# Sprint 1 (W1) — Goal & Acceptance

**Sprint window:** ~5 working days
**Goal:** Working Flutter app skeleton with onboarding + library shell + theme system on both iOS Simulator and Android Emulator.

## Day-by-day target

| Day | Deliverable |
|---|---|
| D1 | Flutter project setup, pubspec.yaml, lib/ structure scaffolded, theme tokens (dark + light), Manrope + JetBrains Mono loaded, runs on both simulators |
| D2 | Onboarding 3 screens, page dots, Continue CTA, "onboarding shown" flag persisted |
| D3 | Library shell (empty state), FAB → import bottom sheet stub, profile icon → settings stub |
| D4 | File picker integration (.obj + .stl), basic file copy to app docs dir, model card rendering in library (placeholder thumbnail) |
| D5 | Share-Intent integration (iOS Share Sheet + Android Open With), Crashlytics wired, light/dark toggle working, polish + commit + PR |

## Acceptance criteria (W1 demo)

End of W1, on both simulators (and ideally on patron's actual iPhone via Personal Team signing):

- [ ] App opens → onboarding 3 screens → Library
- [ ] Onboarding shown only once (flag persisted)
- [ ] Library shows empty state when no models
- [ ] FAB tap → bottom sheet appears with Files / URL (stub) / Sample (stub)
- [ ] "Files" picks an .obj or .stl, copies to app docs, card appears in library
- [ ] Long-press model card → action sheet (Open, Rename, Delete, Share — all stubs except Delete)
- [ ] Delete works; library updates
- [ ] Theme toggle in profile → entire app rebuilds dark ↔ light with 350ms cross-fade
- [ ] On crash, Crashlytics receives report
- [ ] App runs on iOS Simulator + Android Emulator (Pixel 7 API 34)
- [ ] No `print()` statements left in code
- [ ] `flutter analyze` returns 0 warnings
- [ ] At least 5 widget tests pass

## Out of scope for W1 (defer to W2)

- 3D viewer (the hardest piece — W2)
- Thumbnail generation
- Bottom sheet "URL" and "Sample" actions
- Share outbound
- Polish: animations, micro-interactions

## W1 review questions to answer

1. Does model_viewer_plus actually handle .obj + .stl via injected three.js loaders? If not, what's plan B?
2. iOS Simulator share-sheet doesn't work — verified on real device?
3. iOS Personal Team signing — can patron install on his iPhone XR / 14 / whatever via Xcode for free testing?

Decisions blocking W2: viewer engine confirmation (model_viewer_plus or fall back to Thermion/babylonjs_viewer).
