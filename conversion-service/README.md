# Holdable conversion service

Converts model formats the app can't parse natively into `.glb`, using headless
Blender. The app calls this only when `ModelFormat.fromExtension()` returns null
for a *convertible* extension (`.blend`, USD; STEP/IGES via FreeCAD later).

| Endpoint | |
|---|---|
| `POST /convert` | multipart field `file` → streams back `model.glb` (`model/gltf-binary`) |
| `GET /health` | `{ ok: true, formats: [...] }` |

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

## Status

| | |
|---|---|
| `.blend` | ✅ Blender — device-verified end-to-end |
| USD (`.usd/.usda/.usdc/.usdz`) | ✅ Blender — service-verified |
| STEP/IGES (`.step/.stp/.iges/.igs`) | ✅ FreeCAD→STL→Blender — service-verified |

**TODO before a real launch:** the endpoint is public + unauthenticated — add an
API key / Cloud Run auth, and consider a non-prod GCP project. `max-instances=3`
caps runaway cost for now.
