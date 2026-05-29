import 'dart:ui';

import 'package:flutter/material.dart';

import '../../app/theme/prism_colors.dart';
import '../../app/theme/prism_gradient.dart';

/// Liquid-glass surface from the Prism design system
/// (docs/design-handoff.md §Component patterns).
///
/// Layers: gradient fill (glass1→glass2) · optional backdrop blur · top sheen ·
/// iridescent accent edge when [accentEdge] · hairline border.
///
/// **Android perf:** [BackdropFilter] is expensive — use blur only where a few
/// cards are on screen. Pass `blur: false` for long lists / low-end devices
/// (the §5 fallback to a flat surface).
class PrismCard extends StatelessWidget {
  const PrismCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.blur = true,
    this.accentEdge = false,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 20,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool blur;
  final bool accentEdge;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final radius = BorderRadius.circular(borderRadius);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.glass1, c.glass2],
        ),
        border: Border.all(
          color: accentEdge ? Colors.transparent : c.borderHairline,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Top sheen highlight.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(borderRadius),
                  topRight: Radius.circular(borderRadius),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.06),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );

    if (blur) {
      surface = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: surface,
      );
    }

    Widget card = ClipRRect(borderRadius: radius, child: surface);

    // Iridescent accent edge (e.g. on press / selection).
    if (accentEdge) {
      card = Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: PrismGradient.diagonal,
        ),
        padding: const EdgeInsets.all(1.2),
        child: card,
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: radius,
        child: card,
      ),
    );
  }
}
