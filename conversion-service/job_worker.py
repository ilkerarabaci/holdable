"""Async conversion worker — runs as a Cloud Run JOB (not the Flask service).

Deployed from the SAME image as server.py, with the entrypoint overridden to
`python job_worker.py`. Reads JOB_ID + JOB_BUCKET from the per-execution env
(set by server.py's /jobs trigger), converts the already-uploaded input to a
mobile-fit glb, and writes the output + a status.json back to GCS. The Flask
service never blocks on this — it just polls status.json (GET /jobs/{id}).

GCS-as-state layout (no Firestore / Tasks / Pub-Sub):
    jobs/{id}/meta.json     request facts (ext, origBytes, createdAt)
    jobs/{id}/input{ext}     the uploaded big file (deleted after success)
    jobs/{id}/status.json    single source of truth (queued|running|done|failed)
    jobs/{id}/output.glb     mobile-fit result, written on success

Output stays a PLAIN glb (uncompressed geometry + PNG/JPEG textures) — the
device's custom Dart glTF parser can't read Draco/KTX2 (see convert_core's note).
The size win is the tight CONVERT_TRI_BUDGET passed via env, not codec compression.
"""

import datetime
import json
import os
import shutil
import tempfile
import traceback

import convert_core as core

JOB_ID = os.environ["JOB_ID"]
BUCKET = os.environ.get("JOB_BUCKET") or core.BUCKET_NAME
PREFIX = f"jobs/{JOB_ID}"
# Jobs aren't request-bound; allow a long conversion (Cloud Run Job task-timeout
# is the real ceiling). Stay an env knob so it's tunable on redeploy.
JOB_CONVERT_TIMEOUT_S = int(os.environ.get("JOB_CONVERT_TIMEOUT_S", "1500"))


def _bucket():
    from google.cloud import storage
    return storage.Client().bucket(BUCKET)


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _write_status(b, status):
    status["updatedAt"] = _now()
    b.blob(f"{PREFIX}/status.json").upload_from_string(
        json.dumps(status), content_type="application/json")


def main():
    b = _bucket()
    meta = json.loads(b.blob(f"{PREFIX}/meta.json").download_as_text())
    ext = meta.get("ext", "")
    status = {
        "id": JOB_ID, "state": "running", "phase": "download", "ext": ext,
        "origBytes": meta.get("origBytes"), "createdAt": meta.get("createdAt"),
        "outputObject": None, "outputBytes": None, "error": None,
    }
    _write_status(b, status)

    work = tempfile.mkdtemp(prefix="holdablejob_")
    try:
        src = os.path.join(work, "input" + ext)
        b.blob(f"{PREFIX}/input{ext}").download_to_filename(src)

        status["phase"] = "convert"
        _write_status(b, status)
        # CONVERT_TRI_BUDGET / CONVERT_TEX_MAX come from the Job's env (set tight
        # for mobile-fit output); convert.py reads them. Long timeout since the
        # Job isn't request-bound.
        out = core.convert_to_glb(work, src, ext, timeout=JOB_CONVERT_TIMEOUT_S)

        status["phase"] = "upload"
        _write_status(b, status)
        out_obj = f"{PREFIX}/output.glb"
        b.blob(out_obj).upload_from_filename(out, content_type="model/gltf-binary")

        # Input consumed — drop it now (lifecycle is the backstop).
        try:
            b.blob(f"{PREFIX}/input{ext}").delete()
        except Exception:  # noqa: BLE001
            pass

        status.update(state="done", phase="done", outputObject=out_obj,
                      outputBytes=os.path.getsize(out))
        _write_status(b, status)
    except core.ConvertError as e:
        status.update(state="failed", phase="convert", error=e.message)
        _write_status(b, status)
    except Exception as e:  # noqa: BLE001
        # Always leave a terminal status so the client stops polling.
        status.update(state="failed", error=str(e))
        try:
            _write_status(b, status)
        except Exception:  # noqa: BLE001
            pass
        traceback.print_exc()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    # Exit 0 regardless — failure is represented in status.json (the client
    # reads state), not as an opaque Job-execution error.


if __name__ == "__main__":
    main()
