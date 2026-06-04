# dist — local version APKs

Physical copies of the built **profile** APKs for each renderer version line, kept
here for quick on-device comparison and rollback without re-downloading. These are
**not** committed to git (large binaries — see `/dist/*.apk` in `.gitignore`); the
canonical artifacts live on **GitHub Releases**:
<https://github.com/ilkerarabaci/holdable/releases>

| File | Version line | Renderer | Notes |
|------|--------------|----------|-------|
| `holdable-v0.2.0-alpha5-profile.apk` | v0.2 | flutter_scene (Impeller GPU) | Renders, but GPU memory floor (~1 GB on bitki.obj) — frozen, ADR-002 |
| `holdable-v0.3.0-alpha.1-profile.apk` | v0.3 | Thermion (Google Filament) | Active line. bitki.obj GRAPHICS ~310 MB vs flutter_scene's ~1026 MB |

Profile builds are used because they give representative memory (debug inflates).
To refresh after a green CI build:

```sh
gh release download <tag> -D dist --clobber
```

Earlier lines:
- **v0.1 WebView** — tag `v0.1.0-alpha-webview`, branch `release/0.1-webview` (no APK kept here).
- Full v0.2 series (`v0.2.0-alpha.1`–`5`) on GitHub Releases.
