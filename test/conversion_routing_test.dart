import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/conversion_service.dart';

/// Efe feedback #5: ".blend alamıyoruz." Root cause — .blend converted on the
/// synchronous, request-bound path and Blender's single-threaded glTF export
/// ran past the timeout (504). The routing now forces .blend into the async
/// Cloud Run Job (streamed from disk, not request-bound) regardless of size.
/// These lock that contract without any network.
void main() {
  const mb = 1024 * 1024;
  const syncMax = 200 * mb; // mirrors kSyncConvertMax

  group('conversionNeedsAsyncJob', () {
    test('.blend always goes async — even tiny — because it is export-bound',
        () {
      expect(
          conversionNeedsAsyncJob(bytes: 1 * mb, ext: 'blend', syncMaxBytes: syncMax),
          isTrue);
      expect(
          conversionNeedsAsyncJob(
              bytes: 49 * mb, ext: 'blend', syncMaxBytes: syncMax),
          isTrue,
          reason: 'the 49 MB .blend that 504-ed on the sync path now goes async');
      expect(
          conversionNeedsAsyncJob(
              bytes: 180 * mb, ext: 'blend', syncMaxBytes: syncMax),
          isTrue);
    });

    test('other convertible formats stay on the sync path below the cap', () {
      expect(
          conversionNeedsAsyncJob(bytes: 10 * mb, ext: 'step', syncMaxBytes: syncMax),
          isFalse);
      expect(
          conversionNeedsAsyncJob(bytes: 150 * mb, ext: 'usd', syncMaxBytes: syncMax),
          isFalse);
      expect(
          conversionNeedsAsyncJob(bytes: 5 * mb, ext: 'iges', syncMaxBytes: syncMax),
          isFalse);
    });

    test('anything over the sync cap goes async regardless of format', () {
      expect(
          conversionNeedsAsyncJob(bytes: 201 * mb, ext: 'step', syncMaxBytes: syncMax),
          isTrue);
      expect(
          conversionNeedsAsyncJob(bytes: 300 * mb, ext: 'usdz', syncMaxBytes: syncMax),
          isTrue);
    });

    test('extension matching is case- and dot-insensitive', () {
      expect(
          conversionNeedsAsyncJob(bytes: 1 * mb, ext: '.BLEND', syncMaxBytes: syncMax),
          isTrue);
      expect(
          conversionNeedsAsyncJob(bytes: 1 * mb, ext: '.Blend', syncMaxBytes: syncMax),
          isTrue);
      expect(
          conversionNeedsAsyncJob(bytes: 1 * mb, ext: 'STEP', syncMaxBytes: syncMax),
          isFalse);
    });

    test('.blend is the registered export-bound format', () {
      expect(kForceAsyncExtensions, contains('blend'));
    });
  });
}
