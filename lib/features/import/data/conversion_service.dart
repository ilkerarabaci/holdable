import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

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

/// Formats that are EXPORT-BOUND in Blender's single-threaded glTF exporter:
/// even a medium scene blows past the in-request conversion timeout (a 49 MB
/// .blend loaded in ~5 s but its export ran past 7 min — see convert.py). These
/// always convert in the async Cloud Run Job — which streams the upload from
/// disk and isn't request-bound — regardless of file size, so they no longer
/// 504 on the synchronous path.
const Set<String> kForceAsyncExtensions = {'blend'};

/// Routing decision used by the import flow: true ⇒ convert in the async Cloud
/// Run Job (enqueue → await → download); false ⇒ the in-request sync path
/// ([ConversionService.convertToGlb]). Async when the file is over the sync cap
/// OR its format is export-bound (see [kForceAsyncExtensions]). Pure so the
/// routing contract is unit-tested without touching the network.
bool conversionNeedsAsyncJob({
  required int bytes,
  required String ext,
  required int syncMaxBytes,
}) {
  final e = ext.toLowerCase().replaceAll('.', '');
  if (kForceAsyncExtensions.contains(e)) return true;
  return bytes > syncMaxBytes;
}

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

/// Connection timeout for the conversion endpoints. Bumped from 15s: a Cloud
/// Run cold start (the heavy Blender container spinning up from zero instances)
/// can take well over 15s to accept a connection — the likely cause of the
/// "service unreachable" failures when the service has scaled to zero. Pairs
/// with [retryTransient] so a cold first request recovers instead of failing.
const Duration _kConnectTimeout = Duration(seconds: 45);

/// Response timeout for the small control requests (sign-url, enqueue, poll) —
/// also generous enough to ride out a cold start.
const Duration _kCtlTimeout = Duration(seconds: 45);

/// Internal marker for an HTTP status worth retrying (Cloud Run cold-start /
/// transient gateway errors). Never surfaced to the user.
class _TransientHttp implements Exception {
  const _TransientHttp(this.code);
  final int code;
}

bool _isRetryableStatus(int code) => code == 502 || code == 503;

/// Retries [op] on transient failures — network blips and Cloud Run cold-start
/// 5xx — backing off 1s → 3s → 9s. Wrap ONLY idempotent, cheap requests (the
/// first-contact control calls + polling); NEVER the big upload PUT, since
/// re-running it would re-upload hundreds of MB.
@visibleForTesting
Future<T> retryTransient<T>(Future<T> Function() op,
    {int tries = 3, Duration firstDelay = const Duration(seconds: 1)}) async {
  var delay = firstDelay;
  for (var attempt = 1; ; attempt++) {
    try {
      return await op();
    } on _TransientHttp catch (e) {
      if (attempt >= tries) throw _httpError(e.code);
    } on SocketException {
      if (attempt >= tries) rethrow; // callers map this to "unreachable"
    } on TimeoutException {
      if (attempt >= tries) {
        throw ConversionException(
            'The conversion service took too long to respond — it may be '
            'starting up. Please try again in a moment.');
      }
    }
    await Future<void>.delayed(delay);
    delay *= 3;
  }
}

/// State of an async (over-the-sync-cap) conversion job, polled from
/// `GET /jobs/<id>`. Big files convert in a Cloud Run Job, not in-request.
class JobStatus {
  const JobStatus(
      {required this.state, this.phase, this.downloadUrl, this.error});
  final String state; // queued | running | done | failed
  final String? phase;
  final String? downloadUrl;
  final String? error;

  bool get isDone => state == 'done';
  bool get isFailed => state == 'failed';
  bool get isTerminal => isDone || isFailed;

  factory JobStatus.fromJson(Map<String, dynamic> j) => JobStatus(
        state: (j['state'] as String?) ?? 'failed',
        phase: j['phase'] as String?,
        downloadUrl: j['downloadUrl'] as String?,
        error: j['error'] as String?,
      );
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

  // --- Async path (>200 MB): convert in a Cloud Run Job, poll for the result. ---

