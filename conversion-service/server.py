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

# Extensions this service can convert. Native-parseable formats (obj/stl/glb/…)
# never reach here — the app only calls /convert for what it can't read itself.
BLENDER_EXTS = {".blend", ".usd", ".usda", ".usdc", ".usdz"}
SUPPORTED_EXTS = BLENDER_EXTS  # FreeCAD/STEP added in a later phase.

# A single conversion shouldn't run forever (a runaway Blender import).
CONVERT_TIMEOUT_S = 240


@app.get("/health")
def health():
    return jsonify(ok=True, formats=sorted(SUPPORTED_EXTS))


@app.post("/convert")
def convert():
    f = request.files.get("file")
    if f is None or not f.filename:
        return jsonify(error="missing 'file'"), 400

    ext = os.path.splitext(f.filename)[1].lower()
    if ext not in SUPPORTED_EXTS:
        return jsonify(error=f"unsupported extension: {ext or '(none)'}"), 415

    work = tempfile.mkdtemp(prefix="holdable_")
    try:
        src = os.path.join(work, "input" + ext)
        out = os.path.join(work, "output.glb")
        f.save(src)

        proc = subprocess.run(
            [
                "blender", "--background", "--factory-startup",
                "--python", "convert.py", "--", src, out,
            ],
            capture_output=True, text=True, timeout=CONVERT_TIMEOUT_S,
        )

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
