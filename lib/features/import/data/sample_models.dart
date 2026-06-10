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
  SampleModel(name: 'Gear (3MF)', asset: 'assets/sample_models/gear.3mf'),
  SampleModel(name: 'Geosphere (OFF)', asset: 'assets/sample_models/geosphere.off'),
  // Realistic CC0 models (Khronos glTF Sample Assets, public domain), stripped
  // to geometry-only + recolored. See assets/sample_models/CREDITS.md.
  SampleModel(name: 'Teacup', asset: 'assets/sample_models/teapot.glb'),
  SampleModel(
      name: 'Lounge chair', asset: 'assets/sample_models/lounge_chair.glb'),
  SampleModel(name: 'Camera', asset: 'assets/sample_models/camera.glb'),
  // Fully textured showcase (Khronos ToyCar, CC0) — kept WITH its texture:
  // the viewer reads the GLB's embedded base-color texture + TEXCOORD_0 UVs.
  SampleModel(name: 'Toy car', asset: 'assets/sample_models/toy_car.glb'),
  // alpha.28 formats (procedurally generated, CC0).
  SampleModel(name: 'Vase (DAE)', asset: 'assets/sample_models/vase.dae'),
  SampleModel(name: 'Gem (3DS)', asset: 'assets/sample_models/gem.3ds'),
  SampleModel(name: 'Star (FBX)', asset: 'assets/sample_models/star.fbx'),
];
