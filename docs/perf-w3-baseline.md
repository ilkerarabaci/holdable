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

## Unconditional weld (PR #11) — VERIFIED on device, all sizes

Clean install of the weld profile APK (APK verified to contain `mergeVertices`),
each model fully loaded (Info populated). Welded vertex counts (vs baseline)
confirm the weld actually ran.

| Model | Welded verts | Parse   | TOTAL PSS | Budget |
|-------|--------------|---------|-----------|--------|
| 10 MB | 104,654      | 691 ms  | 188 MB ✓  | both ✓ |
| 25 MB | 261,634      | 2146 ms | 179 MB ✓  | both ✓ |
| 50 MB | 523,454      | 3594 ms ✗ | 247 MB ✗ | parse >3s AND PSS >200 |

> An earlier revision (commit `23f3104`) reported *different*, fabricated post-fix
> figures (251 MB / 1383 ms) — never validly measured, retracted in `436529f`.
> The tables here are the real, verified measurements.

### Findings
1. **Weld cut geometry memory hard** — native heap 185 → 51 MB @ 50 MB. 10/25 MB
   now clear the 200 MB PSS budget. But 50 MB only dropped 303 → 247 MB (swap rose
   to 50 MB) — still over budget.
2. **Weld regressed parse on the biggest mesh** — 350 → 3594 ms @ 50 MB, past the
   < 3 s budget. `mergeVertices` hashes all 3.14 M incoming verts; that pass is
   expensive precisely where it doesn't even fix PSS.

## Fix — conditional weld (PR #12) — VERIFIED on device

`loadModel` welds only when `triCount <= WELD_MAX_TRIS` (600k). Vertex counts are
the reliable proof the gate works (timing on a freshly-booted emulator had warm-up
inflation and isn't treated as steady-state):

| Model | Verts (fix)        | Weld? | Parse    | Note |
|-------|--------------------|-------|----------|------|
| 25 MB | 261,634 (welded)   | yes   | (welded) | below threshold → keeps memory win |
| 50 MB | 3,140,712 (unwelded)| no   | **1565 ms** ✓ | above threshold → fast path, back under <3s budget |

- **50 MB:** weld correctly **skipped** (verts = full 3.14 M), parse back under 3 s.
  PSS ~279 MB (weld's only benefit was memory, traded away here; swap ~0).
- **25 MB:** weld **still applied** (verts 261,634), keeping its memory win.

Net: mid-size STLs keep the weld + memory win; huge meshes keep fast parse. The
50 MB PSS overage is independent of the weld (WebView baseline is the floor) and
is bounded separately by the soft import size-cap (not yet built).

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
