import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../viewer/presentation/scene_view.dart';
import '../data/hand_landmarker_channel.dart';
import '../domain/hand_gesture.dart';

/// F4 hand-tracking — "your 3D, in your hand." Control the model with hand
/// gestures: pinch-grab to move + wrist-twist to rotate, two hands to resize.
///
/// This is an OVERLAY over the viewer's existing model scene — deliberately NOT
/// its own [ModelSceneView]. Two simultaneous Thermion viewers contend for the
/// Filament swapchain and BOTH go blank (device-confirmed, alpha.41: opening a
/// second viewer blanked the first too). So this drives the viewer's single
/// [scene] controller via [ModelSceneController.setHandPose] and only adds the
/// camera + hand-skeleton picture-in-picture and a gesture HUD on top; the model
/// itself renders in the viewer underneath and shows through the transparent
/// regions of this overlay.
class HandControlOverlay extends StatefulWidget {
  const HandControlOverlay({
    super.key,
    required this.scene,
    required this.onClose,
  });

  final ModelSceneController scene;
  final VoidCallback onClose;

  @override
  State<HandControlOverlay> createState() => _HandControlOverlayState();
}

class _HandControlOverlayState extends State<HandControlOverlay> {
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
    final pose = _controller.update(frame);
    widget.scene.setHandPose(
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
    return Stack(
      fit: StackFit.expand,
      children: [
        // Top bar: title + reset + close. Sits over the model.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.55),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Close hand control',
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: widget.onClose,
                  ),
                  const Expanded(
                    child: Text('Hand control',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: 'Reset',
                    icon: const Icon(Icons.restart_alt, color: Colors.white),
                    onPressed: () => setState(_controller.reset),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
        if (_error != null)
          Center(child: _ErrorChip(message: _error!))
        else if (_starting)
          const Center(
              child: _Chip(child: Text('Starting camera…',
                  style: TextStyle(color: Colors.white)))),
        if (_error == null) ...[
          // Gesture HUD (below the top bar).
          Positioned(
            left: 12,
            top: 84,
            child: _Hud(frame: _lastFrame, controller: _controller),
          ),
          // Camera + hand-skeleton picture-in-picture (aim + tracking feedback).
          if (_textureId != null)
            Positioned(
              right: 14,
              bottom: 88,
              child: _CameraPip(textureId: _textureId!, frame: _lastFrame),
            ),
          const Positioned(left: 0, right: 0, bottom: 22, child: _Hint()),
        ],
      ],
    );
  }
}

/// Small live-camera box with the detected hand skeleton drawn over it.
class _CameraPip extends StatelessWidget {
  const _CameraPip({required this.textureId, required this.frame});
  final int textureId;
  final HandFrame frame;

  @override
  Widget build(BuildContext context) {
    const w = 130.0, h = 174.0;
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
    return _Chip(
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
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: _Chip(
        child: Text(
          'Pinch to grab & move • twist wrist to rotate • two hands to resize',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

class _ErrorChip extends StatelessWidget {
  const _ErrorChip({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return _Chip(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
          TextButton(
              onPressed: openAppSettings, child: const Text('Open settings')),
        ],
      ),
    );
  }
}
