import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;

/// Hand-tracking POC (F4, the hero feature) — the *pure* gesture core.
///
/// This file is deliberately renderer- and platform-free: it turns the raw hand
/// landmarks coming off MediaPipe Hand Landmarker into a model transform
/// (translate / rotate / scale). Keeping it pure means the hard part — the
/// gesture→6DoF mapping — is unit-testable on the host without a device, a
/// camera, or a CI build. The native side (CameraX + MediaPipe) only has to
/// feed [HandFrame]s into [HandModelController.update].
///
/// MediaPipe Hand Landmarker emits 21 landmarks per hand, each normalized:
/// x,y in [0,1] over the image, z is depth relative to the wrist (negative =
/// toward the camera). Indices follow the MediaPipe hand model.
class HandLandmark {
  const HandLandmark(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;

  vm.Vector3 get v => vm.Vector3(x, y, z);
}

/// The 21 MediaPipe hand-landmark indices we actually use.
class Hand {
  const Hand(this.landmarks, {this.isRight = true});

  /// Exactly 21 landmarks, MediaPipe order.
  final List<HandLandmark> landmarks;
  final bool isRight;

  HandLandmark get wrist => landmarks[0];
  HandLandmark get thumbTip => landmarks[4];
  HandLandmark get indexMcp => landmarks[5];
  HandLandmark get indexTip => landmarks[8];
  HandLandmark get middleMcp => landmarks[9];
  HandLandmark get middleTip => landmarks[12];

  /// Palm center — average of wrist + the finger MCP knuckles (5,9,13,17).
  /// More stable than any single point as the model's "held" anchor.
  vm.Vector2 get palmCenter {
    final pts = [0, 5, 9, 13, 17];
    var sx = 0.0, sy = 0.0;
    for (final i in pts) {
      sx += landmarks[i].x;
      sy += landmarks[i].y;
    }
    return vm.Vector2(sx / pts.length, sy / pts.length);
  }

  /// Apparent hand size (wrist→middle-MCP length) — a monocular depth proxy:
  /// a bigger hand on screen means it's closer to the camera.
  double get span {
    final dx = middleMcp.x - wrist.x;
    final dy = middleMcp.y - wrist.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// In-plane hand orientation (roll), radians, from the wrist→middle-MCP axis.
  /// Drives wrist-rotate → model yaw.
  double get roll => math.atan2(middleMcp.y - wrist.y, middleMcp.x - wrist.x);

  /// Thumb-tip ↔ index-tip distance, normalized by hand span so it's roughly
  /// scale-invariant to how close the hand is. Small value = pinch ("grab").
  double get pinchRatio {
    final dx = thumbTip.x - indexTip.x;
    final dy = thumbTip.y - indexTip.y;
    final d = math.sqrt(dx * dx + dy * dy);
    final s = span;
    return s <= 1e-6 ? double.infinity : d / s;
  }

  /// Pinching when the thumb/index gap closes below [kPinchEnter] of hand span.
  bool get isPinching => pinchRatio < kPinchEnter;

  /// Pinch thresholds, span-relative so they hold whether the hand is near or
  /// far. The two values give the grab *hysteresis*: a deliberate close
  /// (< [kPinchEnter]) STARTS a grab, and only a clear open (>= [kPinchExit])
  /// releases it. The gap between them stops the grab from flickering on/off
  /// when the ratio hovers right on the edge — the main cause of a grab that
  /// "won't hold".
  static const double kPinchEnter = 0.50;
  static const double kPinchExit = 0.65;
}

/// A single processed camera frame: 0, 1 or 2 detected hands.
class HandFrame {
  const HandFrame(this.hands);
  final List<Hand> hands;

  static const HandFrame empty = HandFrame(<Hand>[]);
  bool get hasHand => hands.isNotEmpty;
  bool get isTwoHand => hands.length >= 2;
}

/// The model pose the controller drives. Pure data; the renderer reads it.
class ModelPose {
  ModelPose({this.tx = 0, this.ty = 0, this.scale = 1.0, this.yaw = 0});

  /// Normalized translation in [-1, 1] view space (0 = center). The renderer
  /// maps this to world units for its camera/framing.
  double tx;
  double ty;

