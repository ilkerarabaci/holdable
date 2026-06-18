# F-UV — Texture & Real UV Mapping — Plan (BC · PRD · SRS · Wireframes · Rollout)

Owner: Holdable · PO: Efe · Status: PROPOSED (awaiting PO sign-off on §7 decisions)
Origin: Efe feedback round 2, item #6 — *"texture ya kaldıralım ya da gerçek UV-mapping yapabilecek bir yazılım ekleyelim."* PO decision: **add real UV mapping** (removal rejected).

---

## 1. Business Case (BC)

### 1.1 Problem
The in-app texture feature applies a texture using a **crude box-projection** for the UV-less meshes Holdable actually imports (STL/OBJ have no authored UVs). One uniform scale + dominant-axis planar projection → the texture **stretches** on the long axis and **seams** at every facet where the dominant axis flips. On the formats users actually bring, it looks broken — or silently does nothing.

It is also the project's **single worst stability liability**: the texture/custom-material native path caused the entire alpha.28→34 crash firefight (gltfio ubershader variant aborts, Adreno float-upload SIGSEGV) and still carries a crash-trace file + crash-loop guard + a device diagnostic dialog.

### 1.2 Objective
Let a user apply a texture/material to **any** imported model and have it map **correctly** (low distortion, no seams), regardless of whether the model shipped UVs — **without** reopening the native crash surface.

### 1.3 Options considered
| Option | Approach | New crash surface? | Verdict |
|---|---|---|---|
| **A** | On-device auto-unwrap (xatlas via FFI/WASM) → real UVs → existing apply | No | **Defer** — adds a per-ABI native lib + unwrap of 1–3M-tri meshes on-device (seconds–minutes, memory-heavy vs the already-tight PSS budget). Good future offline story. |
| **B** | **Server-side auto-unwrap** (Blender *Smart UV Project* via the existing Cloud Run service) → plain GLB with real `TEXCOORD_0` → the device's **existing, proven** baseColorMap apply | **None** | **RECOMMENDED** |
| **C** | Triplanar mapping in a custom Filament `.filamat` (no unwrap, no seams) | **Yes** — re-enters the alpha.28-34 minefield | **Reject** for this milestone |

### 1.4 Why B
The output of B is **exactly the artifact the app already renders correctly and safely today** — a plain GLB carrying `TEXCOORD_0`. The native apply path (ubershader baseColorMap variant + 8-bit `SRGB8_A8` upload) is **reused unchanged**; only the *quality of the UVs* changes. B also reuses the **already-battle-tested** Cloud Run + upload + async-Job + polling infrastructure. Net: B fixes the cosmetic problem **and** retires the box-projection crash-fallback, with no new render risk.

### 1.5 Cost & value
- **Cost:** ~9–13 engineering-days + ~2 device-validation rounds; almost entirely additive/reuse. Marginal infra = per-texture Blender compute on existing Cloud Run (quota/auth to address — §7.6).
- **Value:** turns a broken, crash-prone novelty into a working, designer-facing capability (the competitor analysis flagged "designer-friendly" as white space); simultaneously removes a top crash liability.

### 1.6 Recommendation
Adopt **Option B**, **on-demand** (unwrap the first time a model is textured), phased per §6.

---

## 2. Product Requirements (PRD)

### 2.1 Goal
Apply a texture to any model with correct mapping; basic control over how the texture sits.

### 2.2 In scope (v1)
- Server-side auto-unwrap for UV-less importable meshes (stl/obj/ply/off/etc.).
- Correct application of the **bundled** texture set to unwrapped models.
- **Tiling/scale + rotation** controls.
- One-time unwrap, **cached** per model (instant thereafter).
- Graceful **offline/failure fallback** to the current box-mapping (never a hard fail, never blank).
- AR export + library thumbnail automatically reflect the unwrapped model.

### 2.3 Out of scope (v1)
- On-device unwrap (Option A) — roadmap.
- Custom-material / triplanar (Option C).
- Normal / roughness / PBR maps (v1 = base-color only).
- User-uploaded custom textures (v1 = bundled set).

### 2.4 User stories
- *As a user, I apply a "wood" texture to my STL and it looks right (no stretch/seams).*
- *As a user, I adjust the texture's scale and rotation to taste.*
- *As a user, my imports stay fast — I only wait when I actually texture a model, and only once.*
- *As a user, if I'm offline the model still renders (basic mapping), with a clear note.*

