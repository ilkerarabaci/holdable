# ADR-003 — AR strategy ("hold the model in your hand")

**Status:** PROPOSED — awaiting Architect (İlker) decision
**Date:** 2026-06-04
**Context:** v0.3 (Thermion/Filament) viewer is stable on main (alpha.12). AR is
the long-stated hero feature ("Your 3D, in your pocket. And in your hand."). This
ADR scopes how we get there and asks for a scope decision before any build.

## The hero, split into two honestly-different problems

- **AR-1 — Surface placement (achievable now).** Detect a real surface (floor /
  table) via the camera, place the model on it at real scale, walk around it,
  pinch-scale / rotate. This is standard ARCore (Android) / ARKit (iOS).
- **AR-2 — "Hold it in your hand" (research-grade, later).** Track the user's
  hand in the camera feed and lock the model to the palm with correct occlusion
  (fingers in front of the model). This needs real-time hand tracking
  (e.g. MediaPipe Hands) **plus** hand-mesh occlusion — heavy, device-dependent,
  no off-the-shelf Flutter path. This belongs with the **v1.0 / F3 cloud-ML
  phase** alongside `.blend` and photo→3D, not the alpha.

Conflating the two is how this feature stays "coming soon" forever. AR-1 is a
real, shippable milestone; AR-2 is an R&D bet.

## Constraint discovered (read from the pinned source)

**Thermion has no AR.** Grepping the pinned thermion checkout
(`%LOCALAPPDATA%\Pub\Cache\git\thermion-3831559…`) for `passthrough / arcore /
arkit / camera feed / plane / world tracking` returns nothing — it is a pure
Filament 3D renderer. So AR cannot be "turned on" in our existing viewer; it
needs a separate AR layer.

## Flutter AR landscape (2026)

- **`ar_flutter_plugin`** (CariusLars) — the canonical community plugin (ARKit +
  ARCore, loads glTF/GLB, built-in plane detection + placement + gestures).
  **Unmaintained since 2022**; built on Google **Sceneform**, which Google has
  **archived**.
- **Maintained forks** — `ar_flutter_plugin_2`, `ar_flutter_plugin_updated`,
  `ar_flutter_plugin_flutterflow`. These update Gradle/ARCore for Flutter 3.x;
  the active direction is moving off Sceneform to **SceneView (Android) 2.x**,
  which renders with **Google Filament** — the *same* engine as Thermion. Notable
  but they remain a **separate renderer** from our Thermion viewer.
- **`arcore_flutter_plugin`** (Android-only) + **`arkit_plugin`** (iOS-only) —
  lower-level, two codebases, more glue.
- **Platform-native AR via PlatformView** — maximum control, maximum work
  (write ARCore + ARKit hosts ourselves).

All AR-1 options load **glTF/GLB**. Our models are **.obj/.stl** — so any path
needs an **OBJ/STL → GLB export** step.

## Architecture options for AR-1

### Option X — AR plugin's own renderer (recommended for AR-1)
Use a maintained `ar_flutter_plugin` fork. On "View in AR", export the current
model to a temporary `.glb` and hand it to the plugin; it does plane detection,
placement, and gestures.
- **Pros:** the established path; plane detection + anchors + gestures are
  built-in; least custom code; cross-platform (ARKit + ARCore) from one API.
- **Cons:** a **second renderer** (our Thermion render modes/material don't carry
  into AR — AR shows a plain lit GLB); **dependency/Gradle risk** (the fork's
  Android stack — Sceneform/SceneView — alongside our thermion native build +
  the `file_picker 8.1.0` pin); needs the **GLB exporter**; ARCore requires a
  *Google Play Services for AR*-capable device.

### Option Y — Thermion-composite (keep our renderer)
Get only a **camera pose + plane stream** from a thin native ARCore/ARKit
channel, drive Thermion's Filament camera from that pose, and composite the
Thermion model (transparent background) over the live camera texture.
- **Pros:** one renderer — our materials / render modes / lighting carry into AR;
  no GLB needed.
- **Cons:** **much** more work and fragile — we own pose handling, the camera
  texture composite, lighting estimation, and occlusion; no plane-detection UI
  for free. High schedule risk for an alpha.

## Recommendation

1. **Ship AR-1 only; defer AR-2** (hand-tracking) to the v1.0/F3 cloud-ML phase.
2. **Take Option X** (a maintained `ar_flutter_plugin` fork) for AR-1 — fastest
   credible path to "place it on the table and walk around it."
3. **De-risk with a thin spike FIRST**, because the real risk is the Android
   build, not the AR: a new branch that only (a) adds the chosen fork, (b) builds
   a debug APK in CI alongside thermion + file_picker, (c) shows a bare AR view.
   If the Gradle/native stack conflicts, we learn it in one CI run, cheaply —
   mirroring how the thermion de-risk was front-loaded.
4. **GLB export**: reuse the renderer-agnostic `model_parser.dart` `MeshData`
   (positions/normals/indices) and write a minimal binary-glTF (`.glb`) exporter
   (pure Dart, unit-testable) — small and self-contained, like the STL writer was.
5. **Versioning** (mirrors prior lines): build AR on a branch behind a "View in
   AR" entry that is hidden unless `ARCore/ARKit` is available (we already have a
   `holdable/gpu` MethodChannel pattern to copy for an `holdable/ar` capability
   check). Merge to main only when AR-1 is device-verified on the S26 Ultra.

## Open questions for the Architect

- **Scope:** AR-1 (surface placement) for the alpha, AR-2 (hold-in-hand) to v1.0
  — agreed? Or is AR-1 also a post-alpha item (the alpha ships without AR)?
- **Renderer trade-off:** is it acceptable that AR shows a plainly-lit GLB
  (Option X) rather than our Thermion render modes (Option Y's cost is large)?
- **Accounts/devices:** AR-1 needs an ARCore-capable Android device (the S26
  Ultra qualifies) and, for iOS, an Apple Developer account + an ARKit device —
  iOS AR is gated on the same account work as TestFlight (ADR backlog).

## Decision

_Pending._ Once decided, the first concrete step is the **build-compat spike**
(step 3) — no product code until we know the chosen plugin builds with our stack.
