# Conversion test matrix — sonuçlar (2026-07-20)

Sentetik stres senaryoları lokal Docker'da (holdable-convert:test, cloud'la aynı
Blender 5.0.1 + convert.py `db00a20` sonrası) koşuldu. Üretici script:
sentetik .blend'ler in-container Blender'la üretildi; hepsi
`CONVERT_TRI_BUDGET=150000` + `CONVERT_SUBSURF_MAX=1` ile dönüştürüldü.
Cloud Job timeout referansı: **1500 s**.

## Sonuç tablosu — 10/10 geçti

| # | Senaryo | Girdi | Dönüşüm | Çıktı | Not |
|---|---|---|---:|---|---|
| S1 | Küçük+basit (kontrol, test.blend) | 1 MB | ~7 s | geçerli glb | tarihsel, cloud-verified |
| S2 | Küçük boyut + aşırı detay + ağır materyal (4Holdable2) | 49 MB, 2.6 M yüz | **72 s** | 12.0 MB | cihaz e2e ~4 dk (alpha.68) |
| S3 | Dev dosya + düşük detay (big_b) | 304 MB | **67 s** | 13 MB | decimate 60 s |
| S4 | Büyük dosya + yüksek detay (16 yoğun mesh) | 50 MB, 2 M yüz | **96 s** | 21 MB | decimate 88 s |
| S5 | 600 küçük mesh + 3 ağır (logo-koruma ölçeği) | 15 MB | **22 s** | 23.4 MB | 603 node, 299,082 tri (bütçe birebir) |
| S6 | TEK dev mesh (2 M × ARRAY 3 = 6 M değerlendirilmiş yüz) | 52 MB | **455 s** | 23 MB | decimate 448 s — bkz. öğrenim 2 |
| S7 | Packed texture (4×2K + 1×4K) | <1 MB | **5 s** | 0.5 MB | 5 texture binding + 2 image glb'de doğrulandı |
| S8 | Binlerce node'luk prosedürel materyal (5 mat × iç içe gruplar) | 2 MB | **5 s** | 11 MB | **materyal-düzleştirme regresyon kanıtı** (fix öncesi: 20+ dk) |
| S9 | Degenerate topoloji (üst üste kopya + sıfır-alan + MIRROR + SUBSURF) | 1 MB | **25 s** | 1 MB | bmesh temizlik yolu çalışıyor |
| S10 | Non-mesh (curve+bevel, text, vertex-instancing) | <1 MB | **7 s** | 0.1 MB | curve→mesh, text→mesh, 8 instance node olarak export ✓ |

## Öğrenimler

1. **Decimate her yerde baskın faz** ve yüz sayısıyla ölçekleniyor; export artık
   her senaryoda 0.6-2.3 s (materyal düzleştirme sonrası).
2. **Tek dev mesh süper-lineer**: 2.6 M yüz 28 mesh'e dağılınca 60 s; 6 M yüz tek
   mesh'te 448 s. Yine de 1500 s tavanının rahat altında. Gerekirse ileride
   aşamalı/parçalı decimate iyileştirmesi yapılabilir — şimdilik gerek yok.
3. **Çıktı boyutu bütçe-güdümlü ve dar bantta**: her girdi (304 MB dahil)
   12-24 MB glb'ye iniyor → cihaz import cap'inin (60 MB) hep altında.
4. **Tri bütçesi cihaz tavanıyla uyumlu**: 150 k poly ≈ 299 k üçgen — cihaz
   render tavanı 350 k'nın istikrarlı altında (S5'te birebir 299,082).
5. **İçerik kaybolmuyor**: packed texture'lar, curve/text dönüşümleri ve
   instance'lar glb'ye giriyor; degenerate topoloji temizleniyor.

## Kütüphane limitleri için çıkarımlar (plan panosuna işlendi)

- Dönüştürülmüş model ~12-24 MB → **~50 model ≈ 0.6-1.2 GB disk** (sınır koymaya
  gerek yok; "Library stats" göstergesi yeterli).
- Upload tavanı 2 GB'da kalabilir; 304 MB gerçek dosya 67 s'de dönüyor.
- Bellek: 6 M değerlendirilmiş yüz 8 GB job'da sorunsuz; üretimde tek seferde
  ~10 M+ değerlendirilmiş yüz görülürse job belleği izlenmeli.

## Yeniden koşma

Senaryo üretici + koşucu scriptler oturum scratchpad'inde geliştirildi
(`gen_matrix.py`, `run_matrix.sh`); kalıcı kopyaları `conversion-service/test/`
altına alınabilir (istenirse). Koşum düzeni: `conversion-service/README.md`
"Iterate for free" bölümündeki docker komutuyla birebir.