  /// Uniform scale multiplier, clamped to a sane range.
  double scale;

  /// Yaw about the model's vertical axis, radians.
  double yaw;

  ModelPose clone() => ModelPose(tx: tx, ty: ty, scale: scale, yaw: yaw);
}

/// Turns a stream of [HandFrame]s into a smoothly-driven [ModelPose].
///
/// Interaction model (matches the spec — "move hand → model follows; pinch to
/// grab, wrist-rotate to rotate, two-hand stretch to scale"):
///  - One hand, pinching: GRAB. The model tracks the palm (translate) and the
///    wrist roll (rotate). Releasing the pinch drops it in place — no snap.
///  - Two hands: STRETCH. The distance between the two palms sets scale,
///    relative to the span captured when the two-hand gesture started.
///  - No hands / open hand: idle, pose holds.
///
/// Noise is filtered in two places so the model doesn't twitch: [landmarkSmoothing]
/// low-passes the *input* landmarks before any gesture math, and [smoothing]
/// low-passes the *output* pose. Both in (0,1]: 1 = instant/off.
class HandModelController {
  HandModelController({
    this.smoothing = 0.35,
    this.landmarkSmoothing = 1.0,
    this.minScale = 0.25,
    this.maxScale = 4.0,
  });

  /// Output low-pass on the pose, in (0,1]: 1 = instant (no smoothing).
  final double smoothing;

  /// Input low-pass on the raw landmarks, in (0,1]: 1 = off (pass through).
  /// The gesture math (palm, roll, pinch ratio) is built from *differences* of
  /// landmark positions, so single-frame landmark jitter turns into a visible
  /// twitch in the model. Filtering the landmarks *before* that math is the
  /// cheapest way to make control feel fluid. Production uses a value < 1; the
  /// unit tests leave it at 1 for exact, frame-precise math.
  final double landmarkSmoothing;

  final double minScale;
  final double maxScale;

  /// Hand-travel → model-travel gain: a full-frame palm sweep moves the model
  /// [kTranslateGain]× the [-1,1] view range. Kept modest (was 2.0) so jitter
  /// and arm drift don't overshoot — easier to place the model precisely.
  static const double kTranslateGain = 1.5;

  final ModelPose pose = ModelPose();

  // Grab state (one-hand pinch drag).
  bool _grabbing = false;
  vm.Vector2? _grabPalm0; // palm position when the grab started
  double _grabRoll0 = 0; // wrist roll when the grab started
  double _grabSpan0 = 0; // hand span (depth proxy) when the grab started
  double _grabScale0 = 1; // model scale when the grab started
  double _poseTx0 = 0, _poseTy0 = 0, _poseYaw0 = 0; // pose at grab start

  // Stretch state (two-hand scale).
  bool _stretching = false;
  double _stretchSpan0 = 0; // inter-palm distance at stretch start
  double _poseScale0 = 1; // scale at stretch start

  // Input landmark low-pass state: the previous (already-smoothed) hands.
  List<Hand>? _smoothHands;

  bool get isGrabbing => _grabbing;
  bool get isStretching => _stretching;

  /// Feed one processed frame; returns the updated pose.
  ModelPose update(HandFrame frame) {
    final f = _smoothLandmarks(frame);
    if (f.isTwoHand) {
      _updateStretch(f.hands[0], f.hands[1]);
      _grabbing = false;
    } else if (f.hasHand) {
      _stretching = false;
      _updateGrab(f.hands.first);
    } else {
      _grabbing = false;
      _stretching = false;
    }
    return pose;
  }

  /// Exponentially smooths each landmark toward its previous position, pairing
  /// hands by index across frames. A no-op when [landmarkSmoothing] >= 1, on an
  /// empty frame, or on the first frame after a gap (nothing to blend yet).
  HandFrame _smoothLandmarks(HandFrame frame) {
    final prev = _smoothHands;
    if (landmarkSmoothing >= 1.0 || frame.hands.isEmpty || prev == null) {
      _smoothHands = frame.hands;
      return frame;
    }
    final out = <Hand>[];
    for (var i = 0; i < frame.hands.length; i++) {
      final h = frame.hands[i];
      final p =
          (i < prev.length && prev[i].landmarks.length == h.landmarks.length)
              ? prev[i]
              : null;
      out.add(p == null ? h : _lerpHand(p, h));
    }
    _smoothHands = out;
    return HandFrame(out);
  }

