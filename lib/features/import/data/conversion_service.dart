import 'dart:convert';
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

/// Cloud Run rejects HTTP/1 request bodies over 32 MiB at the ingress, so files
/// up to this size POST straight to /convert; anything larger goes via GCS
/// (upload-url → PUT to GCS → convert-gcs), which has no request-size limit.
const int _kDirectPostMax = 28 * 1024 * 1024;

class ConversionException implements Exception {
  ConversionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A user-readable message for a non-200 from the conversion service. 504 means
/// the conversion ran past the time limit — almost always a very heavy scene;
/// point the user at exporting a glb themselves rather than retrying forever.
ConversionException _httpError(int code) {
  if (code == 504) {
    return ConversionException(
        'This model is too complex to convert automatically. In your 3D app, '
        'export it as glTF/.glb and import that instead.');
  }
  if (code == 422) {
    return ConversionException(
        "Couldn't convert this model — it may be corrupt or in an "
        'unsupported variant.');
  }
  return ConversionException('Conversion failed (HTTP $code).');
}

/// Uploads an unsupported model to the conversion service and gets back glb
/// bytes. Pure transport — the caller persists/imports the result.
class ConversionService {
  const ConversionService();

  Future<Uint8List> convertToGlb(Uint8List bytes, String ext) async {
    final e = ext.toLowerCase().replaceAll('.', '');
    if (bytes.length <= _kDirectPostMax) {
      return _convertDirect(bytes, e);
    }
    return _convertViaGcs(bytes, e);
  }

  /// Small files: POST the raw bytes to /convert and stream back the glb.
  Future<Uint8List> _convertDirect(Uint8List bytes, String e) async {
    final uri = Uri.parse('$kConversionBaseUrl/convert?ext=$e');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 240));
      final out = await _collect(resp);
      if (resp.statusCode != 200) {
        throw _httpError(resp.statusCode);
      }
      return _validateGlb(out);
    } on SocketException {
      throw ConversionException('Conversion service unreachable.');
    } on HttpException {
      throw ConversionException('Conversion service error.');
    } finally {
      client.close(force: true);
    }
  }

  /// Large files: get a signed URL, PUT the bytes straight to GCS (no size
  /// limit), then ask the service to convert the uploaded object. The result
  /// comes back inline (small glb) or as a signed download URL (large glb).
  Future<Uint8List> _convertViaGcs(Uint8List bytes, String e) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      // 1) Ask for a signed upload URL.
      final urlReq =
          await client.postUrl(Uri.parse('$kConversionBaseUrl/upload-url?ext=$e'));
      final urlResp = await urlReq.close().timeout(const Duration(seconds: 30));
      final urlBody = await _collectString(urlResp);
      if (urlResp.statusCode != 200) {
        throw _httpError(urlResp.statusCode);
      }
      final signed = jsonDecode(urlBody) as Map<String, dynamic>;
      final uploadUrl = signed['uploadUrl'] as String?;
      final objectName = signed['objectName'] as String?;
      if (uploadUrl == null || objectName == null) {
        throw ConversionException('Conversion service error.');
      }

      // 2) PUT the file straight to GCS (content-type must match the signature).
      final putReq = await client.putUrl(Uri.parse(uploadUrl));
      putReq.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      putReq.add(bytes);
      final putResp = await putReq.close().timeout(const Duration(seconds: 300));
      await _drain(putResp);
      if (putResp.statusCode != 200) {
        throw ConversionException('Upload failed (HTTP ${putResp.statusCode}).');
      }

      // 3) Convert the uploaded object.
      final convReq =
          await client.postUrl(Uri.parse('$kConversionBaseUrl/convert-gcs'));
      convReq.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      convReq.add(utf8.encode(jsonEncode({'objectName': objectName, 'ext': e})));
      final convResp = await convReq.close().timeout(const Duration(seconds: 300));

      // Large output comes back as JSON {downloadUrl}; small output is the glb.
      if (convResp.headers.contentType?.mimeType == 'application/json') {
        final body = await _collectString(convResp);
        if (convResp.statusCode != 200) {
          throw _httpError(convResp.statusCode);
        }
        final r = jsonDecode(body) as Map<String, dynamic>;
        final dl = r['downloadUrl'] as String?;
        if (dl == null) throw ConversionException('Conversion returned no model.');
        return _downloadGlb(client, dl);
      }
      final out = await _collect(convResp);
      if (convResp.statusCode != 200) {
        throw _httpError(convResp.statusCode);
      }
      return _validateGlb(out);
    } on SocketException {
      throw ConversionException('Conversion service unreachable.');
    } on HttpException {
      throw ConversionException('Conversion service error.');
    } on FormatException {
      throw ConversionException('Conversion service error.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _downloadGlb(HttpClient client, String url) async {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 300));
    final out = await _collect(resp);
    if (resp.statusCode != 200) {
      throw ConversionException('Download failed (HTTP ${resp.statusCode}).');
    }
    return _validateGlb(out);
  }

  /// A valid GLB starts with the "glTF" magic.
  Uint8List _validateGlb(Uint8List out) {
    if (out.length < 4 ||
        out[0] != 0x67 ||
        out[1] != 0x6C ||
        out[2] != 0x54 ||
        out[3] != 0x46) {
      throw ConversionException('Conversion returned an invalid model.');
    }
    return out;
  }

  Future<Uint8List> _collect(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<String> _collectString(HttpClientResponse resp) async {
    final bytes = await _collect(resp);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<void> _drain(HttpClientResponse resp) async {
    await for (final _ in resp) {}
  }
}
