import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:holdable/features/ar/domain/hand_gesture.dart';

/// Builds a 21-landmark hand from a few key points; the rest are filled near
/// the wrist so palm-center math stays well-defined. All coords normalized.
Hand _hand({
  required double wx,
  required double wy,
  required double mmx, // middle-MCP (index 9)
  required double mmy,
  required double thumbX,
  required double thumbY,
  required double indexX,
  required double indexY,
}) {
  final pts = List<HandLandmark>.generate(21, (_) => HandLandmark(wx, wy, 0));
  pts[0] = HandLandmark(wx, wy, 0); // wrist
  pts[4] = HandLandmark(thumbX, thumbY, 0); // thumb tip
  pts[5] = HandLandmark(mmx, mmy, 0); // index MCP (near middle MCP for span)
  pts[8] = HandLandmark(indexX, indexY, 0); // index tip
  pts[9] = HandLandmark(mmx, mmy, 0); // middle MCP
  pts[13] = HandLandmark(mmx, mmy, 0);
  pts[17] = HandLandmark(mmx, mmy, 0);
  return Hand(pts);
}

/// An open (not pinching) hand centered at [cx,cy], pointing "up" the image.
Hand _openHand(double cx, double cy) => _hand(
      wx: cx,
      wy: cy + 0.15,
      mmx: cx,
      mmy: cy - 0.15, // hand points up → span ~0.30
      thumbX: cx - 0.12, // thumb & index far apart → open
      thumbY: cy,
      indexX: cx + 0.12,
      indexY: cy - 0.20,
    );

/// A pinching hand centered at [cx,cy]: thumb tip and index tip coincide.
/// [span] is the wrist→middle-MCP length (the depth proxy: larger = hand closer
/// to the camera), used to test one-hand scale.
Hand _pinchHand(double cx, double cy,
    {double roll = -math.pi / 2, double span = 0.30}) {
  // Place middle-MCP along [roll] from the wrist so we can drive yaw.
  final wristToMcp = span;
  final wx = cx, wy = cy + 0.0;
  final mmx = wx + wristToMcp * math.cos(roll);
  final mmy = wy + wristToMcp * math.sin(roll);
  // Thumb tip == index tip (pinch). Put them at the fingertip-ish location.
  final px = cx + 0.02, py = cy - 0.25;
  return _hand(
    wx: wx,
    wy: wy,
    mmx: mmx,
    mmy: mmy,
    thumbX: px,
    thumbY: py,
    indexX: px,
    indexY: py,
  );
}

/// A hand with a *specific* pinch ratio (thumb/index gap = [ratio] × span) —
/// used to exercise the grab hysteresis band between kPinchEnter and kPinchExit.
Hand _gapHand(double cx, double cy,
    {required double ratio, double span = 0.30}) {
  final gap = ratio * span; // thumb/index separated horizontally by `gap`
  return _hand(
    wx: cx,
    wy: cy,
    mmx: cx,
    mmy: cy - span, // roll -pi/2, exact span
    thumbX: cx - gap / 2,
    thumbY: cy - 0.25,
    indexX: cx + gap / 2,
    indexY: cy - 0.25,
  );
}

