"""Holdable conversion service.

POST /convert  (multipart form field `file`)  ->  the model converted to .glb
GET  /health                                  ->  liveness check

Stateless: each request writes the upload to a temp dir, runs headless Blender
to export a .glb, streams it back, and cleans up. Designed to run locally in
Docker for dev and on Cloud Run in production (binds $PORT).
"""

import os
import shutil
import subprocess
import tempfile

from flask import Flask, request, send_file, jsonify

app = Flask(__name__)
# Models can be tens of MB. Allow large uploads; clients send the raw bytes as
# application/octet-stream so Werkzeug streams the body instead of form-parsing
# it (whose default 500 KB cap would 413 a real model).
app.config["MAX_CONTENT_LENGTH"] = 200 * 1024 * 1024
app.config["MAX_FORM_MEMORY_SIZE"] = 200 * 1024 * 1024

# Extensions this service can convert. Native-parseable formats (obj/stl/glb/…)
# never reach here — the app only calls /convert for what it can't read itself.
BLENDER_EXTS = {".blend", ".usd", ".usda", ".usdc", ".usdz"}
# CAD B-rep formats: FreeCAD (OpenCASCADE) tessellates them to an STL, then
# Blender turns that into the glb.
FREECAD_EXTS = {".step", ".stp", ".iges", ".igs"}
SUPPORTED_EXTS = BLENDER_EXTS | FREECAD_EXTS

# A single conversion shouldn't run forever (a runaway import / heavy tessellate).
CONVERT_TIMEOUT_S = 240


def _run_blender(src, out):
    return subprocess.run(
        ["blender", "--background", "--factory-startup",
         "--python", "convert.py", "--", src, out],
        capture_output=True, text=True, timeout=CONVERT_TIMEOUT_S,
    )


def _run_freecad(src, stl):
    env = {**os.environ, "CONVERT_IN": src, "CONVERT_OUT": stl}
    return subprocess.run(
        ["freecadcmd", "convert_step.py"],
        env=env, capture_output=True, text=True, timeout=CONVERT_TIMEOUT_S,
    )


@app.get("/health")
def health():
    return jsonify(ok=True, formats=sorted(SUPPORTED_EXTS))


@app.post("/convert")
def convert():
    # Two ways to send the file: multipart field `file` (handy for curl), or a
    # raw body with the extension in `?ext=` (what the app uses — no multipart
    # dependency needed on the client).
    f = request.files.get("file")
    if f is not None and f.filename:
        ext = os.path.splitext(f.filename)[1].lower()
        data = f.read()
    else:
        ext = (request.args.get("ext") or "").lower()
        if ext and not ext.startswith("."):
            ext = "." + ext
        data = request.get_data()

    if ext not in SUPPORTED_EXTS:
        return jsonify(error=f"unsupported extension: {ext or '(none)'}"), 415
    if not data:
        return jsonify(error="empty body"), 400

    work = tempfile.mkdtemp(prefix="holdable_")
    try:
        src = os.path.join(work, "input" + ext)
        out = os.path.join(work, "output.glb")
        with open(src, "wb") as fh:
            fh.write(data)

        if ext in FREECAD_EXTS:
            # B-rep -> STL (FreeCAD) -> glb (Blender).
            stl = os.path.join(work, "inter.stl")
            fc = _run_freecad(src, stl)
            if not os.path.exists(stl) or os.path.getsize(stl) == 0:
                tail = (fc.stdout[-1500:] + "\n" + fc.stderr[-1500:]).strip()
                return jsonify(error="CAD tessellation failed", log=tail), 422
            proc = _run_blender(stl, out)
        else:
            proc = _run_blender(src, out)

        if not os.path.exists(out) or os.path.getsize(out) == 0:
            tail = (proc.stdout[-1500:] + "\n" + proc.stderr[-1500:]).strip()
            return jsonify(error="conversion produced no output", log=tail), 422

        return send_file(
            out,
            mimetype="model/gltf-binary",
            as_attachment=True,
            download_name="model.glb",
        )
    except subprocess.TimeoutExpired:
        return jsonify(error="conversion timed out"), 504
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    # Dev fallback; production uses gunicorn (see Dockerfile CMD).
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
