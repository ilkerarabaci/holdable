import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Image-based-lighting environments (Faz C / PO #6).
///
/// Each environment is a stylized, *procedurally painted* backdrop — no HDRI /
/// KTX assets. It renders BEHIND the (transparent) Thermion texture in the
/// viewer Stack, and the renderer applies a matching directional-light preset.
/// The looks reproduce the approved claude.ai/design boards (café / sky /
/// studio) directly from their gradient + bloom specs.
enum AppEnvironment { none, cafe, sky, studio }

extension AppEnvironmentX on AppEnvironment {
  /// Short picker label.
  String get label => switch (this) {
        AppEnvironment.none => 'None',
        AppEnvironment.cafe => 'Café',
        AppEnvironment.sky => 'Sky',
        AppEnvironment.studio => 'Studio',
      };

  /// Persisted token (stable across renames).
  String get token => name;

  static AppEnvironment fromToken(String? t) {
    for (final e in AppEnvironment.values) {
      if (e.name == t) return e;
    }
    return AppEnvironment.none;
  }
}

/// Full-bleed procedural backdrop for [environment], painted behind the
/// transparent 3D view. [fallback] is the flat colour used for [AppEnvironment.none]
/// (the viewer's normal background) so that "None" looks exactly like today.
class EnvironmentBackdrop extends StatelessWidget {
  const EnvironmentBackdrop({
    super.key,
    required this.environment,
    required this.fallback,
  });

  final AppEnvironment environment;
  final Color fallback;

  @override
  Widget build(BuildContext context) {
    switch (environment) {
      case AppEnvironment.none:
        return ColoredBox(color: fallback);
      case AppEnvironment.cafe:
        return const _Backdrop(
          gradient: LinearGradient(
            begin: Alignment(-0.18, -1.0),
            end: Alignment(0.18, 1.0),
            colors: [
              Color(0xFF2C1A10),
              Color(0xFF5E3819),
              Color(0xFF92552A),
              Color(0xFF6D3F1C),
              Color(0xFF241509),
            ],
            stops: [0.0, 0.28, 0.5, 0.7, 1.0],
          ),
          painter: _CafePainter(),
        );
      case AppEnvironment.sky:
        return const _Backdrop(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF3C7CC4),
              Color(0xFF6BA4DC),
              Color(0xFFB4D8F0),
              Color(0xFFE7F3FB),
            ],
            stops: [0.0, 0.38, 0.72, 1.0],
          ),
          painter: _SkyPainter(),
        );
      case AppEnvironment.studio:
        return const _Backdrop(
          gradient: RadialGradient(
            center: Alignment(0.0, -0.4),
            radius: 1.15,
            colors: [Color(0xFFF8F9FB), Color(0xFFE4E7EC), Color(0xFFC6CBD2)],
            stops: [0.0, 0.56, 1.0],
          ),
          painter: _StudioPainter(),
        );
    }
  }
}

/// A base gradient with a blooms/bokeh [painter] on top.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.gradient, required this.painter});
  final Gradient gradient;
  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: CustomPaint(painter: painter, size: Size.infinite),
    );
  }
}

void _disc(Canvas c, Size s, double fx, double fy, double r, Color col,
    double blurSigma) {
  final center = Offset(s.width * fx, s.height * fy);
  c.drawCircle(
    center,
    r,
    Paint()
      ..shader = ui.Gradient.radial(center, r, [col, col.withValues(alpha: 0)])
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma),
  );
}

class _CafePainter extends CustomPainter {
  const _CafePainter();
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    // Warm window / sun bloom, top-right.
    final sun = Offset(w * 0.82, h * 0.15);
    c.drawCircle(
      sun,
      w * 0.44,
      Paint()
        ..shader = ui.Gradient.radial(sun, w * 0.44, const [
          Color(0xE6FFCE84),
          Color(0x38FFA856),
          Color(0x00FFA856),
        ], const [
          0.0,
          0.46,
          1.0
        ])
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    // Defocused warm storefront bokeh.
    _disc(c, s, 0.11, 0.17, w * 0.06, const Color(0xBFFFD096), 9);
    _disc(c, s, 0.60, 0.12, w * 0.085, const Color(0x99FFB670), 14);
    _disc(c, s, 0.80, 0.39, w * 0.05, const Color(0x8CFFD296), 10);
    _disc(c, s, 0.15, 0.50, w * 0.06, const Color(0x73FFA45C), 13);
    _disc(c, s, 0.45, 0.23, w * 0.028, const Color(0xCCFFF2D6), 5);
    // Ground darkening, bottom ~30%.
    final gy = h * 0.70;
    c.drawRect(
      Rect.fromLTWH(0, gy, w, h - gy),
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, gy), Offset(0, h),
            const [Color(0x00120B06), Color(0xB3120B06)]),
    );
    // Warm reflective sheen on the ground.
    final sheen = Offset(w * 0.5, h * 0.84);
    c.drawOval(
      Rect.fromCenter(center: sheen, width: w * 0.64, height: h * 0.12),
      Paint()
        ..shader = ui.Gradient.radial(sheen, w * 0.32,
            const [Color(0x57FFBE6C), Color(0x00FFBE6C)])
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 11),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _SkyPainter extends CustomPainter {
  const _SkyPainter();
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    // Bright top bloom.
    _disc(c, s, 0.5, -0.02, w * 0.5, const Color(0x8CFFFFFF), 16);
    // Soft cloud banks (defocused white).
    _disc(c, s, 0.30, 0.13, w * 0.30, const Color(0x9EFFFFFF), 11);
    _disc(c, s, 0.74, 0.22, w * 0.22, const Color(0x94FFFFFF), 9);
    _disc(c, s, 0.22, 0.50, w * 0.34, const Color(0xEBFFFFFF), 14);
    _disc(c, s, 0.72, 0.40, w * 0.36, const Color(0xD9FFFFFF), 15);
    // Low cloud bank at the base + haze.
    _disc(c, s, 0.5, 0.98, w * 0.7, const Color(0xF5FFFFFF), 16);
    c.drawRect(
      Rect.fromLTWH(0, h * 0.66, w, h * 0.34),
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, h * 0.66), Offset(0, h),
            const [Color(0x00FFFFFF), Color(0x52FFFFFF)]),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _StudioPainter extends CustomPainter {
  const _StudioPainter();
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    // Two soft softbox glows, top-left and top-right.
    _disc(c, s, 0.06, 0.06, w * 0.30, const Color(0xCCFFFFFF), 22);
    _disc(c, s, 0.94, 0.06, w * 0.30, const Color(0xCCFFFFFF), 22);
    // Subtle horizon seam highlight above mid.
    _disc(c, s, 0.5, 0.46, w * 0.42, const Color(0x80FFFFFF), 12);
    // Floor: a gentle darker-grey vertical band at the bottom (cyclorama curve).
    c.drawRect(
      Rect.fromLTWH(0, h * 0.62, w, h * 0.38),
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, h * 0.62), Offset(0, h),
            const [Color(0x00A8AFB8), Color(0xB3A8AFB8)]),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
