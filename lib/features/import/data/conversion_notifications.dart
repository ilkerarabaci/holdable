import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

/// #6: a local "conversion finished" notification. A cloud conversion of a big
/// model runs for minutes — the user backgrounds the app and today learns the
/// result only by coming back to check. This posts a system notification via a
/// tiny MethodChannel into MainActivity (plain android.app Notification — no
/// plugin, no build-system changes), gated so it only fires when the app is
/// actually in the background; in the foreground the banner/toast already
/// tells the story.
class ConversionNotifications {
  static const MethodChannel _ch = MethodChannel('holdable/notify');

  /// Request POST_NOTIFICATIONS (runtime on Android 13+) — called right when a
  /// cloud conversion starts, the moment the user best understands why the app
  /// is asking. No-ops silently when already granted/denied or unsupported.
  static Future<void> ensurePermission() async {
    try {
      if (await Permission.notification.isGranted) return;
      await Permission.notification.request();
    } catch (_) {/* best-effort — never block the import on this */}
  }

  /// Posts [title]/[body] as a system notification, but only when the app is
  /// NOT foregrounded. Failures are swallowed: a missed notification must not
  /// fail the import that triggered it.
  static Future<void> notifyIfBackgrounded(String title, String body) async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    try {
      await _ch.invokeMethod('show', {'title': title, 'body': body});
    } catch (_) {/* best-effort */}
  }
}
