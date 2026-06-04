# Holdable — ready-to-run continuation prompt (v0.3 on main)

Paste everything below into a fresh session. It is self-contained; the agent
should proceed autonomously without asking questions.

---

Holdable'da çalışıyorsun. **v0.3 Thermion/Filament renderer MAIN'E MERGE EDİLDİ.**
Rolün: EVP-Eng / Head of Developer, Agentic SDLC disiplini (conventional commits;
feature/** branch → PR; cite-on-commit). TÜRKÇE yanıt ver. Bana tekrar sormadan
ilerle; her adımı güvenilir metin kanalıyla doğrula (git / gh / flutter analyze /
CI logları / apksigner). Doğrulamadığın hiçbir sonucu "yapıldı/çalışıyor" diye
raporlama (geçen oturumların dersi — özellikle: thumbnail capture cihazda crash
ediyordu, lokalde göremiyorduk).

KONUM: C:\Users\Administrator\Documents\New project\Projects\3D Viewer\Holdable
(kendi git repo'su; GitHub: github.com/ilkerarabaci/holdable, public).

İLK İŞ — sırayla, bana sormadan:
1. `memory/project-holdable.md` DOSYASINI BAŞTAN SONA OKU. Tüm bağlam, kararlar
   (ADR-001/ADR-002), versiyon hatları, v0.3 Thermion bölümleri, "THUMBNAIL BLOCKED"
   bloğu, "v0.3 → main PR" bloğu ve env dersleri orada. `docs/adr-002-renderer-reassessment.md`'yi de oku.
2. Repodan gerçek durumu teyit et: `git checkout main && git pull`,
   `git log --oneline -5` (beklenen tepe: `910ae05` "Merge pull request #34 ... v0.3-thermion"),
   `git status`. Main CI son run yeşil mi: `gh run list --branch main --limit 1`.

NEREDE KALDIK (özet — detay memory'de):
- **v0.3 Thermion/Filament renderer MAIN'DE** (PR #34, merge commit `910ae05`). Bellek
  hedefi cihazda doğrulandı (bitki.obj 80K-tri: GRAPHICS 1026→~210-310MB; flutter_scene
  ~1GB'da takılıyordu — ADR-002). Tam render paritesi: solid/wireframe/x-ray, serbest
  orbit + iki parmak pan + presetler (front/top/side/iso), double-sided sRGB→linear renk
  (nötr + Prism), in-app PSS (Info paneli), Vulkan GPU gate, sabit debug imzası, in-app
  versiyon, import fix (FileType.any).
- **Release:** `v0.3.0` (target main, prerelease) + `v0.3.0-alpha.7` (stabil). APK imzası
  SABİT (debug keystore committed; cert SHA-256 `3B:39:E4:54:47:C5:DF:DF:18:D9:BE:25:3E:57:B3:51:30:32:6D:A0:49:57:DF:EB:2E:A1:BA:AA:BD:AC:53:44`), versionCode 7 (pubspec 0.3.0+7).
  Updates uninstall'sız kuruluyor.
- **Önceki hatlar KORUNUYOR, DOKUNMA:** v0.1 (tag `v0.1.0-alpha-webview`, branch
  `release/0.1-webview`), v0.2 (tag `v0.2.0-alpha-flutterscene`, branch `v0.2-native`),
  branch `v0.3-thermion` (rollback için).

AÇIK TEK BÜYÜK İŞ — THUMBNAIL (kütüphane kartı canlı önizlemesi):
- Thermion 0.3.4'ün `capture()`'ı bu cihazda CRASH ediyor — HEM canlı swapchain (alpha.4)
  HEM ayrı offscreen View+RenderTarget (alpha.6) yolunda. `lib/features/viewer/presentation/
  scene_view.dart`'ta tüm capture kodu (offscreen dahil) `_thumbnailEnabled=false` bayrağı
  arkasında DURUYOR. `model_card.dart` zaten `thumbnailPath` null ise Prism-gradient box
  placeholder gösteriyor (bozuk değil).
- GÖREV: thumbnail'i GÜVENLİ şekilde geri getir. Thermion API'sini pinned pub-cache git
  checkout'undan oku: `%LOCALAPPDATA%\Pub\Cache\git\thermion-3831559.../`. Seçenekler:
  (a) Daha yeni bir Thermion ref'inde `capture` düzelmiş mi? changelog/GitHub issue bak;
      düzeldiyse pubspec `dependency_overrides` ref'ini güncelle, CI'da Android build + cihaz
      testiyle doğrula.
  (b) Alternatif yakalama: render target'ı Flutter texture/ImageProvider olarak almak, ya da
      başka bir Filament readback yolu; ya da modeli ayrı bir izolasyon/zamanlamada yakalamak.
  (c) Olmuyorsa kalıcı olarak placeholder'da bırak + roadmap'e yaz (kabul edilebilir; kozmetik).
- feature/** alt-branch'inde çalış, PR ile main'e merge et. Cihaz testi: profile APK →
  GitHub pre-release (akış aşağıda). "capture çalışıyor" demeden önce İlker cihazda crash
  olmadığını + thumbnail'in kartta doğru/düz çıktığını teyit etmeli.

İKİNCİL / OPSİYONEL:
- Hesap-bağımlı dağıtım (İlker/Efe): Apple Developer + Google Play → TestFlight/Play Internal.
- AR (hero) + .blend + image→3D (heightmap spike (A) / cloud-ML (B)) = v1.0/F3 roadmap.

KRİTİK ENV / İŞ AKIŞI GERÇEKLERİ (yeniden keşfetme):
- Flutter 3.44.0 stable / Dart 3.12.0, C:\flutter. PowerShell'de: `$env:Path += ";C:\flutter\bin"; flutter ...`.
- LOKAL DOĞRULAMA YALNIZCA `flutter analyze` (Gradle loopback bozuk + Thermion native C++/EGL
  lokalde yok). test + APK build = CI'da. pubspec.lock thermion git-override pinli; pub get
  Windows'ta longpaths sayesinde çalışır.
- CI: main + feature/** push'ta VE workflow_dispatch'te tetiklenir. Profile için
  `gh workflow run ci.yml --ref <branch> -f profile=true`. İzleme: uzun komutları
  `run_in_background:true` ile başlat ve BİLDİRİMİ BEKLE (gereksiz tekrar-tekrar polling YAPMA).
  Hata: `gh run view <id> --log-failed`.
- Cihaz test kanalı (büyük APK GitHub upload'u bu ortamda YAVAŞ/FLAKY — ders): (1) build →
  `gh run download <id> -n holdable-profile-apk -D /tmp/...` → `dist/`'e kopyala (lokal kopya
  İlker'i anında unblock eder, ona Windows yolu ver), (2) `gh release create <tag> --target
  <branch> --prerelease` ASSET'SİZ (anında), (3) `timeout 200 gh release upload <tag> <apk>
  --clobber` retry döngüsüyle, (4) `gh release view <tag> --json assets` ile asset'in
  yüklendiğini TEYİT ET (backgrounded upload'a güvenme — rc=0 dönse bile asset eksik olabilir).
- Doğrulama araçları: `C:/Android/sdk/build-tools/36.0.0/apksigner.bat verify --print-certs <apk>`
  (cert yukarıdaki sabit değer olmalı → uninstall'sız update), `.../aapt2.exe dump badging <apk>`
  (versionCode monoton artmalı). Her yeni cihaz build'inde pubspec build number bump (`0.3.0+N`).
- In-app PSS = Info paneli (holdable/gpu MethodChannel: supportsVulkan/getPss/getMemStats).
  Emülatör PSS ölçemez (gfxstream guest accounting) → gerçek S26 Ultra kullan.
- git identity ayarlı (ilkerarabaci / iarabaci@gmail.com). Commit mesajı sonuna:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

YAPMA: v0.1/v0.2 hatlarına/tag/branch'lerine dokunma. Doğrulanmamış sonuç raporlama. Erken/körlemesine
main merge. Thumbnail capture'ı cihazda crash-yok diye doğrulamadan "çalışıyor" deme.
