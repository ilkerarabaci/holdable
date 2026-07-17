import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/conversion_service.dart';

// #5 cancel: the CancelToken contract the banner's Cancel button relies on —
// fire registered aborts exactly once, and run a late listener immediately if
// cancellation already happened (so a listener registered mid-request still
// closes its client).
void main() {
  group('CancelToken', () {
    test('starts not cancelled', () {
      expect(CancelToken().isCancelled, isFalse);
    });

    test('cancel() flips isCancelled and fires callbacks exactly once', () {
      final token = CancelToken();
      var fired = 0;
      token.onCancel(() => fired++);
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(fired, 1);
      token.cancel(); // idempotent — must not re-fire
      expect(fired, 1);
    });

    test('onCancel registered after cancel() runs immediately', () {
      final token = CancelToken()..cancel();
      var fired = false;
      token.onCancel(() => fired = true);
      expect(fired, isTrue);
    });
  });
}
