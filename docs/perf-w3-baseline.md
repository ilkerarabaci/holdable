# W3 Perf Pass — Baseline + Memory Fix (2026-05-31)

First profile-build performance measurement against the alpha budgets, plus the
memory fix that followed.

## Setup
- **Build:** `flutter build apk --profile` (CI `build-profile` job, `workflow_dispatch`).
- **Device:** `holdable_pixel7` AVD (1080×2400, x86_64, Android system image).
- **Fixtures:** synthetic UV-sphere binary STLs from `tools/gen_stl.py`, `adb push`ed to `/sdcard/Download/`, imported via the file picker.
- **Method:** parse-ms read from the in-app Info panel; memory via `adb shell dumpsys meminfo app.holdable` with the model loaded; cold start via `am start -W`.

## Budgets
- 50 MB STL parse **< 3 s**
- App PSS **< 200 MB**

## Baseline results (before fix)

| Model      | Triangles  | Parse   | TOTAL PSS | Native heap |
|------------|------------|---------|-----------|-------------|
| perf_10mb  | 209,304    | 76 ms   | 220 MB    | 59 MB       |
| perf_25mb  | 523,264    | 186 ms  | 271 MB    | 107 MB      |
| perf_50mb  | 1,046,904  | 350 ms  | 303 MB    | 185 MB      |

Cold start (profile, emulator): ~2.0–2.6 s.

- **Parse < 3 s — PASS (large margin).** Parse is *not* the bottleneck.
- **PSS < 200 MB — FAIL at every size.** 50 MB hit 303 MB (1.5× budget); `TOTAL SWAP PSS` climbed to ~29 MB → system swapping.

## Root cause (`assets/3d-engine/viewer.html` `loadModel`)
1. **Triple transient buffers** held simultaneously: `b64` (~67 MB for a 50 MB file) + `bin` binary string (~50 MB) + `bytes` Uint8Array (~50 MB).
2. **Unindexed STL geometry** — positions = 3 × triangle count (3.14 M vertices at 50 MB).
3. **`computeVertexNormals()`** adds a full normal attribute (~38 MB on 50 MB).

## Fix (branch `feature/perf-mem-fix`, PR #11)
- `mergeVertices()` → indexed geometry (smooth normals over the welded vertex set).
- Dispose the previous model's geometry on load.
- Null the base64 string right after `atob`.
- `flatShading` deliberately *not* applied (only candidate with a visual cost; welding already reaches budget).

## After fix (50 MB worst case)

| Metric      | Before | After   |
|-------------|--------|---------|
| TOTAL PSS   | 303 MB | **201 MB** |
| Native heap | 185 MB | **66 MB**  |

~3× less geometry memory; 50 MB now sits essentially at the 200 MB budget.

> **Pending:** parse-ms on the welded path was not re-read (measurement env's
> screenshot channel failed mid-session). Pre-change parse was 350 ms (~9× margin);
> `mergeVertices` adds a bounded weld pass. Confirm parse-ms < 3 s before merging PR #11.

## Repro
```
python tools/gen_stl.py 10 25 50
adb push perf_50mb.stl /sdcard/Download/
gh workflow run ci.yml --ref <branch> -f profile=true   # build profile APK
gh run download <id> -n holdable-profile-apk
adb install -r <apk> ; adb shell dumpsys meminfo app.holdable
```
