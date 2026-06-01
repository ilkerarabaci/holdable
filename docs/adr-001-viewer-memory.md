# ADR-001 — How to get large models under the PSS budget

**Status:** Accepted — Option B (native renderer), versioned migration
**Date:** 2026-06-01
**Context:** W3 perf pass (`docs/perf-w3-baseline.md`)

## Decision (Architect, 2026-06-01)

Pursue **Option B — replace the WebView with `flutter_scene` (native Flutter GPU
renderer)** to remove the ~150–180 MB Chromium floor. Constraint: **version first.**
The working WebView alpha must stay intact and runnable as its own version; the
native renderer is a clean new version line, not an in-place rewrite.

Migration plan:
- **Freeze WebView alpha:** tag `v0.1.0-alpha-webview` at the current `main`, plus a
  permanent `release/0.1-webview` branch that always builds/runs the WebView viewer.
- **New version line:** `v0.2-native` long-lived branch; `flutter_scene` viewer built
  there behind the same `ViewerScreen` contract, merged to `main` only once it reaches
  feature parity (render modes, presets, thumbnails, theming, OBJ/STL).
- The size cap, import, library, onboarding, Prism theme, CI all carry over unchanged.

## Problem

The viewer hosts three.js in a `webview_flutter` WebView. Measured on a Pixel7
AVD (profile build):

| Model | TOTAL PSS | Budget |
|-------|-----------|--------|
| 10 MB | 188 MB ✓ | <200 MB |
| 25 MB | 179 MB ✓ | <200 MB |
| 50 MB | 247 MB ✗ | <200 MB |

Geometry optimizations (PR #11 weld, PR #12 conditional weld) cut native heap
hard (185→51 MB @ 50 MB) but **PSS still misses budget at 50 MB**. The reason is
structural: the **WebView (Chromium) + Flutter baseline is ~150–180 MB before any
model loads** — a well-documented webview_flutter cost (community reports put the
WebView overhead at ~150 MB vs ~15 MB for a bare native view). Geometry savings
can't bridge a floor that high.

Already shipped to bound the worst case: **soft 60 MB import size cap** (PR #13,
file-picker; PR #14, share-intent). That keeps users away from the cliff but
doesn't lower the floor.

## Options

### A. Accept it — revise the budget for a WebView viewer
Keep the architecture. Re-set the PSS budget to a realistic figure for a
WebView-based viewer (e.g. ~280 MB), and rely on the size cap for the tail.
- **Cost:** ~0. **Risk:** low. **Downside:** 200 MB target abandoned; large
  models still heavy on low-RAM devices.

### B. Replace WebView with a native renderer — `flutter_scene`
`flutter_scene` (Flutter GPU / Impeller, pure Dart) removes the WebView entirely,
erasing the ~150–180 MB Chromium floor. Impeller is already Flutter's default on
iOS/Android, so no extra native config.
- **Cost:** high. **Risks:**
  - `flutter_scene` + Flutter GPU are **preview / early state** (their own docs:
    "things may break").
  - It's glTF/PBR-oriented — **we'd write our own OBJ/STL loaders** (three.js gave
    us these for free).
  - Re-implements everything the viewer does today: render modes (solid/wire/x-ray),
    preset views, thumbnail capture, theming, orbit controls.
  - Web target (the design-reference PWA) would diverge (WebGL2 backend).
- **Upside:** lowest memory, best frame perf, and it's the most natural path to the
  **hero AR feature** (native GPU access) — so this may be revisited at v1.0/F3
  regardless.

### C. Hybrid — keep WebView, trim the floor
Stay on WebView but attack the baseline: dispose/recreate the WebView when leaving
the viewer (we already dispose geometry), cap `devicePixelRatio`, drop
`preserveDrawingBuffer` except during thumbnail capture, and consider a lighter
engine than full three.js.
- **Cost:** medium. **Risk:** medium. **Downside:** trims, doesn't remove, the
  floor — unlikely to get 50 MB under 200 MB on its own; best paired with A.

## Recommendation (for Architect)

For **alpha**, ship **A** (revise budget + rely on the size cap already in place) —
it's zero-cost and the size cap already prevents the pathological case. Treat **B
(flutter_scene)** as a **v1.0/F3 investigation**, bundled with the AR hero work,
since AR needs native GPU access anyway and that's where the WebView floor stops
being acceptable. **C** is only worth it if a mid-cycle memory complaint forces a
cheaper-than-B intervention.

Not pursued now: `flutter_3d_controller` — also WebView (Google model-viewer) and
no STL support, so it's a sideways move, not progress.
