import 'dart:io';
import 'dart:typed_data';

/// Extensions Holdable can't parse natively but the conversion service can turn
/// into glb (headless Blender / FreeCAD). Distinct from [ModelFormat], which is
/// the set we read directly.
const Set<String> kConvertibleExtensions = {
  'blend',
  'usd',
  'usda',
  'usdc',
  'usdz',
  // CAD B-rep formats (FreeCAD/OpenCASCADE on the service side).
  'step',
  'stp',
  'iges',
  'igs',
};

/// Base URL of the conversion service (Cloud Run, europe-west3). Public HTTPS,
/// so any device can convert without the dev PC. For local-Docker dev, point
/// this at the dev machine's LAN IP (and re-enable cleartext in the manifest).
// TODO(convert): move to build/remote config; add auth before a real launch.
const String kConversionBaseUrl =
    'https://holdable-convert-872321921378.europe-west3.run.app';

class ConversionException implements Exception {
  ConversionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Uploads an unsupported model to the conversion service and gets back glb
/// bytes. Pure transport — the caller persists/imports the result.
class ConversionService {
  const ConversionService();

  Future<Uint8List> convertToGlb(Uint8List bytes, String ext) async {
    final e = ext.toLowerCase().replaceAll('.', '');
    final uri = Uri.parse('$kConversionBaseUrl/convert?ext=$e');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(uri);
      req.headers.set(
          HttpHeaders.contentTypeHeader, 'application/octet-stream');
      req.add(bytes);
      final resp =
          await req.close().timeout(const Duration(seconds: 240));
      final out = await _collect(resp);
      if (resp.statusCode != 200) {
        throw ConversionException(
            'Conversion failed (HTTP ${resp.statusCode}).');
      }
      // A valid GLB starts with the "glTF" magic.
      if (out.length < 4 ||
          out[0] != 0x67 || out[1] != 0x6C || out[2] != 0x54 || out[3] != 0x46) {
        throw ConversionException('Conversion returned an invalid model.');
      }
      return out;
    } on SocketException {
      throw ConversionException('Conversion service unreachable.');
    } on HttpException {
      throw ConversionException('Conversion service error.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _collect(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
