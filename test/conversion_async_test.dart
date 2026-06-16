import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/conversion_service.dart';
import 'package:holdable/features/import/data/import_service.dart';

/// The async >200MB conversion client contract: JobStatus decoding (the shape
/// the server's status.json must satisfy) and the size thresholds that route a
/// file to the sync vs async path.
void main() {
  test('JobStatus decodes server status.json states', () {
    final done = JobStatus.fromJson(
        {'state': 'done', 'phase': 'done', 'downloadUrl': 'https://x/y.glb'});
    expect(done.isDone, isTrue);
    expect(done.isTerminal, isTrue);
    expect(done.downloadUrl, 'https://x/y.glb');

    final running = JobStatus.fromJson({'state': 'running', 'phase': 'convert'});
    expect(running.isDone, isFalse);
    expect(running.isTerminal, isFalse);

    final failed = JobStatus.fromJson({'state': 'failed', 'error': 'boom'});
    expect(failed.isFailed, isTrue);
    expect(failed.isTerminal, isTrue);
    expect(failed.error, 'boom');
  });

  test('missing/garbage state is treated as failed (so the client stops polling)',
      () {
    expect(JobStatus.fromJson(const {}).isFailed, isTrue);
    expect(JobStatus.fromJson(const {}).isTerminal, isTrue);
  });

  test('sync cap sits below the async ceiling, and the wall is 200MB/2GB', () {
    expect(kSyncConvertMax, lessThan(kMaxAsyncUploadBytes));
    expect(kSyncConvertMax, 200 * 1024 * 1024);
    expect(kMaxAsyncUploadBytes, 2 * 1024 * 1024 * 1024);
  });
}
