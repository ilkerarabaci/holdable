# Big-Model Memory Optimization — measured, one lever at a time

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
- alpha.60: on-device grid-cluster decimation (mesh > 350k tris). **MEASURE PENDING (build running).**

## The 4 levers (research combo) — implement ONE BY ONE, measure + record each
Each build is cumulative (keeps the prior levers). Measure the 5H on PROFILE.

| # | Lever | Expected | Build | Status | 5H PSS after | Notes |
|---|-------|----------|-------|--------|--------------|-------|
| 0 | Decimation (grid-cluster, 350k budget) | −geometry | alpha.60 | ✅ DONE | **532** (−255) | Unknown 316→161, GPU 315→234. Visual: shape OK, surface faceting visible — quality↔memory; 350k tunable |
| 1 | Free `_model` after GPU upload; re-parse on mode-switch | −~316 (Dart geom) | alpha.61 | todo | ? | BIGGEST; `_model` only kept for mode-switch / pivot-pick / ground-rebase |
| 2 | Drop dead per-vertex RGBA-white channel (12→8 floats) | −~21 GPU + parse | alpha.62 | todo | ? | every parser writes (1,1,1,1); material already × baseColorFactor |
| 3 | Texture resolution cap ≤2K + 16-bit indices when fits | −~48/4K-tex GPU | alpha.63 | todo | ? | glTF parser always emits Uint32 indices |
| 4 | Server-side plain-GLB diet (weld+prune+tri-budget+tex-cap, `-noq`) | smaller GLB → device | (server) | todo | ? | Cloud Run conversion job; `conversion_service.dart` |

## Measurements log (append after each build + device measure)
- (pending) alpha.60 decimation — 5H profile = ?
