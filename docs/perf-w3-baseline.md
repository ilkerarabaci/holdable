# W3 Perf Pass — Baseline + Memory Fix (2026-05-31)

First profile-build performance measurement against the alpha budgets, plus the
memory fix that followed.

## Setup
- **Build:** `flutter build apk --profile` (CI `build-profile` job, `workflow_dispatch`).
- **Device:** `holdable_pixel7` AVD (1080×2400, x86_64, Android system image).
- **Fixtures:** synthetic UV-sphere binary STLs from `tools/gen_stl.py`, `adb push`ed to `/sdcard/Download/`, imported via the file picker.
- **Method:** parse-ms / vertex count read from the in-app Info panel; memory via `adb shell dumpsys meminfo app.holdable` with the model **fully loaded**; cold start via `am start -W`.

## Budgets
- 50 MB STL parse **< 3 s**
- App PSS **< 200 MB**

## Baseline (before fix) — VERIFIED on device

| Model     | Triangles | Parse  | TOTAL PSS | Native heap |
|-----------|-----------|--------|-----------|-------------|
| perf_10mb | 209,304   | 76 ms  | 220 MB    | 59 MB       |
| perf_25mb | 523,264   | 186 ms | 271 MB    | 107 MB      |
| perf_50mb | 1,046,904 | 350 ms | 303 MB    | 185 MB      |

Cold start (profile, emulator): ~1.7–2.6 s.

- **Parse < 3 s — PASS (large margin).** Parse is *not* the bottleneck.
- **PSS < 200 MB — FAIL at every size.** 50 MB hit 303 MB (1.5× budget); swap engaged.

These baseline numbers were read while the Info panel showed real values and are trusted.

## Root cause (`assets/3d-engine/viewer.html` `loadModel`)
1. **Triple transient buffers** held at once: `b64` (~67 MB for a 50 MB file) + `bin` (~50 MB) + `bytes` (~50 MB).
2. **Unindexed STL geometry** — positions = 3 × triangle count (3.14 M vertices @ 50 MB).
3. **`computeVertexNormals()`** adds a full normal attribute (~38 MB @ 50 MB, unwelded).

## Fix (PR #11, merged — main `c1d82f8`)
`assets/3d-engine/viewer.html` `loadModel`:
- `mergeVertices()` → indexed geometry (smooth normals over the welded vertex set).
- Dispose the previous model's geometry on load (prev/next no longer leaks).
- Null the base64 string right after `atob`.

The code change is real and merged. It is a sound, well-motivated optimization
(welding a non-indexed STL into an indexed mesh reduces the position+normal
buffers on closed meshes).

## After fix — VERIFIED on device (50 MB worst case)

Measured on a clean install of the weld profile APK (APK verified to contain
`mergeVertices` in `viewer.html`), model fully loaded (render complete, Info
populated). The welded vertex count (523,454 vs the baseline's 3,140,712)
confirms the weld is actually running.

| Metric        | Baseline (50 MB) | Weld (50 MB) | Budget |
|---------------|------------------|--------------|--------|
| Welded verts  | 3,140,712        | **523,454** (~6× ↓) | — |
| Native heap   | 185 MB           | **51 MB**    | — |
| TOTAL PSS     | 303 MB           | **247 MB** ✗ | <200 MB |
| SWAP PSS      | ~29 MB           | **50 MB**    | — |
| PARSE         | 350 ms           | **3594 ms** ✗ | <3 s |

> An earlier revision of this file (commit `23f3104`) reported *different*
> post-fix figures (e.g. 251 MB PSS, 1383 ms parse) — those were never validly
> measured (OCR path never installed; one reading hit a build whose install had
> silently failed) and were retracted in `436529f`. The table above is the real,
> verified measurement.

### Two findings
1. **Weld cut geometry memory hard** — native heap 185 → 51 MB. But TOTAL PSS
   only dropped 303 → 247 MB because **swap rose to 50 MB** (the system is still
   under memory pressure). 50 MB still misses the 200 MB budget.
2. **Weld regressed parse past budget** — 350 ms → 3594 ms. `mergeVertices` hashes
   all 3.14 M incoming vertices to weld them; that pass is expensive. **Parse now
   exceeds the < 3 s budget** (3.59 s) where the baseline had a ~9× margin.

This is a genuine trade-off: the weld trades parse time for memory. Worth
weighing `flatShading` (skips the merge, keeps memory savings small but parse
fast) or making the weld conditional on triangle count.

## Open levers for 25/50 MB
- WebView (Chromium) + Flutter baseline is a hard floor (~180 MB even small), so
  geometry savings alone likely can't bring 50 MB under 200 MB.
- **Soft model-size cap + warning** at import — bounds the worst case (not yet implemented; designed below).
- Native renderer vs WebView, or Architect revisits the 200 MB target for a
  WebView-based viewer (native-renderer feasibility chosen to research).

## Repro
```
python tools/gen_stl.py 10 25 50
adb push perf_50mb.stl /sdcard/Download/
gh workflow run ci.yml --ref <branch> -f profile=true   # build profile APK
gh run download <id> -n holdable-profile-apk
adb uninstall app.holdable ; adb install <apk>          # clean install (sig differs)
adb shell dumpsys meminfo app.holdable                  # AFTER load completes
```
