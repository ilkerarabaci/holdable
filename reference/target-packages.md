# Target Flutter Packages (pinned for alpha)

See `docs/tech-decisions.md` for the full list with rationale. Quick reference:

```yaml
# 3D
model_viewer_plus: ^1.9.0
# Fallback if needed:
# flutter_3d_controller: ^2.0.0
# babylonjs_viewer: ^0.0.3

# File handling
file_picker: ^8.0.0
receive_sharing_intent_plus: ^1.5.0
share_plus: ^10.0.0
path_provider: ^2.1.0

# Storage
shared_preferences: ^2.3.0
isar: ^3.1.0
isar_flutter_libs: ^3.1.0

# Image
flutter_image_compress: ^2.3.0

# State
flutter_riverpod: ^2.5.0

# Firebase (Crashlytics only in alpha)
firebase_core: ^3.0.0
firebase_crashlytics: ^4.0.0

# UI
google_fonts: ^6.2.0
lucide_icons: ^0.300.0
go_router: ^14.0.0
```

**Note:** Pin to the listed minimum-major and let `flutter pub upgrade` find compatible patches. Re-run `flutter pub get && flutter pub outdated` weekly during sprints.