void main() {
  group('Hand landmark math', () {
    test('open hand is not pinching, pinch hand is', () {
      expect(_openHand(0.5, 0.5).isPinching, isFalse);
      expect(_pinchHand(0.5, 0.5).isPinching, isTrue);
    });

    test('palm center sits between wrist and knuckles', () {
      final h = _openHand(0.5, 0.5);
      final c = h.palmCenter;
      expect(c.x, closeTo(0.5, 0.05));
      expect(c.y, closeTo(0.5, 0.1));
    });

    test('roll reflects hand orientation', () {
      // Hand pointing straight up the image: middle-MCP above wrist → atan2 of
      // a negative dy → about -pi/2.
      final up = _openHand(0.5, 0.5);
      expect(up.roll, closeTo(-math.pi / 2, 0.2));
    });
  });

  group('HandModelController — grab to translate', () {
    test('open hand does not move the model', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_openHand(0.2, 0.2)]));
      expect(c.isGrabbing, isFalse);
      expect(c.pose.tx, 0);
      expect(c.pose.ty, 0);
    });

    test('pinch then move drags the model; right+up is +tx/+ty', () {
      final c = HandModelController(smoothing: 1.0); // no smoothing for exact math
      // Start the grab at center.
      c.update(HandFrame([_pinchHand(0.5, 0.5)]));
      expect(c.isGrabbing, isTrue);
      // Move hand right (+x) and up (-y in image) by 0.1 each.
      c.update(HandFrame([_pinchHand(0.6, 0.4)]));
      // tx = (0.6-0.5)*gain ; ty = -(palm.y delta = -0.1)*gain  → both +0.1*gain.
      expect(c.pose.tx, closeTo(0.1 * HandModelController.kTranslateGain, 1e-6));
      expect(c.pose.ty, closeTo(0.1 * HandModelController.kTranslateGain, 1e-6));
    });

    test('releasing the pinch leaves the model in place (no snap-back)', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_pinchHand(0.5, 0.5)]));
      c.update(HandFrame([_pinchHand(0.7, 0.5)]));
      final txAfterDrag = c.pose.tx;
      c.update(HandFrame([_openHand(0.7, 0.5)])); // release
      expect(c.isGrabbing, isFalse);
      expect(c.pose.tx, txAfterDrag);
    });

    test('re-grabbing is relative — no jump to the new hand position', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_pinchHand(0.5, 0.5)]));
      c.update(HandFrame([_pinchHand(0.7, 0.5)])); // tx -> 0.2*gain
      c.update(HandFrame([_openHand(0.7, 0.5)])); // release at far side
      // Re-grab somewhere else and nudge: pose must move only by the new delta.
      c.update(HandFrame([_pinchHand(0.2, 0.5)])); // re-grab, no move yet
      expect(c.pose.tx, closeTo(0.2 * HandModelController.kTranslateGain, 1e-6));
      c.update(HandFrame([_pinchHand(0.25, 0.5)])); // +0.05*gain
      expect(
          c.pose.tx, closeTo(0.25 * HandModelController.kTranslateGain, 1e-6));
    });
  });

  group('HandModelController — grab hysteresis & input smoothing', () {
    test('a grab holds through a partial open (hysteresis band)', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_pinchHand(0.5, 0.5)])); // ratio 0 < enter → grab
      expect(c.isGrabbing, isTrue);
      // Ratio between enter (0.50) and exit (0.65): still held, no flicker.
      c.update(HandFrame([_gapHand(0.5, 0.5, ratio: 0.58)]));
      expect(c.isGrabbing, isTrue);
      // Opening clearly past exit releases.
      c.update(HandFrame([_openHand(0.5, 0.5)]));
      expect(c.isGrabbing, isFalse);
    });

    test('a ratio in the hysteresis band does not START a grab', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_gapHand(0.5, 0.5, ratio: 0.58)]));
      expect(c.isGrabbing, isFalse); // needs < enter (0.50) to begin
    });

    test('landmark smoothing damps a sudden jump (input low-pass)', () {
      final c = HandModelController(smoothing: 1.0, landmarkSmoothing: 0.5);
      c.update(HandFrame([_pinchHand(0.5, 0.5)])); // grab; first frame passes raw
      c.update(HandFrame([_pinchHand(0.7, 0.5)])); // palm smoothed 0.5 → 0.6
      // Half the raw 0.2 step: tx ≈ 0.1 × gain, not 0.2 × gain.
      expect(c.pose.tx, closeTo(0.1 * HandModelController.kTranslateGain, 1e-6));
    });

    test('landmark smoothing off (==1) keeps frame-precise math', () {
      final c = HandModelController(smoothing: 1.0, landmarkSmoothing: 1.0);
      c.update(HandFrame([_pinchHand(0.5, 0.5)]));
      c.update(HandFrame([_pinchHand(0.7, 0.5)]));
      expect(c.pose.tx, closeTo(0.2 * HandModelController.kTranslateGain, 1e-6));
    });
  });

  group('HandModelController — two-hand stretch to scale', () {
    test('spreading hands apart scales up, bringing together scales down', () {
      final c = HandModelController(smoothing: 1.0);
      // Start two-hand at span 0.4 (hands at x=0.3 and x=0.7, same y).
      c.update(HandFrame([_openHand(0.3, 0.5), _openHand(0.7, 0.5)]));
      expect(c.isStretching, isTrue);
      expect(c.pose.scale, closeTo(1.0, 1e-9)); // baseline captured
      // Spread to span 0.8 → 2x.
      c.update(HandFrame([_openHand(0.1, 0.5), _openHand(0.9, 0.5)]));
      expect(c.pose.scale, closeTo(2.0, 0.05));
      // Bring to span 0.2 → 0.5x of original baseline.
      c.update(HandFrame([_openHand(0.4, 0.5), _openHand(0.6, 0.5)]));
      expect(c.pose.scale, closeTo(0.5, 0.05));
    });

    test('scale is clamped to [minScale, maxScale]', () {
      final c = HandModelController(smoothing: 1.0, maxScale: 3.0);
      c.update(HandFrame([_openHand(0.49, 0.5), _openHand(0.51, 0.5)])); // tiny span
      c.update(HandFrame([_openHand(0.0, 0.5), _openHand(1.0, 0.5)])); // huge span
      expect(c.pose.scale, lessThanOrEqualTo(3.0));
    });
  });

  group('HandModelController — one-hand depth scale', () {
    test('pulling the hand closer (bigger span) scales up; pushing away down', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_pinchHand(0.5, 0.5, span: 0.30)])); // grab baseline
      expect(c.isGrabbing, isTrue);
      expect(c.pose.scale, closeTo(1.0, 1e-9));
      // Hand closer → span ×1.5 → scale ~1.5
      c.update(HandFrame([_pinchHand(0.5, 0.5, span: 0.45)]));
      expect(c.pose.scale, closeTo(1.5, 0.02));
      // Hand farther → span ×0.5 of baseline → scale ~0.5
      c.update(HandFrame([_pinchHand(0.5, 0.5, span: 0.15)]));
      expect(c.pose.scale, closeTo(0.5, 0.02));
    });

    test('an open (non-grabbing) hand never changes scale', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_openHand(0.5, 0.5)]));
      expect(c.pose.scale, 1.0);
    });
  });

  group('HandModelController — wrist rotate to yaw', () {
    test('rotating the wrist while grabbing rotates the model', () {
      final c = HandModelController(smoothing: 1.0);
      c.update(HandFrame([_pinchHand(0.5, 0.5, roll: -math.pi / 2)]));
      final yaw0 = c.pose.yaw;
      // Rotate the hand by +0.5 rad.
      c.update(HandFrame([_pinchHand(0.5, 0.5, roll: -math.pi / 2 + 0.5)]));
      expect(c.pose.yaw - yaw0, closeTo(0.5, 0.05));
    });
  });
}
