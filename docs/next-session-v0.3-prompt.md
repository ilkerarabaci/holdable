# Ready-to-run prompt — continue v0.3-thermion in a new session

Paste the block below verbatim into a fresh session. It is self-contained; the
session should not need to ask questions before starting.

---

```
Holdable projesinde v0.3-thermion hattında çalışıyorsun. Rolün: EVP-Eng / Head of
Developer, Agentic SDLC disiplini (conventional commits; feature/** branch → PR;
cite-on-commit). TÜRKÇE yanıt ver. Bana tekrar sormadan ilerle; her adımı güvenilir
metin kanalıyla doğrula (git show / gh / flutter analyze / CI logları). Doğrulamadığın
hiçbir sonucu "yapıldı/çalışıyor" diye raporlama (geçen oturumların dersi).

KONUM: C:\Users\Administrator\Documents\New project\Projects\3D Viewer\Holdable
(kendi git repo'su; GitHub: github.com/ilkerarabaci/holdable, public).

İLK İŞ — sırayla, bana sormadan:
1. memory/project-holdable.md DOSYASINI BAŞTAN SONA OKU. Tüm bağlam, kararlar
   (ADR-001/ADR-002), versiyon hatları, CI/cihaz iş akışı ve "Thermion FOUNDATION"
   + "NEXT (v0.3)" bölümleri orada. docs/adr-002-renderer-reassessment.md'yi de oku.
2. Repodan gerçek durumu teyit et: `git checkout v0.3-thermion && git pull`,
   `git log --oneline -8`, `git status`. Beklenen son commit: a9e8c15.

NEREDE KALDIK (özet — detay memory'de):
- Renderer kararı yeniden açıldı (ADR-002). v0.1 WebView ve v0.2 flutter_scene
  DONDURULDU ve saklanıyor (tag'ler: v0.1.0-alpha-webview, v0.2.0-alpha-flutterscene).
  ONLARA DOKUNMA. Aktif hat = v0.3-thermion (pubspec 0.3.0+1).
- flutter_scene neden bırakıldı: native render çalışıyordu ve app-mantık belleği ~56MB
  (WebView CPU tabanı öldü) AMA Impeller GPU belleğini serbest bırakmıyor
  (flutter/flutter#178264) → 80K-tri modelde ~1GB GRAPHICS, takvimsiz engel.
- Thermion (Google Filament) seçildi: kendi GPU belleğini yönetir, Impeller'ı baypas eder.
- BU OTURUMDA YAPILAN: Thermion'un Android build'i CI'da YEŞİLE alındı (analyze+test+
  debug APK+profile APK). Bağımlılık çakışması git-pin ile çözüldü (pubspec'te
  dependency_overrides → thermion_dart + thermion_flutter, github nmfisher/thermion,
  ref 3831559a866d6b92cdba9d6b06f7f0e21b9553ca; flutter_scene/flutter_gpu kaldırıldı).
  ci.yml'e host C++ toolchain apt adımı eklendi; root android/build.gradle.kts'e Kotlin
  jvmTarget=17 zorlaması eklendi. `git config --global core.longpaths true` ayarlı.
- KOD DURUMU: lib/features/viewer/presentation/scene_view.dart şu an bir İSKELET —
  modeli isolate'te parse edip Info paneline istatistik veriyor, ama yalnızca arka planı
  (ColoredBox) çiziyor. scene_geometry.dart silindi. GERÇEK THERMION RENDER'I HENÜZ YOK.

SENİN GÖREVİN (v0.3-thermion'da, feature/** alt-branch'lerinde çalış, PR ile v0.3-thermion'a
merge et; main'e DEĞİL):
1. Thermion API'sini GÜVENİLİR kaynaktan oku: pub cache git checkout'u
   %LOCALAPPDATA%\Pub\Cache\git\thermion-3831559.../  (thermion_dart/lib ve
   thermion_flutter/thermion_flutter/lib). ThermionViewer / ViewerWidget /
   ManipulatorType.ORBIT / loadGlb / loadGlbFromBuffer / createGeometry(varsa, ham
   vertex/index'ten) metotlarını bul. Web dokümanı sürümle uyumsuz olabilir; KAYNAK esastır.
2. KARAR (kendin ver, kanıta dayalı): Thermion sadece glTF/glb yüklüyor; bizim parser
   MeshData (interleaved 48-byte [pos3,normal3,uv2,color4] + indices + AABB) üretiyor.
   İki yol: (a) Thermion'un runtime createGeometry API'si varsa parse çıktısını direkt besle;
   (b) yoksa MeshData → in-memory .glb yazıp loadGlbFromBuffer ile yükle. Hangisi
   uygulanabilirse onu seç, gerekçeni bir satır commit mesajında belirt.
3. ModelSceneView'i (scene_view.dart) Thermion ile gerçek render edecek şekilde kur.
   ViewerScreen kontratını KORU (ModelSceneView, ModelSceneController{setRenderMode,setView},
   ModelSceneStatus, onStatus/onThumbnail). Parite hedefi: model render, orbit (Thermion
   ManipulatorType.ORBIT), preset view'lar (front/top/side/iso), render modları
   (solid/wireframe/x-ray — Filament'te nasıl yapılırsa: material/wireframe seçeneği),
   thumbnail capture (library kartına), Prism arka plan. model_parser.dart + viewer_screen
   chrome + native_stats (holdable/gpu kanalı: getMemStats — in-app PSS) AYNEN yeniden kullanılır.
4. ASIL HEDEF — cihazda PSS ölç: profile APK'yı CI'da üret, GitHub pre-release olarak yayınla,
   İlker S26 Ultra'ya sideload edip Info panelindeki MEMORY/GRAPHICS satırını okusun. Soru:
   Filament, Impeller'ın takıldığı yerde (örn. bitki.obj 80K-tri ~1GB) bütçe altında kalıyor mu?
   Küçük model + bitki.obj/50MB ile kıyasla. Bu sayı tatmin ediciyse parite + PSS doğrulandığında
   v0.3 → main PR'ı (ERKEN MERGE ETME).
5. ERKEN YAP — sabit debug imzası: android'e commit'lenmiş debug keystore + gradle signingConfig
   ekle ki her CI build'inde İlker'in "kaldır-kur + Play Protect" çilesi bitsin (sonra sadece
   "güncelle"). Bu ilk PR'lardan biri olsun; cihaz test döngüsünü çok hızlandırır.

KRİTİK ORTAM/İŞ AKIŞI GERÇEKLERİ (yeniden keşfetme):
- Flutter 3.44.0 stable / Dart 3.12.0, C:\flutter. Komutlar PowerShell'de:
  `$env:Path += ";C:\flutter\bin"; flutter ...`.
- LOKAL BUILD BOZUK (Gradle loopback) + Thermion native C++/cmake/EGL lokalde yok →
  lokal doğrulama YALNIZCA `flutter analyze`. test + APK build = CI'da.
- CI yalnızca main + feature/** push'ta VE workflow_dispatch'te tetiklenir. v0.3-thermion
  push'u CI tetiklemez → ya feature/** branch'inde çalış (otomatik tetikler) ya da
  `gh workflow run ci.yml --ref <branch>` (profile için `-f profile=true`). Build'i
  `gh run watch <id> --exit-status` ile izle; hata için `gh run view <id> --log-failed`.
- pubspec.lock'taki thermion git-override pinli; pub get Windows'ta longpaths sayesinde çalışır.
- ci.yml'de host C++/GL toolchain apt adımı zaten var (Thermion native build için).
- Cihaz test kanalı: `gh release create vX --target <branch> --prerelease <profile.apk>` →
  İlker telefonda indirir (Play Protect → "yine de yükle"). Sabit imza gelene kadar her
  yeni build önce uninstall ister.
- git identity ayarlı (ilkerarabaci / iarabaci@gmail.com). Commit mesajı sonuna:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

YAPMA: v0.1/v0.2 hatlarına, tag'lerine, release/0.1-webview & v0.2-native branch'lerine dokunma.
Doğrulanmamış PSS/sonuç raporlama. Erken main merge.

TANIM-I TAMAM (yön): Thermion ile model gerçek render olur (en azından solid + orbit),
CI yeşil, ve S26 Ultra'da PSS ölçülüp flutter_scene'in ~1GB'ıyla kıyaslanır. Oradan render
modları/preset/thumbnail paritesi ve sonra main PR.
```
