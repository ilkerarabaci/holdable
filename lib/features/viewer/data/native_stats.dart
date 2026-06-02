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
}
