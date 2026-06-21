import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/import/data/conversion_service.dart';

/// Pure-function contracts for the conversion service's load-bearing decision
/// helpers (extracted for testability): the HTTP error → user-message mapping,
/// the GLB magic-bytes guard, and the direct-POST vs GCS-upload size boundary.
void main() {
  group('conversionHttpError', () {
    test('504 → point the user at exporting glTF themselves', () {
      final m = conversionHttpError(504).message;
      expect(m, contains('export'));
      expect(m.toLowerCase(), contains('complex'));
    });
    test('422 → corrupt / unsupported variant', () {
      expect(conversionHttpError(422).message.toLowerCase(), contains('corrupt'));
    });
    test('other codes → generic message carrying the code', () {
      expect(conversionHttpError(500).message, contains('500'));
      expect(conversionHttpError(503).message, contains('503'));
    });
  });

  group('isValidGlb', () {
    test('accepts the "glTF" magic', () {
      final glb = Uint8List.fromList([...utf8.encode('glTF'), 0, 1, 2, 3]);
      expect(isValidGlb(glb), isTrue);
    });
    test('rejects an HTML error page returned in place of a model', () {
      expect(isValidGlb(Uint8List.fromList(utf8.encode('<!DOCTYPE html>...'))),
          isFalse);
    });
    test('rejects bodies shorter than the 4-byte magic', () {
      expect(isValidGlb(Uint8List.fromList([0x67, 0x6C])), isFalse);
      expect(isValidGlb(Uint8List(0)), isFalse);
    });
    test('rejects the right length but wrong bytes', () {
      expect(isValidGlb(Uint8List.fromList([0x67, 0x6C, 0x54, 0x00])), isFalse);
    });
  });

  group('conversionUsesGcsUpload', () {
    const cap = 28 * 1024 * 1024; // mirrors _kDirectPostMax
    test('at or below the 28 MiB cap → direct POST (false)', () {
      expect(conversionUsesGcsUpload(bytes: 1), isFalse);
      expect(conversionUsesGcsUpload(bytes: cap), isFalse,
          reason: 'boundary stays on the direct path, matching the old <= test');
    });
    test('above the cap → GCS upload (true)', () {
      expect(conversionUsesGcsUpload(bytes: cap + 1), isTrue);
      expect(conversionUsesGcsUpload(bytes: 100 * 1024 * 1024), isTrue);
    });
  });
}
