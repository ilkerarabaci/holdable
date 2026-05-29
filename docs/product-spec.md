# Holdable — Product Spec (condensed for Claude Code)

## One-line definition
A mobile "3D file wallet" — designers / makers import, view, and organize 3D models on their phone. Tagline: *"Your 3D, in your pocket. And in your hand."*

## Target users (alpha)
- P1: Industrial / product / interior designers (primary)
- P2: 3D-print makers + hobbyists (secondary)

## Alpha scope (Week 1-2)
**MUST in alpha:**
- Import `.obj` and `.stl` from iOS Files / Android SAF, via Share Sheet / Open With
- 3D viewer: one-finger rotate, pinch zoom, three-finger pan, preset views (Front/Top/Side/Iso)
- Render modes: Solid / Wireframe / X-ray
- Model info panel: vertex count, face count, file size, format
- Library (grid + list view): thumbnail-based, model rename, delete
- Onboarding: 3 screens (drop on app launch only)
- Empty state: "Your shelf is empty. Drop a .obj or .stl to begin."
- Local-only storage (path_provider)
- Auto thumbnail generation (RepaintBoundary.toImage → 256px webp)
- Crash reporting (Firebase Crashlytics) — only crash, no analytics yet
- TestFlight + Internal Testing build pipeline

**NOT in alpha (defer to v1.0):**
- `.blend` support (needs Cloud Run + Blender — F3)
- AR mode (hero feature — needs hand-tracking POC first — F3)
- Cloud sync (defer; design for it but don't build)
- IAP / paywall (revisit at launch)
- AI-powered search (v2 roadmap)
- Folders / collections / search (defer to v1.0)

## v1.0 scope (Week 3-5, after alpha)
- + `.blend` via Cloud Run Blender container
- + AR mode with hand-tracking (HERO FEATURE — patron's vision)
- + App Store + Play Store submission
- + Settings screen with theme toggle (already in design)

## Hero feature for v1.0 (NOT alpha)
AR mode + hand-tracking: user moves hand → model follows (6DoF). Pinch to grab, wrist-rotate to rotate, two-hand stretch to scale. iOS Vision `VNHumanHandPoseRequest` + ARKit / Android ARCore + MediaPipe Hands. 1-day POC spike required before commit.

## Cost discipline
- $10/sprint cap on out-of-pocket spend (GCP, domain, tools — NOT Claude tokens)
- Patron's $200/mo Max plan covers token usage
- No GCP usage in alpha (local-only)

## Differentiation thesis
"Personal 3D file wallet" — owns the white space between pro CAD viewers (eDrawings, CAD Assistant — engineer-coded) and single-format toys (Fast STL Viewer — ad-noise). Designer-friendly wallet UX + .blend + hand-tracking AR is genuine white space per 8-competitor analysis.

## Brand essentials
- Name: **Holdable**
- Hero tagline: *"Your 3D, in your pocket. And in your hand."*
- Voice: designer-empath, lean, precise. NOT engineer-coded, NOT AI-trendy, NOT crypto.
- Visual system: see `design-handoff.md`.
