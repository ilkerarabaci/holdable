# alpha.28 — Fable session kickoff prompt

> **Nasıl kullanılır:** Yeni (taze) bir session aç ve aşağıdaki "PROMPT" bloğunun
> tamamını **ilk mesaj** olarak yapıştır. Session, `memory/MEMORY.md` +
> `project-holdable.md`'yi otomatik yükleyecek; bu prompt onların üzerine
> alpha.28 görevini bindirir. Tek seferde, sormadan koşturup sonucu getirmesi
> için yazıldı.

---

## PROMPT (bunu yapıştır)

Sen Holdable'ın EVP-Eng / Head of Developer'ısın (bağlam belleğinde:
`project-holdable.md`). Bu görevi **baştan sona otonom** yürüt: kararları sen
ver, bana tekrar tekrar sorma, ortada durma. Sadece **sonucu** getir. Türkçe
yanıt ver. Cihazda doğrulanmamış hiçbir şeye "çalışıyor" deme (cihaz testini ben
yaparım). Commit footer: `Co-Authored-By: <model-adın>`. Yeni branch'lerde
**MUTLAKA** `git push -u origin <branch>` (yoksa push sessizce başarısız olur).
Yerel `flutter test`/`flutter analyze` thermion native-download'ında takılır →
`flutter analyze --no-pub` kullan; **testlerin asıl kapısı CI'dır**. Parser'ları
`C:\temp\m3` dart harness'ında (gltf_parser/model_parser/thumbnail_raster/
glb_exporter kopyalı) **lokal render ederek görsel doğrula** (PPM→PNG, bana
göster). Ship hattı: branch → CI yeşil → merge → `gh workflow run ci.yml --ref
main -f profile=true` (arm64 split-per-abi build) → APK'yı indir → `dist/`'e
kopyala → boyut+ABI doğrula (`aapt2 dump badging`, native-code = arm64-v8a) →
GitHub release oluştur + APK yükle (upload flaky → arka planda retry; **local
dist path'i her zaman ver**, asıl unblocker o). Version'ı `0.3.0+28` yap.

### alpha.28 KAPSAMI (üçü de bu tek build'de):

**1) TEXTURE DESTEĞİ — parametrik, TÜM nesneler için (HERO özellik)**
Kullanıcı **herhangi bir modele** texture uygulayabilmeli/değiştirebilmeli
(parametrik). Bunu Thermion viewer'da gerçek texture mapping ile yap:
- **UV'ler:** Şu an tüm parser'lar interleaved buffer'da `u,v=0` yazıyor.
  `GltfParser` `TEXCOORD_0` accessor'ını, `parseObj` `vt`'leri gerçek UV olarak
  okusun. UV'si olmayan modeller için **planar/triplanar fallback UV** üret
  (bounds'a göre) ki texture yine de otursun.
- **Texture yükleme:** Bundled bir texture seti ekle (`assets/textures/` —
  ör. wood, metal, marble, fabric, checker/UV-test, birkaç desen; CC0). Görüntüyü
  RGBA'ya decode et (`package:image` veya `dart:ui`), Thermion'a yükle:
  `FilamentApp.instance.createTexture(w,h,...SAMPLER_2D)` + `createTextureSampler(...)`,
  sonra ubershader materyalinde **`setBaseColorMap(texture, sampler)`** (içte
  `setParameterTexture('baseColorMap', tex, sampler)` + `setParameterInt('baseColorIndex', idx)`
  ile enable). API yerleri: `thermion_dart/.../filament/src/interface/filament_app.dart`
  (createTexture/createTextureSampler/loadKtx2), `.../interface/material.dart`
  (setParameterTexture), `.../interface/ubershader_material.dart` (baseColorMap/
  baseColorIndex).
- **UI:** Render panelinde **TEXTURE** bölümü — bundled texture'lardan seçim
  (küçük önizleme swatch'ları) + "None" (texture'ı kaldır, mevcut renk/COLOR'a
  dön). Renk picker'ı ile birlikte tutarlı çalışsın (texture varken baseColorMap,
  yokken baseColorFactor).
- **Showcase:** Bir **gerçekçi araba** sample'ı ekle ki texture'la güzel görünsün
  (Khronos **ToyCar** CC0 artık texture'ıyla doğru render olur; texture'ını GLB'den
  oku VEYA bundled bir araba texture'ı uygula). Önceki bulgu: texture'sız ToyCar
  dağınık çıkıyordu — texture ile düzelir, alpha.28'in kanıtı bu.

**2) EN ZOR 3 YENİ FORMAT** (mevcut 7: obj/stl/glb/gltf/ply/3mf/off)
Önerilen 3 en-zor değerli format: **FBX, DAE (Collada), 3DS**.
- DAE (Collada): XML scene graph — `<mesh>`/`<polylist>`/`<float_array>` (orta).
- 3DS: binary chunk yapısı (0x4D4D ana chunk, 0x4000 nesne, 0x4110 vert, 0x4120
  face) — moderate.
- FBX: **en zor** (binary + ASCII). Pure-Dart'ta binary FBX makul kapsamda
  infeasible'sa → FBX-ASCII'yi (Geometry/Vertices/PolygonVertexIndex) parse et +
  binary sınırını AÇIKÇA belgele (sahteleme yapma); gerekçen iyiyse 3DS yerine
  USDZ/STEP ikamesi yapabilirsin. Her birine bundled sample (CC0) + parser unit
  test + lokal render doğrulaması. `ModelFormat` enum + `ModelParser.parse`
  switch + import-sheet/empty-state/sample-sheet string'leri güncelle (alpha.23'te
  3mf nasıl yapıldıysa aynı pattern; enum adı rakamla başlayamaz → `threeds` gibi
  + `fileExtension` map).

### TAMAMLANMA TANIMI:
- `flutter analyze --no-pub` temiz; CI yeşil (analyze+test+debug APK); yeni
  parser'lar lokal render edilip görsel onaylanmış (bana PNG göster); texture
  pipeline derleniyor (cihaz GPU testini ben yapacağım — kodu best-effort/try-catch
  ile sarmala ki texture başarısız olsa bile model render olmaya devam etsin,
  siyah/çökme riski olmasın).
- Tek `dist/holdable-v0.3.0-alpha.28-profile.apk` (arm64, ~75MB) + GitHub release.
- Bana **Türkçe** kısa rapor: ne eklendi (texture nasıl çalışıyor + hangi araba +
  hangi 3 format), neyin cihaz-testi gerektiği, local path + GitHub link, ve
  cihazda kontrol edeceğim 3-4 net soru.

**Sormadan koş.** Tıkanırsan en makul varsayımı seç, ilerle, kararını raporda
belirt. İyi şanslar.

---

## Hazırlayanın notları (Opus 4.8, alpha.27 sonu)
- Memory güncel: alpha.23–.27 + tüm gotcha'lar + parça-track planı orada.
- Texture API pointer'ları yukarıda hazır — fresh session keşfetmek zorunda
  kalmasın diye `project-holdable.md`'ye de eklendi.
- Tooltips (LIGHT 3 slider) alpha.27 sonrası main'e girdi; alpha.28 onun üstüne.
- Texture, en riskli/derin parça — sıralama önerisi: önce texture+araba (HERO),
  sonra 3 format. Hepsi tek alpha.28 build'inde.
