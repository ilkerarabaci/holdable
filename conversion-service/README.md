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

### Iterate on convert.py for free (Dockerfile.test)

Every cloud round-trip (build + Job run) costs real money — validate conversion
changes locally first. `Dockerfile.test` is a minimal python-slim + Blender
image (no FreeCAD/gunicorn, fast build) that runs `convert.py` directly:

```bash
docker build -f conversion-service/Dockerfile.test -t holdable-convert:test conversion-service/
# (Git Bash) MSYS_NO_PATHCONV=1 stops /data being mangled into C:\...\data
MSYS_NO_PATHCONV=1 docker run --rm \
  -e CONVERT_TRI_BUDGET=150000 -e CONVERT_SUBSURF_MAX=1 \
  -v "<dir-without-spaces>:/data" holdable-convert:test \
  blender --background --factory-startup --python /app/convert.py -- \
  /data/in.blend /data/out.glb
```

Watch the `[phase]`/`[mesh]` stderr lines — per-phase and per-heavy-mesh timing
plus `diag.txt` pinpoint any slow mesh by name. Rebuild the image after every
convert.py change (it's COPY'd in).

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

> **Tunables live in server.py, not the Job deploy.** The RunJob override
> (`containerOverrides.env`) *replaces* the Job's deploy-time env, so the Job's
> own `--set-env-vars CONVERT_TRI_BUDGET/JOB_CONVERT_TIMEOUT_S` never reach the
> running container (confirmed by a timed-out job's status `diag: budget=400000`
> despite a 150k deploy). The service FORWARDS these on every trigger from
> `_JOB_FORWARD_ENV` in [server.py](server.py) — change them there. The Job's
> `--set-env-vars` above is only a fallback for a direct `gcloud run jobs execute`.

**Gzip uploads (#8):** the app gzips `.blend` uploads before the GCS PUT (they
compress 2-5×; the upload is ~84% of a big import's wall clock). The worker
detects the gzip magic bytes and decompresses before converting — no flag, so
raw uploads from older clients pass through unchanged.

**Follow-ups:** texture downscale (`CONVERT_TEX_MAX`), fair-use throttling
(`usage/*.json`), FCM push to replace polling.

## Security / cost hygiene (pre-launch)

The service URL is **public** (`--allow-unauthenticated`): anyone with the URL
can trigger paid Blender jobs and feed untrusted `.blend` files to Blender.
Mitigation shipped in code: a shared-secret **API key** — `server.py` rejects
requests without a matching `X-Api-Key` once `CONVERT_API_KEY` is set (unset =
auth off, so rollout is two-step and can't brick the installed app).

```bash
# 1) Generate a key and set it on the SERVICE (the Job takes no client traffic)
KEY=$(openssl rand -hex 24)
gcloud run services update holdable-convert --region europe-west3 \
  --update-env-vars CONVERT_API_KEY=$KEY
# 2) Add the same value as the GitHub repo secret CONVERT_API_KEY —
#    CI bakes it into the APK via --dart-define. Rebuild + reinstall, THEN
#    step 1 can be enforced. (Key order: secret first, server second.)
```

This is anti-abuse, not user auth: a determined attacker can extract the key
from the APK — rotate it (repeat both steps) if abused. Remaining hygiene, run
occasionally:

```bash
# Old convert images (~1 GB Blender each) accumulate per build — keep the newest few
gcloud artifacts docker images list \
  europe-west3-docker.pkg.dev/kerte-dev-prod/holdable/convert \
  --include-tags --sort-by=~UPDATE_TIME
gcloud artifacts docker images delete <...>@sha256:<old-digest> --delete-tags

# Confirm the tmp bucket expires uploads (1-day lifecycle: gcs_lifecycle.json)
gsutil lifecycle get gs://holdable-convert-tmp-872321921378
gsutil lifecycle set conversion-service/gcs_lifecycle.json gs://holdable-convert-tmp-872321921378
```

Still open (accepted for alpha, revisit at launch): the service + Job run as the
**default compute SA** (broad project roles) — a dedicated least-privilege SA
(`storage.objectAdmin` on the tmp bucket + `run.developer` on the Job +
`iam.serviceAccountUser` + `serviceAccountTokenCreator` on itself) would contain
a compromise of the public endpoint; and `max-instances=3` caps runaway cost.

## Status

| | |
|---|---|
| `.blend` | ✅ Blender — device-verified end-to-end |
| USD (`.usd/.usda/.usdc/.usdz`) | ✅ Blender — service-verified |
| STEP/IGES (`.step/.stp/.iges/.igs`) | ✅ FreeCAD→STL→Blender — service-verified |