  Hand _lerpHand(Hand prev, Hand curr) {
    final a = landmarkSmoothing;
    final lm = List<HandLandmark>.generate(curr.landmarks.length, (i) {
      final p = prev.landmarks[i], c = curr.landmarks[i];
      return HandLandmark(
        p.x + (c.x - p.x) * a,
        p.y + (c.y - p.y) * a,
        p.z + (c.z - p.z) * a,
      );
    });
    return Hand(lm, isRight: curr.isRight);
  }

  void _updateGrab(Hand hand) {
    // Hysteresis: start a grab only on a deliberate pinch (< kPinchEnter), but
    // once grabbing, hold it until the gap clearly opens (>= kPinchExit).
    final holding = _grabbing
        ? hand.pinchRatio < Hand.kPinchExit
        : hand.pinchRatio < Hand.kPinchEnter;
    if (holding) {
      final palm = hand.palmCenter;
      if (!_grabbing) {
        // Capture the reference frame so the model doesn't jump to the hand —
        // it moves *relative* to where the grab began.
        _grabbing = true;
        _grabPalm0 = palm;
        _grabRoll0 = hand.roll;
        _grabSpan0 = hand.span <= 1e-6 ? 1e-6 : hand.span;
        _grabScale0 = pose.scale;
        _poseTx0 = pose.tx;
        _poseTy0 = pose.ty;
        _poseYaw0 = pose.yaw;
        return;
      }
      final p0 = _grabPalm0!;
      // Image x grows rightward, y grows downward. View tx grows rightward,
      // ty grows *upward*, hence the y negation. kTranslateGain maps palm
      // travel to the [-1,1] view range.
      final targetTx =
          (_poseTx0 + (palm.x - p0.x) * kTranslateGain).clamp(-1.0, 1.0);
      final targetTy =
          (_poseTy0 - (palm.y - p0.y) * kTranslateGain).clamp(-1.0, 1.0);
      final targetYaw = _poseYaw0 + _angleDelta(_grabRoll0, hand.roll);
      // ONE-HAND scale via depth: the hand's apparent size (span) grows as it
      // moves toward the camera. So while grabbing, pull the hand closer to
      // enlarge / push away to shrink — no second hand needed (the other hand
      // holds the phone). Lateral moves keep span ~constant, so translate and
      // scale stay largely independent.
      final targetScale =
          (_grabScale0 * (hand.span / _grabSpan0)).clamp(minScale, maxScale);
      pose.tx = _lerp(pose.tx, targetTx);
      pose.ty = _lerp(pose.ty, targetTy);
      pose.yaw = _lerpAngle(pose.yaw, targetYaw);
      pose.scale = _lerp(pose.scale, targetScale);
    } else {
      // Released — leave the model where it is.
      _grabbing = false;
    }
  }

  void _updateStretch(Hand a, Hand b) {
    final pa = a.palmCenter, pb = b.palmCenter;
    final span = (pa - pb).length;
    if (!_stretching) {
      _stretching = true;
      _stretchSpan0 = span <= 1e-6 ? 1e-6 : span;
      _poseScale0 = pose.scale;
      return;
    }
    final ratio = span / _stretchSpan0;
    final target = (_poseScale0 * ratio).clamp(minScale, maxScale);
    pose.scale = _lerp(pose.scale, target);
  }

  double _lerp(double from, double to) => from + (to - from) * smoothing;

  /// Angle-aware lerp so yaw doesn't take the long way around ±π.
  double _lerpAngle(double from, double to) =>
      from + _angleDelta(from, to) * smoothing;

  /// Shortest signed angular difference to→from in (-π, π].
  static double _angleDelta(double from, double to) {
    var d = (to - from) % (2 * math.pi);
    if (d > math.pi) d -= 2 * math.pi;
    if (d < -math.pi) d += 2 * math.pi;
    return d;
  }

  void reset() {
    pose
      ..tx = 0
      ..ty = 0
      ..scale = 1.0
      ..yaw = 0;
    _grabbing = false;
    _stretching = false;
    _smoothHands = null;
  }
}
