import 'dart:io';

import 'package:flutter/services.dart';

/// On-device runtime stats, so memory can be read inside the app instead of
/// over `adb shell dumpsys meminfo` from a tethered PC.
class NativeStats {
  NativeStats._();

  static const MethodChannel _channel = MethodChannel('holdable/gpu');

  /// This process's total PSS in kilobytes (Android only; null elsewhere or on
  /// error). PSS is the metric the ADR-001 memory budget is written against.
  static Future<int?> pssKb() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('getPss');
    } catch (_) {
      return null;
    }
  }

  /// Full PSS breakdown in KB (keys: total, java, native, code, stack,
  /// graphics, other, system) — same buckets as `dumpsys meminfo` App Summary.
  /// Tells us where memory goes (GPU vs native heap vs dart). Android only.
  static Future<Map<String, int>?> memStats() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getMemStats');
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return null;
    }
  }
}
