# W3 Perf Pass — Baseline (2026-05-31)

First profile-build performance measurement against the alpha budgets.

## Setup
- **Build:** `flutter build apk --profile` (CI `build-profile` job, `workflow_dispatch`).
- **Device:** `holdable_pixel7` AVD (1080×2400, x86_64, Android system image).
- **Fixtures:** synthetic UV-sphere binary STLs from `tools/gen_stl.py`, `adb push`ed to `/sdcard/Download/`, imported via the file picker.
- **Method:** parse-ms read from the in-app Info panel; memory via `adb shell dumpsys meminfo app.holdable` with the model loaded; cold start via `am start -W`.

## Budgets
- 50 MB STL parse **< 3 s**
- App PSS **< 200 MB**

## Results

| Model      | Triangles  | Parse   | TOTAL PSS | Native heap |
|------------|------------|---------|-----------|-------------|
| perf_10mb  | 209,304    | 76 ms   | 220 MB    | 59 MB       |
| perf_25mb  | 523,264    | 186 ms  | 271 MB    | 107 MB      |
| perf_50mb  | 1,046,904  | 350 ms  | 303 MB    | 185 MB      |

Cold start (profile, emulator): ~2.0–2.6 s.

## Verdict
- **Parse < 3 s — PASS (large margin).** 50 MB parses in 350 ms, ~9× under budget. Parse is *not* the bottleneck.
- **PSS < 200 MB — FAIL at every size.** Even the 10 MB model sits at 220 MB; 50 MB hits 303 MB (1.5× budget). `TOTAL SWAP PSS` climbs to ~29 MB at 50 MB → the system starts swapping under pressure.

Profile builds carry some VM-service overhead vs release (~20–40 MB), but the dominant cost is the **native heap**, which is three.js/WebView geometry — identical in release. Release would still clear 200 MB on large models.

## Root cause (from `assets/3d-engine/viewer.html` `loadModel`)
1. **Triple transient buffers held simultaneously** during load: `b64` (~67 MB for a 50 MB file) + `bin` binary string (~50 MB) + `bytes` Uint8Array (~50 MB). ~167 MB transient peak before V8 reclaims.
2. **Unindexed STL geometry** — STL has no vertex sharing, so positions = 3 × triangle count. 50 MB → 3.14 M vertices.
3. **`computeVertexNormals()` doubles geometry** by adding a full normal attribute (~38 MB on the 50 MB model).

## Candidate mitigations (not yet applied — for Architect sign-off)
| Fix | Est. saving | Cost |
|-----|-------------|------|
| Null out `b64`/`bin`/`bytes` ASAP + `__chunks` already cleared | trims transient peak | trivial |
| `material.flatShading = true`, drop `computeVertexNormals()` for STL | ~38 MB on 50 MB | trivial; flat look (fine for CAD/print) |
| `BufferGeometryUtils.mergeVertices()` → indexed geometry | up to ~6× on positions+normals | +CPU at load; needs welding tolerance |
| Soft cap + warning above ~30–40 MB for alpha | bounds worst case | product decision |

## Repro
```
python tools/gen_stl.py 10 25 50
adb push perf_50mb.stl /sdcard/Download/
gh workflow run ci.yml --ref <branch> -f profile=true   # build profile APK
gh run download <id> -n holdable-profile-apk
adb install <apk> ; adb shell dumpsys meminfo app.holdable
```
