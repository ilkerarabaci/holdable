# Tech Decisions — Holdable Alpha

## Framework
**Flutter** (latest stable, 3.x at time of writing). Single codebase iOS + Android. Dart 3.x.

## Recommended pubspec.yaml packages

### Core
```yaml
dependencies:
  flutter:
    sdk: flutter
  
  # 3D rendering (alpha viewer)
  model_viewer_plus: ^1.9.0     # WebView wrapper of <model-viewer>; glTF/GLB + AR quick look
  # NOTE: STL & OBJ must be converted to glTF for model_viewer_plus.
  # Two options:
  #   (a) Client-side via three.js loaders inside the same WebView (recommended for alpha)
  #   (b) Server-side via Blender container (deferred to v1.0)
  # We'll prototype (a) first. If perf is bad, fall back to flutter_3d_controller.
  
  # File import
  file_picker: ^8.0.0           # iOS Files + Android SAF
  receive_sharing_intent_plus: ^1.5.0  # iOS Share Sheet + Android Open With
  share_plus: ^10.0.0           # Outbound share
  
  # Persistence
  path_provider: ^2.1.0         # App documents directory
  shared_preferences: ^2.3.0    # Theme preference, onboarding-shown flag
  isar: ^3.1.0                  # Local DB for model metadata (alternative: drift)
  
  # Image
  flutter_image_compress: ^2.3.0  # Thumbnail compression
  
  # State management
  flutter_riverpod: ^2.5.0      # Or provider, or bloc — pick one and stick
  
  # Firebase (alpha: Crashlytics only)
  firebase_core: ^3.0.0
  firebase_crashlytics: ^4.0.0
  
  # UI helpers
  google_fonts: ^6.2.0          # Manrope + JetBrains Mono dynamic load
  lucide_icons: ^0.300.0        # Icon system (Lucide)
```

### Dev / test
```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  build_runner: ^2.4.0
  isar_generator: ^3.1.0
```

## Suggested file structure
```
lib/
├── main.dart                    # App entry, theme, routing
├── app/
│   ├── theme.dart               # Color tokens (Prism palette), text styles
│   ├── routes.dart              # Route definitions
│   └── providers.dart           # Riverpod global providers
├── features/
│   ├── onboarding/
│   │   ├── presentation/        # 3 screens
│   │   └── data/                # "onboarding_shown" flag
│   ├── library/
│   │   ├── presentation/        # Grid, list, empty state
│   │   ├── domain/              # Model entity
│   │   └── data/                # Isar repository + thumbnail cache
│   ├── import/
│   │   ├── presentation/        # Bottom sheet (Files / URL / Sample)
│   │   └── data/                # File picker + share intent handlers
│   ├── viewer/
│   │   ├── presentation/        # 3D viewer screen + controls
│   │   └── data/                # 3D engine wrapper
│   └── settings/
│       └── presentation/        # Theme toggle, about, version
└── shared/
    ├── widgets/                 # Reusable components (PrismCard, FAB, etc.)
    ├── utils/                   # File size formatter, etc.
    └── constants/               # Brand colors, etc.

assets/
├── fonts/                       # Manrope, JetBrains Mono (or use google_fonts)
├── icons/                       # Custom Holdable cube icon
├── sample_models/               # CC0 .obj + .stl from Poly Haven / NASA (max 3-5)
└── 3d-engine/                   # Bundled three.js + loaders for WebView 3D
```

## Architecture decisions

### State management: **Riverpod**
Why: type-safe, scoped, modern. Provider is its predecessor; Bloc is heavier ceremony. We're solo — Riverpod is the right balance.

### 3D rendering: **model_viewer_plus + custom OBJ/STL loaders in WebView**
Why: ships fastest. The WebView underneath is the same `<model-viewer>` Google ships. Inject three.js OBJLoader + STLLoader to convert on the fly inside the WebView, then feed to model-viewer. If perf is bad on big STLs, fall back to:
- Thermion (native Filament) — v2 upgrade, much more work
- OR pure HTML/CSS/SVG mock for early alpha (last resort)

### Storage: **Isar (local NoSQL)**
Why: fast, type-safe, no SQL ceremony. Drift is the SQL alternative.

### Theming: **Dark default + Light toggle**
Implementation via `ThemeData` + a `themeProvider` (Riverpod). Persist to `shared_preferences`.

### Routing: **go_router** (or named routes via Navigator 2.0)
Why: deep links + future "share a model" deep-link prep.

## Performance budgets (alpha)
- App cold start to onboarding: < 1.5 s on iPhone 12
- App cold start to library: < 2.0 s on iPhone 12
- 50MB STL import → first render: < 3.0 s
- Library scroll: 60 fps with 50 thumbnails
- Memory cap: < 200 MB resident during normal use; OOM warning over 200MB

## What NOT to do in alpha
- No GCP / Firebase Functions / Cloud Run usage (cost cap)
- No analytics (Crashlytics only)
- No auth / accounts
- No cloud upload
- No `.blend` handling
- No AR module (UI placeholder OK, code stubbed)
- No IAP code
- No internationalization yet (English only)
