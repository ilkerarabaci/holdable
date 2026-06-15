import '../../library/domain/library_model.dart';

/// How much of a model's *appearance* (materials, colours, textures) survives
/// import, by source format. Geometry always loads; materials don't, and that
/// surprises people — an .stl importer wonders why their model is grey. PO #7
/// surfaces this as a per-format note at import time.
///
/// Buckets (PO spec): glb/gltf = full; obj = only if its .mtl is bundled;
/// dae/fbx/3ds = partial; stl/ply/off/3mf = geometry only.
enum MaterialSupport {
  /// Materials and textures travel inside the file and load with the model.
  full,

  /// Materials load only when a companion file is present — an .obj references
  /// an .mtl (and image textures) that a single-file import usually won't carry.
  conditional,

  /// Some material/colour data may load; textures and advanced shading often
  /// won't.
  partial,

  /// Geometry only — the format stores no materials, so the model imports onto
  /// a neutral surface.
  none,
}

/// Maps a [ModelFormat] to how completely its materials/textures import.
/// Exhaustive over [ModelFormat] so a new format must be classified here.
MaterialSupport materialSupportFor(ModelFormat format) => switch (format) {
      ModelFormat.glb || ModelFormat.gltf => MaterialSupport.full,
      ModelFormat.obj => MaterialSupport.conditional,
      ModelFormat.dae ||
      ModelFormat.fbx ||
      ModelFormat.threeds =>
        MaterialSupport.partial,
      ModelFormat.stl ||
      ModelFormat.ply ||
      ModelFormat.off ||
      ModelFormat.threemf =>
        MaterialSupport.none,
    };

extension MaterialSupportInfo on MaterialSupport {
  /// Short headline for the note ("Geometry only", "Partial materials", …).
  String get title => switch (this) {
        MaterialSupport.full => 'Materials & textures included',
        MaterialSupport.conditional => 'Needs an .mtl for materials',
        MaterialSupport.partial => 'Partial materials',
        MaterialSupport.none => 'Geometry only',
      };

  /// One-line explanation shown under the title.
  String get detail => switch (this) {
        MaterialSupport.full =>
          'Colours and textures load with the model.',
        MaterialSupport.conditional =>
          "An .obj's colours live in a separate .mtl — a single .obj imports "
              'untextured.',
        MaterialSupport.partial =>
          "Basic colours may load; textures and advanced materials often won't.",
        MaterialSupport.none =>
          'This format carries no materials — the model imports on a neutral '
              'surface.',
      };
}
