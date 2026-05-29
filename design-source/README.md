# Holdable — Prism Studio (Prototype)

A high-fidelity, fully interactive prototype for a 3D file wallet app, built as plain HTML + CSS + JS. No build step, no dependencies. Open `index.html` in any browser.

## Files

```
index.html   — markup for the prototype (12 screens, one phone frame)
styles.css   — design tokens (dark + light), components, layout
app.js       — 3D engine, routing, theme toggle, model context, screen index
README.md    — this file
```

## Design system summary

**Voice.** Lean, precise, studio-professional. Speaks to a maker who'd compare this app to their CAD pipeline.

**Color tokens.** All themeable values live as CSS custom properties on the `.screen` element, switched via the `data-theme` attribute (`"dark"` or `"light"`). The iridescent gradient (`#FF5CB4 → #8B6CFF → #4FE0E5`) is the single brand accent and is identical in both themes.

**Typography.** Manrope (display & UI) + JetBrains Mono (technical labels, metadata, file specs). No serif.

**Surface treatment — Liquid Glass.** Library cards and the profile card use a layered effect:
1. Linear gradient fill (`--card-glass-1` → `--card-glass-2`)
2. `backdrop-filter: blur(20px) saturate(1.4)`
3. Top sheen highlight via `::before`
4. Iridescent gradient edge via `::after` (visible on hover)
5. Soft outer shadow + inset top highlight

This is what gives the cards their "popping out of the surface" feel; it works in both dark and light without modification.

## Screens (12)

| ID | Screen | Reached from |
|---|---|---|
| `ob1` | Welcome | initial |
| `ob2` | Import demo | ob1 Continue |
| `ob3` | Gesture intro | ob2 Continue |
| `lib` | Library | ob3 Enter studio |
| `viewer` | Model viewer (interactive 3D) | tap any card |
| `profile` | Profile, theme picker, storage, account | avatar in library |
| `search` | Search active state with recents | search bar in library |
| `import-sheet` | Bottom sheet — add a model | `+` FAB in library |
| `action-sheet` | Bottom sheet — model actions | `⋯` in viewer |
| `render` | Render presets + sliders | Render tab in viewer |
| `info` | Model specs, dimensions, tags | Info tab in viewer |
| `ar` | AR mode — coming soon | AR tab in viewer |

## Interactions

- **3D viewer** — drag the gem with mouse/touch to rotate (one finger), scroll-wheel or pinch to zoom, momentum decay on release, gentle auto-spin after 1.4s of idle.
- **Theme toggle** — small sun/moon icon in the library header, also a segmented Dark/Light control inside Profile. Toggles instantly with a 350ms cross-fade between token values.
- **Overlay sheets** — `import-sheet` and `action-sheet` are real overlays: the underlying screen stays rendered behind a blurred backdrop. Tapping the backdrop or Cancel dismisses without changing the underlay.
- **Model context** — clicking a library card threads the model id through viewer, action-sheet, and info; all metadata updates in sync.
- **Screen index** (right sidebar) — jump directly to any screen for review.

## Wiring map

Every clickable element has a `data-go="<screen-id>"` attribute or a `data-action` attribute (`theme`, `theme-seg`). The single click delegate in `app.js` routes by attribute — no per-button handlers.

Special attributes:
- `data-model="<id>"` on a card or chip — sets the active model before navigating
- `data-overlay="true"` on a screen — makes it render on top of the previous (non-overlay) screen
- `data-theme-set="dark|light"` — direct theme set (used in the Profile segmented control)
- `data-preset="<id>"` — toggles render preset selection without navigating

## Implementation notes for Claude Code

- The 3D engine is a hand-rolled SVG octahedron (`VERTS`/`FACES` arrays at the top of `app.js`). Swap for a real glTF viewer (e.g. `<model-viewer>`, three.js, or RealityKit on iOS) without touching the rest of the app.
- All theme values flow through CSS custom properties. To add a third theme, add another `.screen[data-theme="..."]` block in `styles.css`.
- The phone frame is purely cosmetic — `.phone` is `340 × 700`. The `.screen` inside is the actual app surface; on a real device you'd render only `.screen` contents.
- `data-overlay="true"` plus the routing logic in `app.js` mirrors how iOS sheet presentation works conceptually (source view stays in the hierarchy). Translate directly to `.sheet(...)` in SwiftUI or a portal'd modal in React.

## Acceptance checklist

- [x] All three onboarding screens reachable in order; `Get started` lands on Library.
- [x] Library renders 4 cards with the liquid-glass treatment in both themes.
- [x] Viewer's gem responds to drag and wheel; auto-rotates when idle.
- [x] Theme toggle flips every screen, including all overlays.
- [x] Every CTA in the prototype has a destination (no dead links).
- [x] Screen index sidebar jumps to any screen and reflects the active one.
