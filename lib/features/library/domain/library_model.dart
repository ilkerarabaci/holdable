import 'package:flutter/foundation.dart';

/// Supported alpha formats. `.blend` is intentionally absent (v1.0).
enum ModelFormat {
  obj,
  stl;

  String get label => '.${name.toUpperCase()}';

  static ModelFormat? fromExtension(String ext) {
    final e = ext.toLowerCase().replaceAll('.', '');
    return switch (e) {
      'obj' => ModelFormat.obj,
      'stl' => ModelFormat.stl,
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
