# ADR-002 — Renderer reassessment after the native (flutter_scene) experiment

**Status:** ACCEPTED — Option C (Thermion/Filament) as the newest version line
**Date:** 2026-06-02
**Supersedes consideration of:** ADR-001 (native renderer via flutter_scene)
**Context:** v0.2-native built + device-tested on a real Vulkan phone (Galaxy S26 Ultra)

## Why we're reopening the decision

ADR-001 chose native `flutter_scene` to remove the WebView's ~150–180 MB
Chromium floor. We built it end-to-end (PRs #15–#21): dependency + Impeller/GPU
enable, our own OBJ/STL parser, a native `ViewerScreen` with full feature parity
(solid / wireframe / x-ray, presets, orbit, thumbnails, Prism chrome), a
Vulkan-support gate, and an in-app PSS readout. It **renders correctly** on a
real Vulkan device and the parser is fast (50 MB / 1 M-tri STL parses in ~500 ms
vs the old WebView weld path's 3594 ms).

**But on-device memory measurement (in-app `Debug.getMemoryInfo`, profile build,
S26 Ultra) revealed a blocker.**

## What we measured (alpha.5, profile, S26 Ultra)

| Model | tris | PSS | GRAPHICS | NATIVE | DART | CODE |
|-------|------|-----|----------|--------|------|------|
| Cube | 12 | 380 MB | 260 MB | 35 | 10 | 18 |
| Icosahedron | 20 | 415 MB | 310 MB | 25 | 9 | 18 |
| bitki.obj | 79,768 | 1202 MB | **1026 MB** | 34 | 3 | 19 |

(alpha.4, before the per-frame `image.dispose()` fix, bitki.obj was **1924 MB
PSS / 1747 MB GRAPHICS** — the fix saved ~720 MB but did not solve it.)

**Reading:**
- ✅ **App-logic memory is excellent: ~56 MB** (NATIVE+DART+CODE). The original
  ADR-001 premise — kill the Chromium CPU floor — is fully achieved. WebView's
  ~180 MB floor is gone.
- ❌ **GPU memory (GRAPHICS) is the new, larger problem:** 260 MB for a *cube*,
  ~1 GB for an 80 K-tri / 5.6 MB model. Our geometry is ~2.5 MB, IBL textures
  ~15 MB, render targets ~40 MB (MSAA already disabled) — the rest (200 MB–1 GB)
  is the Impeller/flutter_gpu Vulkan allocator, and it grows with use.

## Root cause — this is an Impeller engine limitation, not our code

This is a **known, unsolved Flutter engine issue**, confirmed by upstream:
- [flutter/flutter#178264](https://github.com/flutter/flutter/issues/178264) —
  "Impeller retains textures longer than Skia, preventing recovery even when Dart
  resources are freed"; GL memory balloons to 3–4 GB then OOM-crashes. The
  proposed fix (`reduceGpuMemoryUse()` + GPU stats + pressure callbacks) is
  **proposed only, P2, not implemented, no timeline.** Existing workarounds
  "only delay crashes."
- [flutter/flutter#131001](https://github.com/flutter/flutter/issues/131001),
  [#161861](https://github.com/flutter/flutter/issues/161861) — Android Impeller
  Vulkan fails to release graphics memory, eventually crashes.
- `flutter_scene` changelog 0.9.2 → 0.15.0 has **no GPU-memory fix** — upgrading
  (which would also force the master channel) would not help.

We mitigated what we could from Dart (disable MSAA, on-demand rendering, dispose
the per-frame `ui.Image` that `Scene.render` leaks) — each helped, none fixed the
floor, because the retention is inside Impeller.

**Consequence:** the app's hero use case (import & view large models, up to the
60 MB cap) would OOM on real devices with native flutter_scene today. The native
renderer traded a bounded ~180–300 MB CPU floor for an unbounded GPU floor.

## Options

### A. Ship the frozen WebView alpha (v0.1) to testers now
- **Pros:** works today, bounded memory (10 MB=188, 25 MB=179, 50 MB=247 MB PSS,
  capped at 60 MB import), already built/tagged (`v0.1.0-alpha-webview`). Unblocks
  TestFlight/Play Internal distribution immediately.
- **Cons:** Chromium floor remains; 50 MB models slightly over a 200 MB target;
  not the AR-ready hero path.

### B. Stay on flutter_scene, wait for the Impeller fix
- **Pros:** keeps all v0.2 work; app-logic memory is already tiny; AR-ready;
  native.
- **Cons:** blocked on an upstream engine fix with **no timeline** (#178264).
  Can't ship the memory-sensitive alpha until then. High schedule risk.

### C. Pivot the native renderer to Thermion (Google Filament)
- [Thermion](https://thermion.dev/) wraps Google's **Filament** PBR engine via
  Dart FFI. Filament manages its **own** GPU memory (not via Impeller/flutter_gpu),
  so it sidesteps the #178264 blocker; it's production-grade (used widely) and
  AR-friendly.
- **Pros:** real native renderer with mature memory management; keeps the native
  strategy + hero path.
- **Cons:** glTF-only (we'd convert OBJ/STL → glTF at import — our parser output
  maps cleanly to glTF buffers); heavy native FFI dependency; larger app size;
  adoption + re-test cost. Linux unmaintained (irrelevant for us).

## What carries over regardless of choice

The OBJ/STL **parser** (`model_parser.dart`, 20 tests), the `ViewerScreen`
chrome/contract, the import/library/onboarding/Prism/CI/size-cap, the Vulkan
gate, and the in-app PSS readout are all **renderer-agnostic** and reused under
any option (B keeps them as-is; C feeds the parser output into Filament; A is the
existing WebView path).

## Recommendation (for the Architect)

**Hybrid:** ship **Option A (WebView v0.1)** for the alpha now so testers are
unblocked, and pursue **Option C (Thermion/Filament)** as the strategic native
renderer that actually solves the memory budget. Treat **B** as a fallback to
revisit only if/when Impeller ships `reduceGpuMemoryUse()` (#178264). Keep
`v0.2-native` and all renderer-agnostic work intact.

## Decision (Architect, 2026-06-02)

**Adopt Thermion (Filament) as the newest version line (v0.3), keeping the prior
lines for rollback.** Versioning, mirroring ADR-001:
- **v0.1 WebView** — `v0.1.0-alpha-webview` + `release/0.1-webview` (kept).
- **v0.2 flutter_scene** — frozen at tag `v0.2.0-alpha-flutterscene`, branch
  `v0.2-native` retained (kept, recoverable).
- **v0.3 Thermion** — new branch `v0.3-thermion` (pubspec `0.3.0+1`); build the
  Filament-based viewer behind the same `ViewerScreen` contract, reusing the
  renderer-agnostic OBJ/STL parser, gate, in-app PSS readout, and chrome. Merge
  to `main` only at feature parity AND a verified memory budget on a real device.

If Thermion doesn't pan out (memory, complexity, OBJ/STL→glTF), we can roll back
to v0.2 (flutter_scene) or v0.1 (WebView). The WebView v0.1 remains the
fallback for distributing an alpha if needed.