  /// Enqueues a large file for ASYNC conversion: signs a job upload URL, streams
  /// the file straight to GCS (never buffering it in RAM — it can be hundreds of
  /// MB), then starts the Cloud Run Job. Returns the job id to poll with
  /// [awaitJob]. Use when the file is too big for the synchronous path.
  Future<String> enqueueLargeConversion(File file, String ext) async {
    final e = ext.toLowerCase().replaceAll('.', '');
    final client = HttpClient()..connectionTimeout = _kConnectTimeout;
    try {
      // First contact — retried, since a cold/scaled-to-zero service most often
      // fails right here (this is the request the user hit yesterday when the
      // import "couldn't upload").
      final signed = await retryTransient(() async {
        final urlReq = await client
            .postUrl(Uri.parse('$kConversionBaseUrl/jobs/upload-url?ext=$e'));
        final urlResp = await urlReq.close().timeout(_kCtlTimeout);
        final urlBody = await _collectString(urlResp);
        if (_isRetryableStatus(urlResp.statusCode)) {
          throw _TransientHttp(urlResp.statusCode);
        }
        if (urlResp.statusCode != 200) throw _httpError(urlResp.statusCode);
        return jsonDecode(urlBody) as Map<String, dynamic>;
      });
      final jobId = signed['jobId'] as String?;
      final uploadUrl = signed['uploadUrl'] as String?;
      if (jobId == null || uploadUrl == null) {
        throw ConversionException('Conversion service error.');
      }
      // Stream the file to GCS from disk (content-type must match the signature).
      final len = await file.length();
      final putReq = await client.putUrl(Uri.parse(uploadUrl));
      putReq.headers
          .set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      putReq.contentLength = len;
      await putReq.addStream(file.openRead());
      final putResp = await putReq.close().timeout(const Duration(minutes: 15));
      await _drain(putResp);
      if (putResp.statusCode != 200) {
        throw ConversionException('Upload failed (HTTP ${putResp.statusCode}).');
      }
      final jobReq =
          await client.postUrl(Uri.parse('$kConversionBaseUrl/jobs'));
      jobReq.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      jobReq.add(utf8
          .encode(jsonEncode({'jobId': jobId, 'ext': e, 'origBytes': len})));
      final jobResp = await jobReq.close().timeout(const Duration(seconds: 30));
      await _drain(jobResp);
      if (jobResp.statusCode != 202 && jobResp.statusCode != 200) {
        throw _httpError(jobResp.statusCode);
      }
      return jobId;
    } on SocketException {
      throw ConversionException('Conversion service unreachable.');
    } finally {
      client.close(force: true);
    }
  }

  /// Polls a job once.
  Future<JobStatus> pollJob(String jobId) async {
    final client = HttpClient()..connectionTimeout = _kConnectTimeout;
    try {
      return await retryTransient(() async {
        final req =
            await client.getUrl(Uri.parse('$kConversionBaseUrl/jobs/$jobId'));
        final resp = await req.close().timeout(_kCtlTimeout);
        final body = await _collectString(resp);
        if (_isRetryableStatus(resp.statusCode)) {
          throw _TransientHttp(resp.statusCode);
        }
        if (resp.statusCode != 200) throw _httpError(resp.statusCode);
        return JobStatus.fromJson(jsonDecode(body) as Map<String, dynamic>);
      });
    } on SocketException {
      throw ConversionException('Conversion service unreachable.');
    } finally {
      client.close(force: true);
    }
  }

  /// Polls until the job is done/failed or [maxWait] elapses (backing off
  /// 3s → 12s). Throws if it's still running past the deadline.
  Future<JobStatus> awaitJob(String jobId,
      {Duration maxWait = const Duration(minutes: 30)}) async {
    final deadline = DateTime.now().add(maxWait);
    var delay = const Duration(seconds: 3);
    while (true) {
      final s = await pollJob(jobId);
      if (s.isTerminal) return s;
      if (DateTime.now().isAfter(deadline)) {
        throw ConversionException(
            "Still converting — this one's taking a while. Check back shortly.");
      }
      await Future<void>.delayed(delay);
      if (delay < const Duration(seconds: 12)) {
        delay += const Duration(seconds: 2);
      }
    }
  }

  /// Downloads the finished glb from a completed job's signed [downloadUrl].
  Future<Uint8List> downloadJobGlb(String downloadUrl) async {
    final client = HttpClient()..connectionTimeout = _kConnectTimeout;
    try {
      return await _downloadGlb(client, downloadUrl);
    } finally {
      client.close(force: true);
    }
  }

  /// Small files: POST the raw bytes to /convert and stream back the glb.
  Future<Uint8List> _convertDirect(Uint8List bytes, String e) async {
    final uri = Uri.parse('$kConversionBaseUrl/convert?ext=$e');
    final client = HttpClient()..connectionTimeout = _kConnectTimeout;
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
    final client = HttpClient()..connectionTimeout = _kConnectTimeout;
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
