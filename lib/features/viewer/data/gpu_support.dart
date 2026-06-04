import 'dart:io';

import 'package:flutter/services.dart';

/// Reports whether this device can run the native flutter_scene viewer.
///
/// flutter_scene renders through Impeller's Vulkan backend on Android and Metal
/// on iOS. It crashes on Impeller's OpenGL ES backend (a hard native abort we
/// can't catch), so on Android we proactively check for a Vulkan-capable GPU
/// and gate the viewer behind it.
///
/// This is best-effort: it catches devices with no Vulkan hardware. It can't
/// detect a device that has a Vulkan driver Flutter's denylist rejects (e.g.
/// the emulator's software Vulkan, which falls back to GLES) — that's a
/// dev-only case. iOS and other platforms are assumed supported (Metal).
class GpuSupport {
  GpuSupport._();

  static const MethodChannel _channel = MethodChannel('holdable/gpu');
  static bool? _cached;

  static Future<bool> isSupported() async {
    if (_cached != null) return _cached!;
    if (!Platform.isAndroid) {
      return _cached = true;
    }
    try {
      _cached = await _channel.invokeMethod<bool>('supportsVulkan') ?? true;
    } catch (_) {
      // Fail open: a channel hiccup shouldn't wrongly block a working device.
      _cached = true;
    }
    return _cached!;
  }
}
