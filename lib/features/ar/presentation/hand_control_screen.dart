import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../viewer/presentation/scene_view.dart';
import '../data/hand_landmarker_channel.dart';
import '../domain/hand_gesture.dart';

/// F4 hand-tracking — "your 3D, in your hand."
///
/// Iteration 2: the REAL model (rendered by the proven Thermion [ModelSceneView])
/// is driven by hand gestures — pinch-grab to move + wrist-twist to rotate, two
/// hands to resize. The live camera + detected hand skeleton sit in a corner
/// picture-in-picture so you can aim and see the tracking. (Placing the model
/// over the live camera as an AR overlay needs a transparent Filament swapchain,
/// which this thermion version doesn't expose — that lands with the ARCore AR
/// epic. This mode is gesture *manipulation* of the model, distinct from AR
/// placement.)
class HandControlScreen extends StatefulWidget {
  const HandControlScreen({
    super.key,
    required this.filePath,
    required this.format,
    required this.title,
  });

  /// The model's own file + format — rendered at full fidelity (textures and
  /// all), no glb round-trip needed.
  final String filePath;
  final String format;
  final String title;

  @override
  State<HandControlScreen> createState() => _HandControlScreenState();
}

class _HandControlScreenState extends State<HandControlScreen> {
  final HandLandmarkerChannel _channel = HandLandmarkerChannel();
  final HandModelController _controller = HandModelController();
  final ModelSceneController _scene = ModelSceneController();

  StreamSubscription<HandFrame>? _sub;
  int? _textureId;
  HandFrame _lastFrame = HandFrame.empty;
  String? _error;
  bool _starting = true;
  bool _sceneLoading = true;

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
    final pose = _controller.update(frame);
    // Drive the real model's framing from the gesture pose.
    _scene.setHandPose(
      yaw: pose.yaw,
      scale: pose.scale,
      tx: pose.tx,
      ty: pose.ty,
    );
    if (mounted) setState(() => _lastFrame = frame);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E12),
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
          : Stack(
              fit: StackFit.expand,
              children: [
                // The real model, full-screen, driven by the hand pose.
                ModelSceneView(
                  controller: _scene,
                  filePath: widget.filePath,
                  format: widget.format,
                  background: const Color(0xFF0E0E12),
                  onStatus: (s) {
                    if (mounted && s.loading != _sceneLoading) {
                      setState(() => _sceneLoading = s.loading);
                    }
                  },
                ),
                if (_sceneLoading || _starting)
                  const Center(
                      child: CircularProgressIndicator(color: Colors.white)),
                // Camera + hand-skeleton picture-in-picture (tracking feedback).
                if (_textureId != null)
                  Positioned(
                    right: 14,
                    bottom: 96,
                    child: _CameraPip(
                      textureId: _textureId!,
                      frame: _lastFrame,
                    ),
                  ),
                _Hud(frame: _lastFrame, controller: _controller),
                const Positioned(
                    left: 0, right: 0, bottom: 18, child: _Hint()),
              ],
            ),
    );
  }
}

/// Small live-camera box (bottom corner) with the detected hand skeleton drawn
/// over it — lets the user aim their hand and confirm tracking.
class _CameraPip extends StatelessWidget {
  const _CameraPip({required this.textureId, required this.frame});
  final int textureId;
  final HandFrame frame;

  @override
  Widget build(BuildContext context) {
    const w = 132.0, h = 176.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Texture(textureId: textureId),
            CustomPaint(painter: _SkeletonPainter(frame)),
            // A subtle border so the PiP reads as a distinct panel.
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35), width: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the 21-landmark hand skeleton, normalized coords → the paint box.
class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter(this.frame);
  final HandFrame frame;

  static const List<List<int>> _bones = [
    [0, 1], [1, 2], [2, 3], [3, 4],
    [0, 5], [5, 6], [6, 7], [7, 8],
    [5, 9], [9, 10], [10, 11], [11, 12],
    [9, 13], [13, 14], [14, 15], [15, 16],
    [13, 17], [17, 18], [18, 19], [19, 20],
    [0, 17],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final bone = Paint()
      ..color = const Color(0xFF6EE7F0)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final joint = Paint()..color = const Color(0xFFB388FF);
    for (final hand in frame.hands) {
      Offset at(int i) => Offset(
          hand.landmarks[i].x * size.width, hand.landmarks[i].y * size.height);
      for (final b in _bones) {
        canvas.drawLine(at(b[0]), at(b[1]), bone);
      }
      for (var i = 0; i < 21; i++) {
        canvas.drawCircle(at(i), i == 4 || i == 8 ? 4 : 2.5, joint);
      }
    }
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) => old.frame != frame;
}

class _Hud extends StatelessWidget {
  const _Hud({required this.frame, required this.controller});
  final HandFrame frame;
  final HandModelController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.pose;
    final state = controller.isStretching
        ? 'STRETCH (resize)'
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
              color: Colors.white,
              fontSize: 12,
              height: 1.4,
              fontFamily: 'monospace'),
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
                onPressed: openAppSettings, child: const Text('Open settings')),
          ],
        ),
      ),
    );
  }
}
