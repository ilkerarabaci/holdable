"""Holdable conversion service.

POST /convert      (raw body + ?ext=, or multipart `file`)  -> model as .glb
POST /upload-url   (?ext=)   -> { uploadUrl, objectName } signed GCS PUT URL
POST /convert-gcs  (JSON {objectName, ext}) -> glb inline, OR { downloadUrl }
GET  /health                 -> liveness check

Two upload paths. Small files (<= ~32 MiB) POST straight to /convert. Cloud Run
rejects HTTP/1 request bodies over 32 MiB at the ingress, so LARGE files use the
GCS path: the client asks /upload-url for a signed URL, PUTs the file directly to
GCS (no size limit), then calls /convert-gcs with the object name; the service
downloads it from GCS, converts, and returns the glb inline (small) or a signed
download URL (large output). Objects auto-expire (bucket lifecycle, 1 day).
"""

import datetime
import os
import shutil
import subprocess
import tempfile
import uuid

from flask import Flask, request, send_file, jsonify

app = Flask(__name__)
# /convert reads the raw body into memory; cap it (Cloud Run ingress caps at
# 32 MiB anyway). The GCS path has no such limit.
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024 * 1024
app.config["MAX_FORM_MEMORY_SIZE"] = 64 * 1024 * 1024

# Extensions this service can convert. Native-parseable formats (obj/stl/glb/…)
# never reach here — the app only calls these endpoints for what it can't read.
BLENDER_EXTS = {".blend", ".usd", ".usda", ".usdc", ".usdz"}
# CAD B-rep formats: FreeCAD (OpenCASCADE) tessellates them to an STL, then
# Blender turns that into the glb.
FREECAD_EXTS = {".step", ".stp", ".iges", ".igs"}
SUPPORTED_EXTS = BLENDER_EXTS | FREECAD_EXTS

# A single conversion shouldn't run forever (a runaway import / heavy tessellate).
# Env-configurable so it can be tuned on redeploy without a rebuild. Keep it
# below the gunicorn worker timeout (Dockerfile -t) and the Cloud Run --timeout.
CONVERT_TIMEOUT_S = int(os.environ.get("CONVERT_TIMEOUT_S", "240"))

# GCS bucket for the large-file path (set via the CONVERT_BUCKET env on deploy).
BUCKET_NAME = os.environ.get("CONVERT_BUCKET", "")
# Return the glb in the response if it's small enough to clear Cloud Run's 32 MiB
# response limit with margin; otherwise hand back a signed download URL.
INLINE_MAX = 28 * 1024 * 1024
SIGN_TTL = datetime.timedelta(minutes=20)


class ConvertError(Exception):
    def __init__(self, message, status=422, log=None):
        super().__init__(message)
        self.message = message
        self.status = status
        self.log = log


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


def _convert_to_glb(work, src, ext):
    """Runs the right tool for [ext]; returns the output .glb path or raises
    ConvertError. Shared by /convert and /convert-gcs."""
    out = os.path.join(work, "output.glb")
    if ext in FREECAD_EXTS:
        stl = os.path.join(work, "inter.stl")
        fc = _run_freecad(src, stl)
        if not os.path.exists(stl) or os.path.getsize(stl) == 0:
            tail = (fc.stdout[-1500:] + "\n" + fc.stderr[-1500:]).strip()
            raise ConvertError("CAD tessellation failed", 422, tail)
        proc = _run_blender(stl, out)
    else:
        proc = _run_blender(src, out)
    # Surface Blender's tail (timing lines from convert.py, warnings) to the
    # Cloud Run logs even on success — handy for diagnosing slow conversions.
    print("[blender]\n" + (proc.stderr or proc.stdout or "")[-2000:], flush=True)
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        tail = (proc.stdout[-1500:] + "\n" + proc.stderr[-1500:]).strip()
        raise ConvertError("conversion produced no output", 422, tail)
    return out


def _norm_ext(ext):
    ext = (ext or "").lower()
    if ext and not ext.startswith("."):
        ext = "." + ext
    return ext


# --- GCS helpers (lazy imports so /health + /convert work without the lib) ---

def _bucket():
    from google.cloud import storage
    return storage.Client().bucket(BUCKET_NAME)


def _signing_creds():
    """Default Cloud Run SA credentials, refreshed — used to V4-sign URLs via
    IAM signBlob (the SA has roles/iam.serviceAccountTokenCreator on itself)."""
    from google import auth
    from google.auth.transport import requests as gauth_requests
    creds, _ = auth.default()
    creds.refresh(gauth_requests.Request())
    return creds


def _signed_url(blob, method, content_type=None):
    creds = _signing_creds()
    return blob.generate_signed_url(
        version="v4",
        expiration=SIGN_TTL,
        method=method,
        content_type=content_type,
        service_account_email=creds.service_account_email,
        access_token=creds.token,
    )


