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
import gzip
import json
import os
import shutil
import tempfile
import traceback

import convert_core as core

JOB_ID = os.environ["JOB_ID"]
BUCKET = os.environ.get("JOB_BUCKET") or core.BUCKET_NAME
PREFIX = f"jobs/{JOB_ID}"
# Per-conversion Blender timeout. server.py's /jobs trigger now FORWARDS this in
# the per-execution containerOverrides.env (the override REPLACES the Job's
# deploy-time env, so forwarding is the only way a tuned value reaches here — see
# server.py _JOB_FORWARD_ENV). This default is just the safety net for a direct
# `gcloud run jobs execute` with no override. Heavy real-world models (e.g. the
# 49 MB, 3.2M-eval-face 4Holdable2.blend) legitimately need minutes, so keep it
# generous rather than the 240s used transiently for #9 diagnosis.
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


def _gunzip_if_needed(src):
    """#8: the client gzips .blend uploads (they compress 2-5x and the upload
    dominates the wall clock). Detect by the gzip magic, not a flag, so old
    clients' raw uploads pass through untouched. A LEGACY gzip-compressed .blend
    (old Blender's compressed save) also matches — decompressing it yields the
    raw .blend, which Blender opens the same, so the transform is safe either way."""
    with open(src, "rb") as fh:
        if fh.read(2) != b"\x1f\x8b":
            return
    raw = src + ".raw"
    with gzip.open(src, "rb") as fin, open(raw, "wb") as fout:
        shutil.copyfileobj(fin, fout)
    os.replace(raw, src)


def _read_diag(work):
    """The modifier-stack / face-count sidecar convert.py writes before the slow
    export — surfaced in status.json so a timeout is diagnosable without digging
    through Cloud Run logs."""
    try:
        p = os.path.join(work, "diag.txt")
        return open(p).read()[-4000:] if os.path.exists(p) else ""
    except Exception:  # noqa: BLE001
        return ""


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
        _gunzip_if_needed(src)

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
                      outputBytes=os.path.getsize(out), diag=_read_diag(work))
        _write_status(b, status)
    except core.ConvertError as e:
        status.update(state="failed", phase="convert", error=e.message,
                      diag=_read_diag(work))
        _write_status(b, status)
    except Exception as e:  # noqa: BLE001
        # Always leave a terminal status so the client stops polling.
        status.update(state="failed", error=str(e), diag=_read_diag(work))
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
