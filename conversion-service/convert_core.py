"""Shared conversion core — used by BOTH the Flask service (server.py) and the
async Cloud Run Job worker (job_worker.py).

Pure tool-running + GCS helpers, no Flask. Extracted from server.py so the
synchronous path (small / 28-200 MB files) and the async >200 MB Job path run
the *exact same* Blender / FreeCAD conversion — only the trigger and the
poly/texture budget differ.

IMPORTANT — output must stay PLAIN glb (uncompressed geometry + PNG/JPEG
textures). The device re-parses every imported glb with a custom pure-Dart
reader (lib/features/viewer/data/gltf_parser.dart) that THROWS on Draco/meshopt
and only decodes PNG/JPEG. Do NOT enable Draco or KTX2 in convert.py until that
renderer can read them (see memory: holdable-gltf-parser-constraint). The >200 MB
win comes from aggressive decimation + texture downscale, not codec compression.
"""

import datetime
import os
import subprocess

# Extensions this service can convert. Native-parseable formats (obj/stl/glb/…)
# never reach here — the app only calls the service for what it can't read.
BLENDER_EXTS = {".blend", ".usd", ".usda", ".usdc", ".usdz"}
# CAD B-rep formats: FreeCAD (OpenCASCADE) tessellates them to an STL, then
# Blender turns that into the glb.
FREECAD_EXTS = {".step", ".stp", ".iges", ".igs"}
SUPPORTED_EXTS = BLENDER_EXTS | FREECAD_EXTS

# Default per-conversion timeout for the SYNC path (kept below the gunicorn
# worker timeout + Cloud Run --timeout). The async Job passes a much larger
# timeout since it isn't request-bound (Cloud Run Jobs allow long task timeouts).
CONVERT_TIMEOUT_S = int(os.environ.get("CONVERT_TIMEOUT_S", "240"))

# GCS bucket for the large-file + async paths (set via CONVERT_BUCKET on deploy).
BUCKET_NAME = os.environ.get("CONVERT_BUCKET", "")
# Return the glb in the HTTP response if it clears Cloud Run's 32 MiB response
# cap with margin; otherwise hand back a signed download URL.
INLINE_MAX = 28 * 1024 * 1024
SIGN_TTL = datetime.timedelta(minutes=20)


class ConvertError(Exception):
    def __init__(self, message, status=422, log=None):
        super().__init__(message)
        self.message = message
        self.status = status
        self.log = log


def norm_ext(ext):
    ext = (ext or "").lower()
    if ext and not ext.startswith("."):
        ext = "." + ext
    return ext


def _run_blender(src, out, timeout=None):
    try:
        return subprocess.run(
            ["blender", "--background", "--factory-startup",
             "--python", "convert.py", "--", src, out],
            capture_output=True, text=True, timeout=timeout or CONVERT_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as e:
        # subprocess.run discards the captured output when it times out — forward
        # convert.py's [convert] phase lines so a timeout is DIAGNOSABLE (which
        # phase ran long, base vs evaluated face counts) instead of just a bare
        # "timed out after N seconds".
        partial = (e.stderr or "") + "\n" + (e.stdout or "")
        print("[blender:timeout]\n" + partial[-3000:], flush=True)
        raise


def _run_freecad(src, stl, timeout=None):
    env = {**os.environ, "CONVERT_IN": src, "CONVERT_OUT": stl}
    return subprocess.run(
        ["freecadcmd", "convert_step.py"],
        env=env, capture_output=True, text=True,
        timeout=timeout or CONVERT_TIMEOUT_S,
    )


def convert_to_glb(work, src, ext, timeout=None):
    """Runs the right tool for [ext]; returns the output .glb path or raises
    ConvertError. Shared by /convert, /convert-gcs and the async Job worker.

    [timeout] overrides CONVERT_TIMEOUT_S (the Job passes a larger value since it
    is not request-bound). convert.py reads its poly/texture budget from env
    (CONVERT_TRI_BUDGET / CONVERT_TEX_MAX), so the Job tightens the budget for
    mobile-fit output without any change here.
    """
    out = os.path.join(work, "output.glb")
    if ext in FREECAD_EXTS:
        stl = os.path.join(work, "inter.stl")
        fc = _run_freecad(src, stl, timeout=timeout)
        if not os.path.exists(stl) or os.path.getsize(stl) == 0:
            tail = (fc.stdout[-1500:] + "\n" + fc.stderr[-1500:]).strip()
            raise ConvertError("CAD tessellation failed", 422, tail)
        proc = _run_blender(stl, out, timeout=timeout)
    else:
        proc = _run_blender(src, out, timeout=timeout)
    # Surface Blender's tail (phase timing from convert.py, warnings) to the logs
    # even on success — handy for diagnosing slow conversions.
    print("[blender]\n" + (proc.stderr or proc.stdout or "")[-2000:], flush=True)
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        tail = (proc.stdout[-1500:] + "\n" + proc.stderr[-1500:]).strip()
        raise ConvertError("conversion produced no output", 422, tail)
    return out


# --- GCS helpers (lazy imports so /health works without the lib) ---

def bucket():
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


def signed_url(blob, method, content_type=None):
    creds = _signing_creds()
    return blob.generate_signed_url(
        version="v4",
        expiration=SIGN_TTL,
        method=method,
        content_type=content_type,
        service_account_email=creds.service_account_email,
        access_token=creds.token,
    )
