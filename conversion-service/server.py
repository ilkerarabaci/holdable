"""Holdable conversion service.

Sync (small / 28-200 MB):
  POST /convert      (raw body + ?ext=, or multipart `file`)  -> model as .glb
  POST /upload-url   (?ext=)   -> { uploadUrl, objectName } signed GCS PUT URL
  POST /convert-gcs  (JSON {objectName, ext}) -> glb inline, OR { downloadUrl }

Async (>200 MB — converts in a Cloud Run JOB so it isn't request-bound):
  POST /jobs/upload-url (?ext=) -> { jobId, uploadUrl, objectName } signed PUT
  POST /jobs            (JSON {jobId, ext, origBytes}) -> 202 {jobId, state}
  GET  /jobs/<jobId>            -> status.json (+ downloadUrl when state=done)

  GET  /health                 -> liveness check

Small files POST straight to /convert. Cloud Run rejects HTTP/1 request bodies
over 32 MiB at the ingress, so larger files use the GCS path (sign a PUT, upload
direct, then /convert-gcs). Files over the sync cap go through /jobs: the client
PUTs to GCS, /jobs writes job state to GCS and triggers a Cloud Run Job that
decimates to a mobile budget and writes the output glb back; the client polls
GET /jobs/<id>. GCS is the only state store (no Firestore / Tasks / Pub-Sub).
Objects auto-expire (bucket lifecycle).

The conversion core (Blender/FreeCAD runners, GCS helpers) lives in
convert_core.py so the sync path here and the async job_worker.py run identical
logic. Output is always a PLAIN glb (no Draco/KTX2) — see convert_core's note.
"""

import datetime
import json
import os
import shutil
import subprocess
import tempfile
import uuid

from flask import Flask, request, send_file, jsonify

from convert_core import (
    ConvertError, SUPPORTED_EXTS, INLINE_MAX, BUCKET_NAME,
    convert_to_glb as _convert_to_glb,
    norm_ext as _norm_ext,
    bucket as _bucket,
    signed_url as _signed_url,
)

app = Flask(__name__)
# /convert reads the raw body into memory; cap it (Cloud Run ingress caps at
# 32 MiB anyway). The GCS + jobs paths have no such limit.
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024 * 1024
app.config["MAX_FORM_MEMORY_SIZE"] = 64 * 1024 * 1024

# Shared-secret API key. The service URL is public (--allow-unauthenticated):
# without this, anyone with the URL can trigger paid Blender jobs AND feed
# untrusted .blend files to Blender. Set CONVERT_API_KEY on the Cloud Run
# SERVICE (the Job never receives client traffic); the app bakes the same value
# in via --dart-define and sends it as X-Api-Key. Unset ⇒ auth is OFF (local
# Docker dev / staged rollout) — the health endpoint stays open either way.
API_KEY = os.environ.get("CONVERT_API_KEY", "")


@app.before_request
def _require_api_key():
    if not API_KEY or request.path == "/health":
        return None
    if request.headers.get("X-Api-Key") != API_KEY:
        return jsonify(error="unauthorized"), 401
    return None

# Async Job (>200 MB) target — overridable via env on deploy.
JOB_PROJECT = os.environ.get("JOB_PROJECT", "kerte-dev-prod")
JOB_REGION = os.environ.get("JOB_REGION", "europe-west3")
JOB_NAME = os.environ.get("JOB_NAME", "holdable-convert-job")

# Conversion tunables FORWARDED into every Job execution. The RunJob override's
# containerOverrides.env was observed to REPLACE the Job's deploy-time env (not
# merge): the deploy-time CONVERT_TRI_BUDGET=150000 never reached the container,
# so the job silently ran at convert.py's 400k default — confirmed by a failed
# job's status.json diag ("budget=400000"). So the service is the single source
# of truth and forwards these explicitly on every trigger, read from its own env
# with mobile-fit defaults. Change them here (or via the service's env) — the
# Job's own deploy-time values for these keys are ignored once the override runs.
_JOB_FORWARD_ENV = {
    "CONVERT_TRI_BUDGET": "150000",    # decimate target (mobile face budget)
    "CONVERT_SUBSURF_MAX": "1",        # cap Subsurf/Multires levels pre-export
    "JOB_CONVERT_TIMEOUT_S": "1500",   # per-conversion Blender timeout (async Job)
}


def _iso_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


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
        try:
            bucket.blob(name).delete()
        except Exception:  # noqa: BLE001
            pass
        if size <= INLINE_MAX:
            return send_file(out, mimetype="model/gltf-binary",
                             as_attachment=True, download_name="model.glb")
        out_name = f"outputs/{uuid.uuid4().hex}.glb"
        ob = bucket.blob(out_name)
        ob.upload_from_filename(out, content_type="model/gltf-binary")
        return jsonify(downloadUrl=_signed_url(ob, "GET"), sizeBytes=size)
    except ConvertError as e:
        return jsonify(error=e.message, log=e.log), e.status
    except subprocess.TimeoutExpired as e:
        partial = (e.stderr or e.stdout or b"")
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", "replace")
        print("[timeout]\n" + partial[-2000:], flush=True)
        return jsonify(error="conversion timed out"), 504
    except Exception as e:  # noqa: BLE001
        return jsonify(error=f"gcs convert failed: {e}"), 500
    finally:
        shutil.rmtree(work, ignore_errors=True)


