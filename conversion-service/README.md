# Holdable conversion service

Converts model formats the app can't parse natively into `.glb`, using headless
Blender. The app calls this only when `ModelFormat.fromExtension()` returns null
for a *convertible* extension (`.blend`, USD; STEP/IGES via FreeCAD later).

| Endpoint | |
|---|---|
| `POST /convert` | multipart `file` or raw body + `?ext=` → streams back `model.glb` |
| `POST /upload-url` · `POST /convert-gcs` | 28–200 MB: sign a GCS PUT, upload direct, then convert the uploaded object |
| `POST /jobs/upload-url` · `POST /jobs` · `GET /jobs/<id>` | **>200 MB async**: upload to GCS → a Cloud Run **Job** converts → poll status |
| `GET /health` | `{ ok, formats, gcs }` |

## Run locally (Docker Desktop)

```bash
# Build (downloads Blender ~300 MB the first time)
docker build -t holdable-convert:dev conversion-service/

# Run
docker run --rm -p 8080:8080 holdable-convert:dev

# Health
curl http://localhost:8080/health

# Convert (any .blend / .usd / .usdz)
curl -F file=@model.blend http://localhost:8080/convert -o out.glb
```

Generate a throwaway test `.blend` (default cube scene) without Blender installed
on the host — run it inside the image:

```bash
docker run --rm -v "$PWD:/out" holdable-convert:dev \
  blender --background --factory-startup \
  --python-expr "import bpy; bpy.ops.wm.save_as_mainfile(filepath='/out/test.blend')"
```

## Deployed (Cloud Run)

Live: **https://holdable-convert-872321921378.europe-west3.run.app** (public,
project `kerte-dev-prod`, region `europe-west3`). The app points here
([conversion_service.dart](../lib/features/import/data/conversion_service.dart)).

Redeploy after changes:

```bash
gcloud builds submit conversion-service/ --timeout=2400s \
  --tag europe-west3-docker.pkg.dev/kerte-dev-prod/holdable/convert:latest
gcloud run deploy holdable-convert \
  --image europe-west3-docker.pkg.dev/kerte-dev-prod/holdable/convert:latest \
  --region europe-west3 --memory 4Gi --cpu 2 --concurrency 1 \
  --max-instances 3 --timeout 300 --allow-unauthenticated
```

## Async conversion for files >200 MB (Cloud Run Job)

Big files would blow the request timeout, so they convert in a **Cloud Run Job**
(`holdable-convert-job`) instead of in-request. The client PUTs the file to GCS,
calls `POST /jobs`, then polls `GET /jobs/<id>`; the service triggers the Job via
the Cloud Run Admin API (no gcloud in the image). State lives entirely in GCS
(`jobs/<id>/{meta,status}.json` + `input*` + `output.glb`) — no Firestore / Tasks /
Pub-Sub. The Job shares this image, overriding the entrypoint to
`python job_worker.py`, and decimates to a tight mobile `CONVERT_TRI_BUDGET`.

Output is a **plain glb** (no Draco/KTX2) — the device's Dart glTF parser can't read
compressed geometry/textures. The win is decimation + (TODO) texture downscale.

```bash
# Deploy/redeploy the Job (after the gcloud builds submit above)
gcloud run jobs deploy holdable-convert-job \
  --image europe-west3-docker.pkg.dev/kerte-dev-prod/holdable/convert:latest \
  --region europe-west3 --command python --args job_worker.py \
  --task-timeout 1800 --max-retries 1 --parallelism 1 --tasks 1 \
  --memory 8Gi --cpu 4 \
  --service-account 872321921378-compute@developer.gserviceaccount.com \
  --set-env-vars CONVERT_BUCKET=holdable-convert-tmp-872321921378,CONVERT_TRI_BUDGET=150000,JOB_CONVERT_TIMEOUT_S=1500

# One-time IAM: let the service SA trigger the Job + act as its SA
gcloud projects add-iam-policy-binding kerte-dev-prod \
  --member serviceAccount:872321921378-compute@developer.gserviceaccount.com \
  --role roles/run.developer --condition=None
gcloud iam service-accounts add-iam-policy-binding \
  872321921378-compute@developer.gserviceaccount.com \
  --member serviceAccount:872321921378-compute@developer.gserviceaccount.com \
  --role roles/iam.serviceAccountUser
```

Verified end-to-end (test.blend → GCS → Job → status `done` → valid glb).
**Follow-ups:** texture downscale (`CONVERT_TEX_MAX`), fair-use throttling
(`usage/*.json`), FCM push to replace polling, restart-survivable polling.

## Status

| | |
|---|---|
| `.blend` | ✅ Blender — device-verified end-to-end |
| USD (`.usd/.usda/.usdc/.usdz`) | ✅ Blender — service-verified |
| STEP/IGES (`.step/.stp/.iges/.igs`) | ✅ FreeCAD→STL→Blender — service-verified |

**TODO before a real launch:** the endpoint is public + unauthenticated — add an
API key / Cloud Run auth, and consider a non-prod GCP project. `max-instances=3`
caps runaway cost for now.