### 2.5 UX flow
1. User opens Render → TEXTURE, taps a swatch.
2. If the model has **real UVs already** (textured GLB) **or** a cached UV-GLB exists → apply immediately (today's path).
3. Else → show **"Preparing model for texturing…"** (spinner + Cancel); the model keeps rendering box-mapped underneath. A one-time Blender unwrap runs server-side.
4. On success → silently swap to the unwrapped GLB, apply the texture correctly; cache it.
5. On failure/offline → toast *"Couldn't prepare high-quality mapping — using basic mapping"*, fall back to box-mapping.
6. **Tiling/scale + rotation** sliders adjust the applied texture live.

### 2.6 Acceptance criteria
- A checker/wood texture tiles on an unwrapped STL **without visible stretch or seams**.
- First texture-apply triggers exactly one unwrap; subsequent applies are instant (cached).
- Offline → box-mapping + toast; no crash, no blank screen.
- No native abort/segfault on the textured variant (crash-trace guard remains armed).
- AR view + thumbnail of a textured model show the unwrapped mesh.

---

## 3. Software Requirements Specification (SRS)

### 3.1 Architecture (Option B)
`import (fast, unchanged)` → user taps texture → if UV-less & uncached: `device → ConversionService.unwrapToGlb() → Cloud Run /unwrap → headless Blender (Smart UV Project + decimate-to-budget + PLAIN GLB export with TEXCOORD_0) → device downloads UV-GLB → cache path in Drift → viewer reloads UV-GLB → existing safe baseColorMap apply`.

### 3.2 Server components (reuse `convert_core`/`server.py` patterns)
- **`unwrap.py`** (new Blender script): factory-reset → import via the right operator (`wm.stl_import`/`obj_import`/`ply_import`/…) → **reuse the existing decimate-to-budget pass** (`convert.py:48-59`) → per mesh: ensure UV layer + `bpy.ops.uv.smart_project(...)` (angle-based `uv.unwrap` fallback for organic) → optional default base-color material slot → `export_scene.gltf(format='GLB', export_apply=True, export_yup=True)` — **identical plain-GLB contract** as `convert.py:66-71` (no Draco/KTX2 — parser constraint, `convert_core.py:9-14`).
- **`convert_core.unwrap_to_glb(work, src, ext)`** mirroring `convert_to_glb` (`:74-99`), calling `_run_blender(..., 'unwrap.py')`.
- **Routes:** `/unwrap`, `/unwrap-gcs`, and a `mode=unwrap` flag in `/jobs` `meta.json` (job_worker dispatches convert vs unwrap). Mirror `server.py:67-165`. **Separate routes (not `/convert`)** so the format gate stays clean — `/convert` must keep rejecting native formats, `/unwrap` must accept them.

### 3.3 Client components
- **`ConversionService.unwrapToGlb(File, ext)`** mirroring `convertToGlb`/`enqueueLargeConversion` — same size tiers (direct ≤28MB / GCS 28–200MB / async Job >200MB), same `_validateGlb` magic-byte check, same `awaitJob` backoff. (STL is the big case → mostly GCS/Job tier.)
- **Drift:** add nullable `Models.uvGlbPath` (`app_database.dart`), bump `schemaVersion`→2 with an additive `onUpgrade`, add `setUvGlbById` (mirror `setThumbnailById`); surface on `LibraryModel` + `LibraryController.setUvGlb`.
- **Parser → UI signal:** propagate the already-computed `hasUv` as `hadAuthoredUv` on `_PreparedModel` (mirror `hadAuthoredNormals`) and expose via the controller (mirror `pickedColorArgb`/`hasTexture`). (Optionally thread through `MeshData` for pure unit-testing.)
- **Viewer source selection:** `model.uvGlbPath ?? model.filePath` (format becomes `glb`); the **existing** `gltf_parser` reads `TEXCOORD_0` — no parser change.
- **Texture transform:** `controller.setTextureTransform(scale, rotationRad)` — applied **CPU-side into the uploaded UV buffer at load** (no new material parameter → stays on the safe surface).

### 3.4 The apply path — UNCHANGED (the safety crux)
`_createGpuTexture` (RGBA8 → `SRGB8_A8` + `setImage` UPLOADABLE, `scene_view.dart:1541-1585`) → `createUbershaderMaterialInstance(hasBaseColorTexture: true, baseColorUV: 0)` → `setBaseColorTexture` + `setBaseColorUV(0)`. **No new `.filamat`, no float upload, no new native binding.** The only difference: UV set 0 now holds Blender Smart-UV charts instead of box-projection.

### 3.5 Constraints
- Converted/unwrapped output **must be plain glTF** (device parser; `convert_core.py:9-14`).
- Reuse the proven 8-bit SRGB upload; **no** custom materials.
- Unwrap cost bounded server-side by the decimate-to-budget pass (device never unwraps a 3M-tri mesh; it downloads a ≤~400k-tri UV-GLB — *lighter* than the source STL → improves PSS).

### 3.6 Crash mitigation
No new native binding (the abort/segfault class is untouched); the crash-trace breadcrumb + `_texCrashStep` auto-skip stay in force; structural graceful degradation (offline→box-map; apply-fail→flat base color); server faults return 4xx/timeout the client already messages.

### 3.7 Testing
- **Unit (pure Dart):** `hadAuthoredUv` false for STL/box-fallback, true for a TEXCOORD_0 GLB; UV-GLB round-trips `TEXCOORD_0`; `unwrapToGlb` tier selection + `_validateGlb` + polling (stubbed HTTP); UV-transform (scale/rotation) as a pure function (like `arPickedColorArgb`). Run on CI's analyze-test job.
- **Server (Python golden):** per-format `/unwrap` returns valid GLB whose JSON chunk has `TEXCOORD_0`; decimation respected; output plain (no `KHR_draco`/`KHR_texture_basisu`).
- **Render harness (offline PPM→PNG, per `docs/alpha-28-prompt.md`):** checker tiles un-stretched on an unwrapped STL (before/after).
- **Device (PO):** no abort on the textured variant; no Adreno segfault; Smart-UV visibly beats box on `perf_50mb.stl`/`perf_70mb.stl`; crash-guard arms/disarms.

---

## 4. Wireframes
See the rendered wireframe widget delivered alongside this doc (Render-panel TEXTURE section: swatches → "Preparing for texturing…" async state → applied + tiling/scale/rotation controls; plus offline-fallback toast).

---

## 5. (reserved)

---

## 6. Phased rollout & effort
*(one engineer familiar with the codebase; "device round" = one PO profile-APK validation)*

- **P0 — Spike / de-risk (0.5–1 day).** Run `smart_project` + GLB export in headless Blender on `perf_50mb.stl` locally; confirm the GLB has `TEXCOORD_0` and renders un-stretched in the offline harness. **Exit:** a hand-made UV-GLB the current app textures correctly **with zero code change** — proves the whole thesis.
- **P1 — Service `/unwrap` (2–3 days).** `unwrap.py`, `unwrap_to_glb`, routes, job mode, Python golden tests, redeploy. Risk: low (pure reuse). **Exit:** curl an STL → get a UV-GLB.
- **P2 — Client integration, on-demand + caching (3–4 days).** `unwrapToGlb`; `uvGlbPath` column + schemaV2 migration + writer; `hadAuthoredUv` plumbing; on-demand trigger + spinner + fallback; file-swap + reload; unit tests. Risk: medium (migration + load sequencing). **Exit (1 device round):** tap-to-texture a UV-less STL → seamless; 2nd tap instant.
- **P3 — Tiling/scale/rotation controls (2 days).** UV-transform fn + sliders + `setTextureTransform`; unit-test the math. Risk: low (CPU-side, off the native surface). **Exit:** folds into P2's device round.
- **P4 — Hardening (1–2 days).** Offline/error toasts, cancel, quota/auth, thumbnail/AR re-check against the UV-GLB, crash-trace regression.

**Total ≈ 9–13 working days + ~2 device rounds.** No renderer rewrite, no new native lib, no new `.filamat`.

---

## 7. Open decisions for the PO (sign-off needed)
1. **Latency:** texturing a UV-less 50–70MB model incurs a one-time Blender round-trip (tens of seconds, occasionally minutes). Accept spinner + cached-thereafter? *(rec: accept)*
2. **On-demand vs at-import:** rec **on-demand** (keeps imports fast; only pays when textured). At-import makes models instantly texture-ready but slows every import + burns quota on never-textured models.
3. **Offline:** degrade to box-mapping, or disable the texture UI when the service is unreachable? *(rec: degrade)*
4. **Decimation:** the textured view shows a decimated mesh (reuses the budget pass). Consistent with today's >200MB behavior — accept, or keep full-res geometry and only add UVs (heavier export/download)?
5. **Unwrap algorithm:** `smart_project` (fast, mechanical) vs angle-based `unwrap` (organic). v1 = one fixed algorithm, or a per-model toggle?
6. **Cost/abuse/auth:** server-side unwrap adds Blender compute per texture action; the conversion base URL is currently unauthenticated. Add auth/quota before shipping more traffic?
7. **Future Option A:** on-device xatlas can be added later behind the **same** `uvGlbPath`/`hadAuthoredUv` seam if offline/zero-latency becomes a requirement — roadmap, not v1.

---

## Critical files (implementation)
- `lib/features/viewer/presentation/scene_view.dart` — apply path (~780-828), `_createGpuTexture` (~1541-1585), box-fallback (~1744-1778), `_load` swap point (~659-707)
- `lib/features/import/data/conversion_service.dart` — add `unwrapToGlb` (reuse tiers + `awaitJob`)
- `conversion-service/server.py` (+ new `unwrap.py`, `convert_core.py`) — `/unwrap` routes
- `lib/features/library/data/app_database.dart` (+ `library_controller.dart`, `library_model.dart`) — `uvGlbPath` column + schemaV2
- `lib/features/viewer/presentation/viewer_screen.dart` — TEXTURE panel: on-demand trigger, spinner, tiling/scale/rotation
