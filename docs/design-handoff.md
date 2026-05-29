# Design Handoff — Prism Studio System (from Claude.ai/Design D0 wildcard direction)

> **Source of truth:** `design-source/` folder in this package — HTML/CSS/JS prototype with all 12 screens, dark/light themes, working interactions. Open `design-source/index.html` in any browser. README inside it documents every design token, component, and interaction.

## Color tokens

All themeable values live as CSS custom properties; in Flutter, translate to `ThemeData` extension or `colors.dart` constants. The iridescent gradient is the SINGLE brand accent and is identical in dark + light.

### Brand
- **Iridescent gradient:** `#FF5CB4 → #8B6CFF → #4FE0E5` (linear, 0% / 50% / 100%) — used for: brand mark, hero CTA edge highlight, library card hover ::after edge

### Dark theme (default)
- bg: `#0E0E10`
- surface: `#1A1A1F`
- text-primary: `#F5F5F7`
- text-muted: `#8A8A95`
- border-hairline: `rgba(255,255,255,0.08)`
- card-glass-1: `rgba(255,255,255,0.04)`
- card-glass-2: `rgba(255,255,255,0.02)`

### Light theme
- bg: `#F4F2EE`
- surface: `#FFFFFF`
- text-primary: `#1A1A1C`
- text-muted: `#5A5A5E`
- border-hairline: `rgba(0,0,0,0.08)`
- card-glass-1: `rgba(255,255,255,0.85)`
- card-glass-2: `rgba(255,255,255,0.6)`

## Typography

- **Display & UI:** Manrope (400, 500, 600, 700, 800)
- **Technical / specs / metadata:** JetBrains Mono (400, 500, 700)
- **NO serif anywhere.**

Use `google_fonts: ^6.2.0` package to load dynamically, or bundle .ttf in `assets/fonts/`.

### Scale (Flutter `TextTheme`)
- displayLarge: 28 / Manrope 700 / -0.02em
- displayMedium: 22 / Manrope 700 / -0.02em
- titleLarge: 18 / Manrope 600 / -0.01em
- bodyLarge: 15 / Manrope 500
- bodyMedium: 13 / Manrope 500
- labelSmall: 11 / JetBrains Mono 500 / +0.04em / uppercase
- monoBody: 13 / JetBrains Mono 500

## Component patterns

### Liquid Glass card (library cards, profile card)
1. Linear gradient fill: `card-glass-1` → `card-glass-2`
2. `backdrop-filter: blur(20px) saturate(1.4)` — **Flutter equivalent:** `BackdropFilter(filter: ImageFilter.blur(sigmaX:20, sigmaY:20), child: ...)` with translucent overlay
3. Top sheen `::before` highlight — replicate with `Stack` + `Container(gradient: LinearGradient(...))`
4. Iridescent edge `::after` on hover — for Flutter, animate on press
5. Soft outer shadow + inset top highlight

**Android perf note:** `BackdropFilter` is expensive. Use it ONLY on the library cards (max ~6 on screen). For long lists, render thumbnails without blur. Test on a mid-tier Android (Samsung A52 class) before committing.

### Phone shell (only relevant for prototype, NOT for Flutter app)
The prototype wraps content in a 340×700 phone frame for desktop preview. In Flutter, just render `Scaffold` full-screen — the OS provides the device chrome.

## Interactions

- **3D viewer:** drag (1-finger) rotate, pinch zoom, momentum decay on release, gentle auto-spin after 1.4s idle.
- **Theme toggle:** sun/moon icon in library header. 350ms cross-fade between token values.
- **Bottom sheets:** import sheet, action sheet — render OVER current screen with blurred backdrop. Tapping backdrop dismisses without changing underlay.
- **Screen index:** prototype-only sidebar (not in app).

## 12 screens in the prototype

| ID | Screen | Notes for Flutter implementation |
|---|---|---|
| ob1 | Welcome / "Hold the work, not the format" | Splash → straight to onboarding on first launch |
| ob2 | Import demo / "Drop one in." | ⚠️ Mentions .blend — ALPHA: replace with .obj + .stl + "more soon" badge |
| ob3 | Gesture intro / "Spin it, squeeze it." | "Enter studio" → library |
| lib | Library — 4 cards, header + counter | ⚠️ Statically dolu in prototype; build empty state for first-time |
| viewer | Model viewer (interactive 3D) | Bottom toolbar: View / Render / Info / AR (AR with "SOON" badge in alpha) |
| profile | Profile, theme picker, storage, account | Profile icon top-right in library — opens this |
| search | Active search with recents | Search bar in library header |
| import-sheet | Add a model bottom sheet | FAB triggers; offer Files / URL / Sample (CC0 bundle) |
| action-sheet | Model actions: open, share, rename, delete | Long-press on card |
| render | Render presets + sliders | Render tab in viewer |
| info | Specs, dimensions, tags | Info tab in viewer |
| ar | AR mode | ⚠️ Just "coming soon" in prototype — ALPHA: stub the screen entirely, link disabled |

## Alpha-scope adjustments to the prototype

These were flagged in design review — implement these deviations, not the prototype as-is:

1. **Remove `.blend` from ob2** — alpha only supports `.obj` + `.stl`. Add a "More formats coming in v1.0" microcopy.
2. **Empty state for library** — design + ship; prototype's "34 models · 218 mb" is the populated state.
3. **AR screen + Render tab disabled in alpha** — show but visually muted with "SOON" badge. Don't wire actions.
4. **Sample models bundled** — `assets/sample_models/` with 3-5 CC0 .obj/.stl files from Poly Haven / NASA. Surface in import-sheet as "Sample models".
5. **Liquid glass fallback** — `@supports not (backdrop-filter)` → flat surface for Android low-end.

## What to ship in alpha (visual fidelity)

- ✅ Iridescent gradient on splash + brand marks + hero CTA edge
- ✅ Dark default + Light toggle
- ✅ Liquid glass on library cards (iOS + mid+ Android)
- ✅ Manrope + JetBrains Mono via google_fonts
- ✅ Octahedron / placeholder 3D shape during loading
- ✅ Bottom sheet pattern for Add Model + Model Actions
- ⛔ Render tab — show, but disabled
- ⛔ AR tab — show "SOON" badge, disabled
- ⛔ Search — defer to v1.0
- ⛔ Profile screen — minimal version OK (theme toggle + version + privacy link)
