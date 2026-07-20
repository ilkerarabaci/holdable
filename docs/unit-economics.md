# Holdable — Birim Ekonomi (unit economics)

> Tek doğruluk kaynağı. Her yeni ölçümde **Ölçüm günlüğü**ne satır eklenir; rakam
> değişince üst tablolar güncellenir (git geçmişi = fiyat/maliyet izleme).
> Pano özeti: claude.ai/code artifact "Holdable — Plan Panosu" (senkron tutulur).

## Conversion başına maliyet (ölçüm: 2026-07-17, 4Holdable2.blend)

| Kalem | Neye bağlı | Maliyet |
|---|---|---:|
| Cloud Run Job CPU (4 vCPU × ~150 s) | Model karmaşıklığı (yüz sayısı) | $0.014 |
| Cloud Run Job RAM (8 GB × ~150 s) | Sabit konfigürasyon | $0.003 |
| Çıktı indirme (~12 MB egress) | Çıktı boyutu (tri-budget ile sabit) | $0.001 |
| GCS geçici depolama + istekler | 1 günlük lifecycle | <$0.001 |
| **Toplam / conversion** | İlk import'ta bir kez; sonrası lokal | **≈ $0.02** |

Fiyat referansları (europe-west3, tier-1, 2026-07): vCPU-sn $0.000024 · GiB-sn
$0.0000025 · GCS internet egress ~$0.12/GB. Job süresi ~150 s = convert 72 s +
container start + GCS I/O.

## Sabit / arka plan giderleri

- **Cloud Build**: deploy başına ~6 dk (yalnız kod değişince).
- **Artifact Registry**: image ~1 GB (Blender+FreeCAD) × sürüm sayısı,
  ~$0.10/GB·ay → eski digest'leri düzenli sil (README "Security/cost hygiene").
- **Cloud Run servis**: scale-to-zero, boşta ~$0. `max-instances=3` tavan.
- **GCS**: 1 günlük lifecycle sayesinde kalıcı depolama ~0.

## Bütçe matematiği

- Aylık bütçe hedefi: **$10** → ~**400 conversion/ay** (yalnız uyarır, harcamayı
  kesmez; koruma = API key + max-instances + fair-use).
- Mayıs (~$19) / Haziran (~$10) aşımlarının nedeni serving değil GELİŞTİRMEydi:
  başarısız 15-25 dk Job denemeleri (~$0.15-0.20/adet) + tekrarlı Cloud Build.
  Kural: convert.py iterasyonu LOKAL Docker'da (Dockerfile.test), cloud'a tek
  deploy.

## Süre-boyut ilişkisi (ölçülmüş)

| Faz | Sürücü | Ölçüm |
|---|---|---|
| Upload | dosya boyutu ÷ hat; gzip 2-5× kısaltır | 51 MB → <1 dk (5G) |
| Convert | boyut DEĞİL karmaşıklık | 319 MB basit → 51 s · 49 MB kompleks → 72 s |
| Job overhead | sabit (cold start + GCS) | ~30-60 s |
| İndirme | çıktı ~12 MB sabit | saniyeler |

Uçtan uca (dokunuş→kütüphane): tipik 2-4 dk; 4Holdable2 canlı ölçüm ~4 dk.

## Kapasite: başlangıç modeli kaç kullanıcıyı kaldırır? (2026-07-20)

Kullanıcı-başı sunucu maliyeti YALNIZ conversion'dır: kütüphane cihazda yaşar
(görüntüleme/AR/tekrar açma = $0, kullanıcı sayısından bağımsız; 50 model ≈
0.6-1.2 GB kullanıcının kendi diski).

| Bütçe | Herkes 5 hakkını kullanırsa (kötü ay) | Gerçekçi (~2 conversion/ay) |
|---|---:|---:|
| $10/ay (bugünkü) | **~100 aktif kullanıcı** | ~250 |
| $50/ay | ~500 | ~1.250 |
| $100/ay | ~1.000 | ~2.500 |

- Kısıt PARA, sistem değil: Job'lar paralel; 3 eşzamanlı işleyici bile saatte
  ~70 conversion (günde ~1.700) kaldırır — bütçe çok daha önce biter.
- Ölçek lineeri bozacak ilk şey **sosyal** (egress ~$0.12/GB) — Model C gereği
  o noktada Pro geliri devreye girmiş olacak.
- Ön şart: kullanıcı-başı fair-use sayacı (usage/*.json) — henüz yok, backlog.

## Pricing kararı (2026-07-17, Ilker)

**Model C — aşamalı:** launch tamamen ücretsiz + fair-use (5 conversion/ay
hedefi; sunucu tarafı kullanıcı-başı sayaç backlog'da). Pro **$9.99/ay**
aboneliği sosyal/HDRI premium değeriyle birlikte devreye girer (Haziran
tasarımı: Free/Pro/Studio; pazar çıpaları Polycam $20, Sketchfab $15-79,
Meshy $20+; asıl ölçek maliyeti sosyaldeki egress ~$0.12/GB).

## Ölçüm günlüğü (append-only)

| Tarih | Ne | Sonuç |
|---|---|---|
| 2026-06-22 | big_b 319 MB e2e (gzip'siz) | upload 4 m 27 s · convert 51 s · toplam ~5.5 dk |
| 2026-07-17 | 4Holdable2 lokal Docker (fix sonrası) | 72 s toplam; decimate 64.9 s, export 1.2 s |
| 2026-07-17 | 4Holdable2 cihaz e2e (alpha.68, gzip'li) | dokunuş→kütüphane ~4 dk; Job ~150 s; ~$0.02 |

### Yeniden ölçüm nasıl yapılır

- Lokal (ücretsiz): `conversion-service/README.md` → "Iterate on convert.py for
  free" — `[phase]` satırları faz sürelerini verir.
- Cloud gerçeği: Job süresi = GCS `jobs/<id>/status.json` `createdAt→updatedAt`
  farkı; maliyet = süre × (4 vCPU + 8 GiB) fiyatı.
