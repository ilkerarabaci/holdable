import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/conversion_service.dart';

// Covers the cold-start resilience added in alpha.63: retryTransient must retry
// the transient failures a scaled-to-zero Cloud Run service throws on first
// contact, give up cleanly after `tries`, and never loop forever. firstDelay is
// zeroed so the backoff doesn't slow the suite.
void main() {
  group('retryTransient', () {
    test('returns immediately on success — no retry', () async {
      var calls = 0;
      final r = await retryTransient(() async {
        calls++;
        return 'ok';
      }, firstDelay: Duration.zero);
      expect(r, 'ok');
      expect(calls, 1);
    });

    test('retries a transient SocketException, then succeeds', () async {
      var calls = 0;
      final r = await retryTransient(() async {
        calls++;
        if (calls < 3) throw const SocketException('cold start');
        return 'ok';
      }, firstDelay: Duration.zero);
      expect(r, 'ok');
      expect(calls, 3);
    });

    test('gives up after `tries` and rethrows the SocketException', () async {
      var calls = 0;
      await expectLater(
        retryTransient<String>(() async {
          calls++;
          throw const SocketException('service down');
        }, tries: 2, firstDelay: Duration.zero),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 2); // exactly `tries` attempts, not an infinite loop
    });

    test('maps a final TimeoutException to a friendly ConversionException',
        () async {
      await expectLater(
        retryTransient<String>(() async {
          throw TimeoutException('slow');
        }, tries: 1, firstDelay: Duration.zero),
        throwsA(isA<ConversionException>()),
      );
    });
  });
}
