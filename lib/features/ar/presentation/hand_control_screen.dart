import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../data/hand_landmarker_channel.dart';
import '../domain/hand_gesture.dart';

/// F4 hand-tracking POC (the hero feature) — "your 3D, in your hand."
///
/// SPIKE SCOPE (iteration 1): prove the control loop end-to-end on a real
/// device — native MediaPipe emits hand landmarks, the [HandModelController]
/// turns them into a 6DoF pose, and an object on screen follows the hand
/// (pinch-grab to move + wrist-rotate, two hands to scale). It renders the live
/// camera, the detected hand skeleton, and a proxy model driven by the gesture
/// pose. Iteration 2 swaps the proxy for the real Thermion-rendered model and
/// polishes preview orientation; that's why [glbAbsolutePath] is carried here.
class HandControlScreen extends StatefulWidget {
  const HandControlScreen({
    super.key,
    required this.glbAbsolutePath,
    required this.title,
  });

  final String glbAbsolutePath;
  final String title;

  @override
  State<HandControlScreen> createState() => _HandControlScreenState();
}

class _HandControlScreenState extends State<HandControlScreen> {
  final HandLandmarkerChannel _channel = HandLandmarkerChannel();
  final HandModelController _controller = HandModelController();

  StreamSubscription<HandFrame>? _sub;
  int? _textureId;
  HandFrame _lastFrame = HandFrame.empty;
  String? _error;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = 'Camera permission is needed for hand tracking.';
        });
      }
      return;
    }
    try {
      final id = await _channel.start();
      _sub = _channel.frames.listen(_onFrame);
      if (mounted) {
        setState(() {
          _textureId = id;
          _starting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = '$e';
        });
      }
    }
  }

  void _onFrame(HandFrame frame) {
    _controller.update(frame);
    if (mounted) {
      // The pose lives on the controller; setState just repaints with it.
      setState(() => _lastFrame = frame);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pose = _controller.pose;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${widget.title} — Hand control'),
        actions: [
          IconButton(
            tooltip: 'Reset',
            onPressed: () => setState(_controller.reset),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: _error != null
          ? _ErrorView(message: _error!)
          : _starting || _textureId == null
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(constraints.maxWidth, constraints.maxHeight);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        // Live camera preview (native CameraX → Flutter texture).
                        Texture(textureId: _textureId!),
                        // Detected hand skeleton, mapped from normalized coords.
                        CustomPaint(
                          painter: _SkeletonPainter(_lastFrame),
                          size: size,
                        ),
                        // Proxy model that follows the gesture pose. (Iteration
                        // 2: the real 3D model.)
                        _ProxyModel(pose: pose, viewport: size),
                        // Gesture HUD — makes the on-device proof legible.
                        _Hud(
                          frame: _lastFrame,
                          controller: _controller,
                        ),
                        const Positioned(
                          left: 0,
                          right: 0,
                          bottom: 18,
                          child: _Hint(),
                        ),
                      ],
                    );
                  },
                ),
    );
  }
}

/// Draws the 21-landmark hand skeleton over the preview.
class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter(this.frame);
  final HandFrame frame;

  // MediaPipe hand connections (bone pairs).
  static const List<List<int>> _bones = [
    [0, 1], [1, 2], [2, 3], [3, 4], // thumb
    [0, 5], [5, 6], [6, 7], [7, 8], // index
    [5, 9], [9, 10], [10, 11], [11, 12], // middle
    [9, 13], [13, 14], [14, 15], [15, 16], // ring
    [13, 17], [17, 18], [18, 19], [19, 20], // pinky
    [0, 17], // palm base
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final bone = Paint()
      ..color = const Color(0xFF6EE7F0)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final joint = Paint()..color = const Color(0xFFB388FF);

    for (final hand in frame.hands) {
      Offset at(int i) =>
          Offset(hand.landmarks[i].x * size.width, hand.landmarks[i].y * size.height);
      for (final b in _bones) {
        canvas.drawLine(at(b[0]), at(b[1]), bone);
      }
      for (var i = 0; i < 21; i++) {
        canvas.drawCircle(at(i), i == 4 || i == 8 ? 7 : 4, joint);
      }
    }
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) => old.frame != frame;
}

/// A simple 3D-looking cube proxy that translates/scales/rotates with the pose,
/// proving the gesture→6DoF mapping visually without the renderer in the loop.
class _ProxyModel extends StatelessWidget {
  const _ProxyModel({required this.pose, required this.viewport});
  final ModelPose pose;
  final Size viewport;

  @override
  Widget build(BuildContext context) {
    final base = math.min(viewport.width, viewport.height) * 0.28;
    final dx = pose.tx * viewport.width * 0.42;
    final dy = -pose.ty * viewport.height * 0.42; // ty is up-positive
    return Center(
      child: Transform.translate(
        offset: Offset(dx, dy),
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015) // a little perspective
            ..rotateX(0.5)
            ..rotateY(pose.yaw)
            ..scaleByDouble(pose.scale, pose.scale, pose.scale, 1),
          child: Container(
            width: base,
            height: base,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF8B5CF6), Color(0xFF22D3EE)],
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF22D3EE).withValues(alpha: 0.4),
                  blurRadius: 30,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(Icons.view_in_ar, color: Colors.white70, size: 48),
          ),
        ),
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  const _Hud({required this.frame, required this.controller});
  final HandFrame frame;
  final HandModelController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.pose;
    final state = controller.isStretching
        ? 'STRETCH (scale)'
        : controller.isGrabbing
            ? 'GRAB (move/rotate)'
            : frame.hasHand
                ? 'tracking'
                : 'show your hand';
    String n(double v) => v.toStringAsFixed(2);
    return Positioned(
      left: 12,
      top: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
              color: Colors.white, fontSize: 12, height: 1.4, fontFamily: 'monospace'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('hands: ${frame.hands.length}   •   $state'),
              Text('pos: ${n(p.tx)}, ${n(p.ty)}   scale: ${n(p.scale)}'),
              Text('yaw: ${(p.yaw * 180 / math.pi).toStringAsFixed(0)}°'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Text(
          'Pinch to grab & move • twist wrist to rotate • two hands to resize',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            TextButton(
              onPressed: openAppSettings,
              child: const Text('Open settings'),
            ),
          ],
        ),
      ),
    );
  }
}
