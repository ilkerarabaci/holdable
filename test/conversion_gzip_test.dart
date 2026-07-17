import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/conversion_service.dart';

/// #8 (upload time): the client gzips .blend uploads before the GCS PUT; the
/// job worker detects the gzip MAGIC BYTES (not a flag) and decompresses. These
/// lock the client half of that contract without any network: what we send is
/// exactly what `_gunzip_if_needed` in job_worker.py keys on.
void main() {
  group('gzip upload contract', () {
    test('.blend is registered for gzip upload; zip-containers are not', () {
      expect(kGzipUploadExtensions, contains('blend'));
      // usdz IS a zip archive — gzipping it would burn CPU for ~no size win.
      expect(kGzipUploadExtensions, isNot(contains('usdz')));
    });

    test('the client codec emits the gzip magic the worker detects', () async {
      final raw = utf8.encode('BLENDER-v500' * 400); // stand-in payload
      final gz = await (Stream<List<int>>.fromIterable([raw])
              .transform(gzip.encoder))
          .fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
      // job_worker.py: `fh.read(2) != b"\x1f\x8b"` — this is that contract.
      expect(gz[0], 0x1f);
      expect(gz[1], 0x8b);
      // And it round-trips: the worker's gzip.open() sees the original bytes.
      final back = gzip.decode(gz);
      expect(back, raw);
      expect(gz.length, lessThan(raw.length),
          reason: 'repetitive model data must actually shrink');
    });

    test('API key defaults to empty (header omitted) without a dart-define',
        () {
      // CI injects CONVERT_API_KEY via --dart-define; plain `flutter test` has
      // none, and the client must then send no X-Api-Key header (matches a
      // server with auth off — the staged-rollout state).
      expect(kConversionApiKey, isEmpty);
    });
  });
}
