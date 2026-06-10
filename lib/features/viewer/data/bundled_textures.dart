/// Bundled CC0 surface textures the user can apply to any model from the
/// Render panel's TEXTURE section. Sources: ambientCG (CC0 1.0, downscaled to
/// 512px) + a procedural UV-test checker. See assets/textures/CREDITS.md.
class BundledTexture {
  const BundledTexture(this.name, this.assetPath);

  /// Short display name (swatch tooltip).
  final String name;

  /// Flutter asset path, e.g. `assets/textures/wood.jpg`.
  final String assetPath;
}

const List<BundledTexture> kBundledTextures = [
  BundledTexture('Wood', 'assets/textures/wood.jpg'),
  BundledTexture('Metal', 'assets/textures/metal.jpg'),
  BundledTexture('Marble', 'assets/textures/marble.jpg'),
  BundledTexture('Fabric', 'assets/textures/fabric.jpg'),
  BundledTexture('Checker', 'assets/textures/checker.png'),
];