@app.get("/health")
def health():
    return jsonify(ok=True, formats=sorted(SUPPORTED_EXTS), gcs=bool(BUCKET_NAME))


@app.post("/convert")
def convert():
    # Two ways to send the file: multipart field `file` (handy for curl), or a
    # raw body with the extension in `?ext=` (what the app uses for small files).
    f = request.files.get("file")
    if f is not None and f.filename:
        ext = _norm_ext(os.path.splitext(f.filename)[1])
        data = f.read()
    else:
        ext = _norm_ext(request.args.get("ext"))
        data = request.get_data()

    if ext not in SUPPORTED_EXTS:
        return jsonify(error=f"unsupported extension: {ext or '(none)'}"), 415
    if not data:
        return jsonify(error="empty body"), 400

    work = tempfile.mkdtemp(prefix="holdable_")
    try:
        src = os.path.join(work, "input" + ext)
        with open(src, "wb") as fh:
            fh.write(data)
        out = _convert_to_glb(work, src, ext)
        return send_file(out, mimetype="model/gltf-binary",
                         as_attachment=True, download_name="model.glb")
    except ConvertError as e:
        return jsonify(error=e.message, log=e.log), e.status
    except subprocess.TimeoutExpired as e:
        # Log whatever Blender printed before the kill — the convert.py phase
        # timing tells us whether LOAD or EXPORT blew the budget.
        partial = (e.stderr or e.stdout or b"")
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", "replace")
        print("[timeout]\n" + partial[-2000:], flush=True)
        return jsonify(error="conversion timed out"), 504
    finally:
        shutil.rmtree(work, ignore_errors=True)


@app.post("/upload-url")
def upload_url():
    """Hand the client a short-lived signed URL to PUT a (large) file straight
    to GCS, plus the object name to pass back to /convert-gcs."""
    if not BUCKET_NAME:
        return jsonify(error="gcs not configured"), 500
    ext = _norm_ext(request.args.get("ext"))
    if ext not in SUPPORTED_EXTS:
        return jsonify(error=f"unsupported extension: {ext or '(none)'}"), 415
    name = f"uploads/{uuid.uuid4().hex}{ext}"
    try:
        url = _signed_url(_bucket().blob(name), "PUT",
                          content_type="application/octet-stream")
    except Exception as e:  # noqa: BLE001 - surface signing/config errors
        return jsonify(error=f"could not sign upload url: {e}"), 500
    return jsonify(uploadUrl=url, objectName=name)


@app.post("/convert-gcs")
def convert_gcs():
    """Convert a file already uploaded to GCS (via /upload-url). Returns the glb
    inline when small, else a signed download URL."""
    if not BUCKET_NAME:
        return jsonify(error="gcs not configured"), 500
    body = request.get_json(silent=True) or {}
    name = body.get("objectName") or ""
    ext = _norm_ext(body.get("ext") or os.path.splitext(name)[1])
    if not name.startswith("uploads/"):
        return jsonify(error="bad objectName"), 400
    if ext not in SUPPORTED_EXTS:
        return jsonify(error=f"unsupported extension: {ext or '(none)'}"), 415

    bucket = _bucket()
    work = tempfile.mkdtemp(prefix="holdable_")
    try:
        src = os.path.join(work, "input" + ext)
        bucket.blob(name).download_to_filename(src)
        out = _convert_to_glb(work, src, ext)
        size = os.path.getsize(out)
        # The upload is consumed; drop it now (lifecycle is the backstop).
        try:
            bucket.blob(name).delete()
        except Exception:  # noqa: BLE001
            pass
        if size <= INLINE_MAX:
            return send_file(out, mimetype="model/gltf-binary",
                             as_attachment=True, download_name="model.glb")
        # Output too big for the 32 MiB response cap → hand back a signed GET URL.
        out_name = f"outputs/{uuid.uuid4().hex}.glb"
        ob = bucket.blob(out_name)
        ob.upload_from_filename(out, content_type="model/gltf-binary")
        return jsonify(downloadUrl=_signed_url(ob, "GET"), sizeBytes=size)
    except ConvertError as e:
        return jsonify(error=e.message, log=e.log), e.status
    except subprocess.TimeoutExpired as e:
        # Log whatever Blender printed before the kill — the convert.py phase
        # timing tells us whether LOAD or EXPORT blew the budget.
        partial = (e.stderr or e.stdout or b"")
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", "replace")
        print("[timeout]\n" + partial[-2000:], flush=True)
        return jsonify(error="conversion timed out"), 504
    except Exception as e:  # noqa: BLE001
        return jsonify(error=f"gcs convert failed: {e}"), 500
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    # Dev fallback; production uses gunicorn (see Dockerfile CMD).
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
