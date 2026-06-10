import 'package:flutter/foundation.dart';

/// Supported model formats. `.blend` is intentionally absent (v1.0).
enum ModelFormat {
  obj,
  stl,
  glb,
  gltf,
  ply,
  off,
  // Enum names can't start with a digit, so '3mf' is `threemf` and '3ds' is
  // `threeds`; [label] + [fileExtension] map them back to the real extension.
  threemf,
  dae,
  threeds,
  fbx;

  String get label => switch (this) {
        threemf => '.3MF',
        threeds => '.3DS',
        _ => '.${name.toUpperCase()}',
      };

  /// The on-disk extension / the format string passed to ModelParser.parse.
  String get fileExtension => switch (this) {
        threemf => '3mf',
        threeds => '3ds',
        _ => name,
      };

  static ModelFormat? fromExtension(String ext) {
    final e = ext.toLowerCase().replaceAll('.', '');
    return switch (e) {
      'obj' => ModelFormat.obj,
      'stl' => ModelFormat.stl,
      'glb' => ModelFormat.glb,
      'gltf' => ModelFormat.gltf,
      'ply' => ModelFormat.ply,
      'off' => ModelFormat.off,
      '3mf' => ModelFormat.threemf,
      'dae' => ModelFormat.dae,
      '3ds' => ModelFormat.threeds,
      'fbx' => ModelFormat.fbx,
      _ => null,
    };
  }
}

/// A model in the wallet. Persisted via Drift in D4; until then the library
/// holds these in memory.
@immutable
class LibraryModel {
  const LibraryModel({
    required this.id,
    required this.name,
    required this.format,
    required this.sizeBytes,
    required this.filePath,
    required this.importedAt,
    this.thumbnailPath,
  });

  final String id;
  final String name;
  final ModelFormat format;
  final int sizeBytes;
  final String filePath;
  final DateTime importedAt;
  final String? thumbnailPath;

  LibraryModel copyWith({String? name, String? thumbnailPath}) => LibraryModel(
        id: id,
        name: name ?? this.name,
        format: format,
        sizeBytes: sizeBytes,
        filePath: filePath,
        importedAt: importedAt,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      );
}
