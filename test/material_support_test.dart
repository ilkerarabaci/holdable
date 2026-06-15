import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/domain/material_support.dart';
import 'package:holdable/features/library/domain/library_model.dart';

/// PO #7 — the per-format material/texture support lookup that drives the
/// import warning balloon. Buckets per the PO spec.
void main() {
  test('glb and gltf carry full materials + textures', () {
    expect(materialSupportFor(ModelFormat.glb), MaterialSupport.full);
    expect(materialSupportFor(ModelFormat.gltf), MaterialSupport.full);
  });

  test('obj materials are conditional on a bundled .mtl', () {
    expect(materialSupportFor(ModelFormat.obj), MaterialSupport.conditional);
  });

  test('dae / fbx / 3ds import partial materials', () {
    expect(materialSupportFor(ModelFormat.dae), MaterialSupport.partial);
    expect(materialSupportFor(ModelFormat.fbx), MaterialSupport.partial);
    expect(materialSupportFor(ModelFormat.threeds), MaterialSupport.partial);
  });

  test('mesh-only formats carry no materials', () {
    for (final f in const [
      ModelFormat.stl,
      ModelFormat.ply,
      ModelFormat.off,
      ModelFormat.threemf,
    ]) {
      expect(materialSupportFor(f), MaterialSupport.none, reason: f.label);
    }
  });

  test('every format maps to a note with a non-empty title and detail', () {
    for (final f in ModelFormat.values) {
      final s = materialSupportFor(f);
      expect(s.title, isNotEmpty, reason: f.label);
      expect(s.detail, isNotEmpty, reason: f.label);
    }
  });
}
