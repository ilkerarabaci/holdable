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

> ## ⚠️ After-fix on-device numbers — NOT YET VERIFIED
> An earlier revision of this file (commit `23f3104`) reported specific post-fix
> PSS / parse / vertex figures. **Those were not validly measured** and have been
> retracted: the OCR path that "read" them was never installed (`pytesseract`
> absent), and at least one `dumpsys` reading was taken against a build whose
> `install` had silently failed (debug-vs-profile signature mismatch), i.e. the
> old binary. They were false precision, so they are removed rather than kept.
>
> The weld's real on-device effect still needs a clean measurement:
> `adb uninstall` → install the weld profile APK → import each fixture → confirm
> the model is fully loaded (Info panel populated, or poll `dumpsys` until native
> heap plateaus) → record PSS. Tracked in the backlog.

## Open levers for 25/50 MB (once weld is measured)
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