# --- Async >200 MB path (Cloud Run Job + GCS-as-state) ---

def _job_blob(job_id, name):
    return _bucket().blob(f"jobs/{job_id}/{name}")


def _valid_job_id(job_id):
    # uuid4().hex is 32 hex chars; reject anything with path/space chars so the
    # id can't escape the jobs/<id>/ prefix.
    return bool(job_id) and job_id.isalnum() and len(job_id) <= 64


def _trigger_job(job_id):
    """Fire the Cloud Run Job for [job_id] via the Admin API (so no gcloud in
    the image). The per-execution override REPLACES the Job's deploy-time env, so
    we forward EVERYTHING the worker needs: the per-job JOB_ID/JOB_BUCKET plus the
    conversion tunables (_JOB_FORWARD_ENV) — otherwise convert.py falls back to its
    in-code defaults (the 400k-budget bug). The service SA needs run.jobs.run +
    iam.serviceAccountUser on the Job's SA."""
    from google import auth
    from google.auth.transport.requests import AuthorizedSession
    creds, _ = auth.default()
    session = AuthorizedSession(creds)
    url = (f"https://run.googleapis.com/v2/projects/{JOB_PROJECT}"
           f"/locations/{JOB_REGION}/jobs/{JOB_NAME}:run")
    env = [
        {"name": "JOB_ID", "value": job_id},
        {"name": "JOB_BUCKET", "value": BUCKET_NAME},
    ]
    for _k, _default in _JOB_FORWARD_ENV.items():
        env.append({"name": _k, "value": os.environ.get(_k, _default)})
    body = {"overrides": {"containerOverrides": [{"env": env}]}}
    resp = session.post(url, json=body, timeout=30)
    if resp.status_code >= 300:
        raise ConvertError(
            f"could not start job: {resp.status_code} {resp.text[:300]}", 500)
    return resp.json().get("name")


@app.post("/jobs/upload-url")
def jobs_upload_url():
    """Signed PUT URL for a big file under a fresh job id. Client PUTs the file,
    then calls POST /jobs to start the async conversion."""
    if not BUCKET_NAME:
        return jsonify(error="gcs not configured"), 500
    ext = _norm_ext(request.args.get("ext"))
    if ext not in SUPPORTED_EXTS:
        return jsonify(error=f"unsupported extension: {ext or '(none)'}"), 415
    job_id = uuid.uuid4().hex
    name = f"jobs/{job_id}/input{ext}"
    try:
        url = _signed_url(_bucket().blob(name), "PUT",
                          content_type="application/octet-stream")
    except Exception as e:  # noqa: BLE001
        return jsonify(error=f"could not sign upload url: {e}"), 500
    return jsonify(jobId=job_id, uploadUrl=url, objectName=name)


@app.post("/jobs")
def jobs_create():
    """Start an async conversion for an already-uploaded big file: write
    meta.json + an initial status.json, trigger the Cloud Run Job, return 202."""
    if not BUCKET_NAME:
        return jsonify(error="gcs not configured"), 500
    body = request.get_json(silent=True) or {}
    job_id = (body.get("jobId") or "").strip()
    ext = _norm_ext(body.get("ext"))
    if not _valid_job_id(job_id):
        return jsonify(error="bad jobId"), 400
    if ext not in SUPPORTED_EXTS:
        return jsonify(error=f"unsupported extension: {ext or '(none)'}"), 415
    if not _job_blob(job_id, f"input{ext}").exists():
        return jsonify(error="input not uploaded"), 400

    meta = {"id": job_id, "ext": ext, "origBytes": body.get("origBytes"),
            "createdAt": _iso_now()}
    _job_blob(job_id, "meta.json").upload_from_string(
        json.dumps(meta), content_type="application/json")
    status = {"id": job_id, "state": "queued", "phase": "queued", "ext": ext,
              "error": None, "outputObject": None, "outputBytes": None}
    _job_blob(job_id, "status.json").upload_from_string(
        json.dumps(status), content_type="application/json")
    try:
        _trigger_job(job_id)
    except ConvertError as e:
        status.update(state="failed", error=e.message)
        _job_blob(job_id, "status.json").upload_from_string(
            json.dumps(status), content_type="application/json")
        return jsonify(error=e.message), e.status
    except Exception as e:  # noqa: BLE001
        return jsonify(error=f"could not start job: {e}"), 500
    return jsonify(jobId=job_id, state="queued"), 202


@app.get("/jobs/<job_id>")
def jobs_status(job_id):
    """Poll a job. Returns status.json; when done, adds a signed downloadUrl for
    the output glb."""
    if not BUCKET_NAME:
        return jsonify(error="gcs not configured"), 500
    if not _valid_job_id(job_id):
        return jsonify(error="bad jobId"), 400
    blob = _job_blob(job_id, "status.json")
    if not blob.exists():
        return jsonify(error="unknown job"), 404
    status = json.loads(blob.download_as_text())
    if status.get("state") == "done" and status.get("outputObject"):
        try:
            status["downloadUrl"] = _signed_url(
                _bucket().blob(status["outputObject"]), "GET")
        except Exception as e:  # noqa: BLE001
            status["downloadUrl"] = None
            status["error"] = f"could not sign download url: {e}"
    return jsonify(status)


if __name__ == "__main__":
    # Dev fallback; production uses gunicorn (see Dockerfile CMD).
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
