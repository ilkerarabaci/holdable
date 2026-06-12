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

## Phases

1. **.blend + USD** via Blender — this image. ✅ local-Docker first.
2. App integration: `import_service` routes convertible extensions here.
3. **STEP / IGES** via FreeCAD (OpenCASCADE) added to the image.
4. Deploy to **Cloud Run** (`gcloud run deploy`, needs a GCP project).

The app reaches it at the dev machine's LAN IP during local testing, and at the
Cloud Run URL in production.
