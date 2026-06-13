import 'dart:async';
import 'package:flutter/services.dart';
import '../domain/hand_gesture.dart';

/// Dart side of the native hand-tracking pipeline (see `HandTracker.kt`).
///
/// [start] spins up the native CameraX + MediaPipe HandLandmarker and returns
/// the Flutter texture id the camera preview renders into. [frames] streams a
/// [HandFrame] per processed camera frame. [stop] tears the camera down.
///
/// Transport: a MethodChannel for control + an EventChannel for the high-rate
/// landmark stream (only ~63 doubles/hand/frame — small enough to ship over the
/// channel comfortably; the heavy camera + inference work stays native).
class HandLandmarkerChannel {
  HandLandmarkerChannel();

  static const MethodChannel _control = MethodChannel('holdable/hands');
  static const EventChannel _events = EventChannel('holdable/hands/events');

  Stream<HandFrame>? _frames;

  /// Starts the camera + landmarker. Returns the preview texture id.
  Future<int> start() async {
    final id = await _control.invokeMethod<int>('start');
    if (id == null) {
      throw const HandTrackingException('Camera failed to start.');
    }
    return id;
  }

  Future<void> stop() async {
    try {
      await _control.invokeMethod('stop');
    } on PlatformException {
      // Already stopped / engine detached — nothing to do.
    }
  }

  /// Broadcast stream of processed frames. Lazily bound to the EventChannel.
  Stream<HandFrame> get frames =>
      _frames ??= _events.receiveBroadcastStream().map(_parse).asBroadcastStream();

  HandFrame _parse(dynamic event) {
    if (event is! Map) return HandFrame.empty;
    final rawHands = event['hands'];
    if (rawHands is! List || rawHands.isEmpty) return HandFrame.empty;

    final hands = <Hand>[];
    for (final h in rawHands) {
      if (h is! Map) continue;
      final lm = h['lm'];
      if (lm is! List || lm.length < 63) continue;
      final landmarks = <HandLandmark>[];
      for (var i = 0; i < 21; i++) {
        landmarks.add(HandLandmark(
          (lm[i * 3] as num).toDouble(),
          (lm[i * 3 + 1] as num).toDouble(),
          (lm[i * 3 + 2] as num).toDouble(),
        ));
      }
      hands.add(Hand(landmarks, isRight: h['right'] == true));
    }
    return HandFrame(hands);
  }
}

class HandTrackingException implements Exception {
  const HandTrackingException(this.message);
  final String message;
  @override
  String toString() => message;
}
