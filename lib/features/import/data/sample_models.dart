/// Bundled CC0 sample models surfaced in the import sheet's "Sample models"
/// option. Simple procedurally-generated polyhedra so first-run users have
/// something to view immediately (assets/sample_models/).
class SampleModel {
  const SampleModel({required this.name, required this.asset});
  final String name;
  final String asset;
}

const kSampleModels = <SampleModel>[
  SampleModel(name: 'Cube', asset: 'assets/sample_models/cube.stl'),
  SampleModel(name: 'Tetrahedron', asset: 'assets/sample_models/tetrahedron.stl'),
  SampleModel(name: 'Octahedron', asset: 'assets/sample_models/octahedron.stl'),
  SampleModel(name: 'Icosahedron', asset: 'assets/sample_models/icosahedron.stl'),
  SampleModel(name: 'Hex pendant', asset: 'assets/sample_models/hex_pendant.stl'),
  SampleModel(name: 'Lamp shade', asset: 'assets/sample_models/lamp_shade.stl'),
  SampleModel(name: 'Cube (OBJ)', asset: 'assets/sample_models/cube.obj'),
  SampleModel(name: 'Torus (GLB)', asset: 'assets/sample_models/torus.glb'),
  SampleModel(name: 'Sphere (PLY)', asset: 'assets/sample_models/sphere.ply'),
];
