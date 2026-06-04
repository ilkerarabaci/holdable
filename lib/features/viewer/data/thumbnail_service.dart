import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

import 'model_parser.dart';
import 'thumbnail_raster.dart';

/// Library-thumbnail generation that can run OUTSIDE the viewer — used to
/// proactively refresh stale thumbnails (e.g. ones left over from the old
/// Thermion GPU-capture builds) without the user having to open each model.
///
/// Same pipeline as the viewer: parse off-isolate → CPU [rasterizeThumbnail]
/// (no GPU) → PNG encode on the UI isolate → write to the thumbs dir. The file
/// name carries a version suffix so staleness is a pure path check.

/// Version-stamped thumbnail file suffix. Bump the token when the rasterizer's
/// output changes so old thumbnails are detected as stale and regenerated.
const String kThumbnailVersionSuffix = '.t2.png';

const int _kSize = 256;
const double _kAzimuth = math.pi / 4; // matches the viewer's default iso camera
const double _kElevation = 0.6;
const int _kBgColor = 0xFF0E0E10; // Prism dark bg (viewer background)
const int _kSurfaceColor = 0xFFD1D1DB; // neutral model surface

/// True if [path] is missing or not a current-version thumbnail and should be
/// regenerated. Pure (no IO) so it's unit-testable; the caller additionally
/// treats a vanished file as stale.
bool isThumbnailStale(String? path) =>
    path == null || !path.endsWith(kThumbnailVersionSuffix);

class _ThumbRequest {
  const _ThumbRequest(this.path, this.format);
  final String path;
  final String format;
}

/// Isolate entry: parse the model file and rasterize the thumbnail to RGBA.
Uint8List? _rasterEntry(_ThumbRequest req) {
  final bytes = File(req.path).readAsBytesSync();
  final mesh = ModelParser.parse(bytes, format: req.format);
  final n = mesh.vertexCount;
  if (n == 0) return null;
  final positions = Float32List(n * 3);
  for (var i = 0; i < n; i++) {
    final s = i * kFloatsPerVertex;
    positions[i * 3] = mesh.vertices[s];
    positions[i * 3 + 1] = mesh.vertices[s + 1];
    positions[i * 3 + 2] = mesh.vertices[s + 2];
  }
  final List<int> indices =
      mesh.indices16 ?? mesh.indices32 ?? List<int>.generate(n, (i) => i);
  final b = mesh.bounds;
  return rasterizeThumbnail(
    positions: positions,
    indices: indices,
    triangleCount: mesh.triangleCount,
    centerX: b.centerX,
    centerY: b.centerY,
    centerZ: b.centerZ,
    minX: b.minX,
    minY: b.minY,
    minZ: b.minZ,
    maxX: b.maxX,
    maxY: b.maxY,
    maxZ: b.maxZ,
    azimuth: _kAzimuth,
    elevation: _kElevation,
    size: _kSize,
    bgColor: _kBgColor,
    surfaceColor: _kSurfaceColor,
  );
}

/// Generates (and persists) a versioned thumbnail PNG for a model, returning its
/// file path — or null on any failure (best-effort; the placeholder is graceful).
Future<String?> generateThumbnailFile({
  required String modelId,
  required String filePath,
  required String format,
}) async {
  try {
    if (!File(filePath).existsSync()) return null;
    final rgba = await compute(_rasterEntry, _ThumbRequest(filePath, format));
    if (rgba == null) return null;
    final png = await _encodePng(rgba, _kSize);
    if (png == null) return null;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/thumbs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = '${dir.path}/$modelId$kThumbnailVersionSuffix';
    await File(path).writeAsBytes(png);
    return path;
  } catch (_) {
    return null;
  }
}

/// RGBA8888 (top-down, [size]×[size]) → PNG bytes via the engine.
Future<Uint8List?> _encodePng(Uint8List rgba, int size) async {
  if (size <= 0 || rgba.length < size * size * 4) return null;
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    size,
    size,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final img = await completer.future;
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bytes?.buffer.asUint8List();
}
