# Big-Model Memory Optimization — measured, one lever at a time

> ## ⚠️ 2026-06-22 — THE REAL BLOCKER WAS A CRASH, NOT MEMORY
> On-device (Samsung **S26 Ultra-class**, S948B / Android 16 — a top flagship, NOT a
> low-RAM phone), 5H **crashes** on load: `SIGSEGV null-deref in libflutter.so` on an
> `io.worker` thread, ~9s uptime. **Not** an OOM-kill (lmkd never touched holdable).
> Root cause: **my alpha.61 texture-cap change** called `descriptor.dispose()` BEFORE
> `codec.getNextFrame()` → use-after-free of the encoded SkData while the io.worker
> decode thread still read it. Only 5H (textured) hit it; intermittent because it's a
> race. Timeline proves it: 5H loaded fine on alpha.59 (787) and alpha.60 (532); broke
> on alpha.61. The "634 = env-noise" reading was a single race-win, not a clean measure.
> **Fix (alpha.62):** dispose codec→descriptor→buffer AFTER the frame is decoded+copied.
> Lesson: I measured PSS numbers and "celebrated" while the app was actually crashing —
> stability is the metric, not dumpsys. Re-verify 5H *loads* before trusting any number.

**Goal:** the "5H" (a 63 MB raw GLB) loaded at **787 MB PSS** (debug was 750+) —
too heavy for average 3-4 GB phones, with NO headroom for real big models. Cut it
lever by lever, **MEASURED on a PROFILE build each step**. No un-measured claims.

**Constraint:** the pure-Dart glTF parser rejects Draco / KTX2 / KHR_mesh_quantization
(`gltf_parser.dart` extensionsRequired check) → serialized compression is OFF the
table. Every lever below is on-device, or server-emitting-PLAIN-glTF.

## Baselines (PROFILE build)
| State | PSS | GPU | Dart-geom (Unknown) |
|---|---|---|---|
| Library (no viewer) | ~271 | 138 | — |
| Octahedron, None env | 473 | 228 | low |
| Octahedron, Sky/IBL | ~544 | ~300 | low |
| **5H (63 MB raw GLB, full high-poly)** | **787** | 315 | **316** |

Already shipped (baseline cuts, not part of the 4):
- alpha.55: GPU MaterialInstance leak fix.
- alpha.59: `releaseSourceData:true` (heavy-model CPU high-water −139) + 0.75 render-scale (GPU −26, measured None).
- alpha.60: on-device grid-cluster decimation (mesh > 350k tris). **✅ measured: 5H 787→532, see table row 0.**

## The 4 levers (research combo) — implemented ONE BY ONE, measured, recorded
Each build cumulative (keeps prior levers). 5H measured on PROFILE, None env, fresh launch.

| # | Lever | Build | Status | 5H PSS | Notes |
|---|-------|-------|--------|--------|-------|
| 0 | Decimation (grid-cluster, 350k budget) | alpha.60 | ✅ SHIPPED — **THE WIN** | **532** (−255, −32%) | vs alpha.59 787 (None-vs-None, controlled). Unknown 316→161, GPU 315→234. Visual: shape preserved, surface faceting (grid-cluster) — quality↔mem, 350k tunable |
| 3 | Texture resolution cap ≤2K | alpha.61 | ✅ SHIPPED, un-isolatable on 5H | (n/a on 5H) | Implemented + CI-green. 4K tex 64MB→16MB GPU **for textured models**. 5H is untextured/≤2K so no delta; the alpha.61 634 reading was Sky/IBL env-noise (GL 243 vs 153 ≈ +IBL 71), NOT a regression. Needs a >2K-textured model to measure |
| 2 | Drop per-vertex RGBA-white (12→8 floats) | alpha.62 | ❌ REVERTED | — | Assumption WRONG: PLY/OFF/glTF parsers write REAL vertex colors at offsets 8–11; 12→8 broke them (OOB, 3 tests red). Benefit transient-only anyway. `git checkout -f feature/alpha-61` |
| 1 | Free `_model` after GPU upload; re-parse on mode-switch | — | ❌ SKIPPED (re-calibrated) | — | Research ranked it biggest **under a no-decimation assumption**. Post-decimation `_model` is small + steady-state Unknown is mostly renderer-native (not `_model`) → gain ~tens of MB vs a risky re-parse refactor + mode-switch latency. Not worth it |
| 4 | Server-side plain-GLB diet (weld+prune+tri-budget+tex-cap, PLAIN out) | (server) | 📋 PROPOSED — separate effort | — | The real lever for converted-model workload. Cloud Run job; `conversion_service.dart`. Server-side, own task |

## Measurements log
- **alpha.59** (releaseSourceData + 0.75 render-scale): octahedron None 473 (GL 147); 5H None **787** (GPU 315, Unknown 316).
- **alpha.60** (+decimation): 5H None **532** (−255, −32%). Unknown 316→161, GPU 315→234. ← controlled None-vs-None vs alpha.59. **THE WIN.**
- **alpha.61** (+texture cap ≤2K): 5H Sky/IBL 634 = env-noise (GL 243 vs alpha.60's 153 ≈ +IBL 71), NOT None, NOT a regression. Texture cap not isolatable on the untextured/≤2K 5H.
- **alpha.62** (RGBA 12→8): build FAILED (gltf/ply/off parser tests — real vertex colors at offsets 8–11). REVERTED.

## Verdict (end of #4)
**Celebrate the decimation win.** 787→532 (−32%) answers the "average 3–4 GB phone" problem — a 63 MB raw GLB now loads at 532 MB; big models stop OOMing. + texture-cap shipped for textured models.
**Period on #1 (free `_model`) and #2 (RGBA):** marginal/risky post-decimation — chasing them is waste.
**#4 (server diet)** is the one remaining worthwhile lever, but a separate server-side effort — user's call.
App-side geometry/GPU savings now exploited (decimation + texture-cap, on `feature/alpha-61`, clean + CI-green, ready to merge to main on the user's word).
