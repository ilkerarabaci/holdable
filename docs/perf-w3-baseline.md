# W3 Perf Pass — Baseline + Memory Fix (2026-05-31)

First profile-build performance measurement against the alpha budgets, plus the
memory fix that followed and its verified results.

## Setup
- **Build:** `flutter build apk --profile` (CI `build-profile` job, `workflow_dispatch`).
- **Device:** `holdable_pixel7` AVD (1080×2400, x86_64, Android system image).
- **Fixtures:** synthetic UV-sphere binary STLs from `tools/gen_stl.py`, `adb push`ed to `/sdcard/Download/`, imported via the file picker.
- **Method:** parse-ms / vertex count read from the in-app Info panel (OCR'd from screenshots); memory via `adb shell dumpsys meminfo app.holdable` with the model **fully loaded** (Info shows real values, not `—`); cold start via `am start -W`.

## Budgets
- 50 MB STL parse **< 3 s**
- App PSS **< 200 MB**

## Baseline (before fix)

| Model     | Triangles | Parse  | TOTAL PSS | Native heap |
|-----------|-----------|--------|-----------|-------------|
| perf_10mb | 209,304   | 76 ms  | 220 MB    | 59 MB       |
| perf_25mb | 523,264   | 186 ms | 271 MB    | 107 MB      |
| perf_50mb | 1,046,904 | 350 ms | 303 MB    | 185 MB      |

Cold start (profile, emulator): ~1.7–2.6 s.

- **Parse < 3 s — PASS (large margin).**
- **PSS < 200 MB — FAIL at every size.** 50 MB hit 303 MB (1.5× budget); swap engaged.

## Root cause (`assets/3d-engine/viewer.html` `loadModel`)
1. **Triple transient buffers** held at once: `b64` (~67 MB for a 50 MB file) + `bin` (~50 MB) + `bytes` (~50 MB).
2. **Unindexed STL geometry** — positions = 3 × triangle count (3.14 M vertices @ 50 MB).
3. **`computeVertexNormals()`** adds a full normal attribute (~38 MB @ 50 MB, unwelded).

## Fix (branch `feature/perf-mem-fix`, PR #11)
- `mergeVertices()` → indexed geometry (smooth normals over the welded set).
- Dispose the previous model's geometry on load (prev/next no longer leaks).
- Null the base64 string right after `atob`.

## After fix — verified (fully loaded; vertex count + parse OCR'd, PSS via dumpsys)

| Model     | Welded verts | Parse   | TOTAL PSS    | Native heap |
|-----------|--------------|---------|--------------|-------------|
| perf_10mb | 105,282      | 277 ms  | **188 MB** ✓ | 47 MB       |
| perf_25mb | 262,528      | 695 ms  | **219 MB** ✗ | 70 MB       |
| perf_50mb | 524,386      | 1383 ms | **251 MB** ✗ | 98 MB       |

- **Weld confirmed:** vertex count drops ~6× (≈ triangles/2 — a closed manifold), exactly as expected.
- **Parse < 3 s — still PASS.** Welding adds a hashing pass (~4× parse time; 1383 ms @ 50 MB), comfortably under 3 s.
- **PSS:** native heap roughly halved at every size. **10 MB now clears 200 MB (188); 25 MB (219) and 50 MB (251) still exceed it.**

## Interpretation / next levers
- The fix is a clear win — merge it. But the **WebView (Chromium) + Flutter baseline is the floor** (~180 MB even at 10 MB), so geometry savings alone can't bring 50 MB under 200 MB.
- **`flatShading` is no longer a meaningful lever** — post-weld normals are only ~6 MB.
- Real options to clear 25/50 MB: (a) **soft model-size cap + warning** for alpha (bounds worst case), (b) revisit the WebView/three.js rendering architecture (native renderer) — large effort, (c) **Architect to revisit the 200 MB target** for a WebView-based viewer.

## Repro
```
python tools/gen_stl.py 10 25 50
adb push perf_50mb.stl /sdcard/Download/
gh workflow run ci.yml --ref <branch> -f profile=true   # build profile APK
gh run download <id> -n holdable-profile-apk
adb install -r <apk> ; adb shell dumpsys meminfo app.holdable
```
