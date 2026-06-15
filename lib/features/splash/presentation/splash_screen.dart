import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../onboarding/data/onboarding_controller.dart';

/// Brand splash shown for ~1.7s on cold start (PO #1), then hands off to the
/// onboarding gate (first run) or the library. Pairs with the Android 12 system
/// splash (res/values-v31/styles.xml).
///
/// Appearance: variant B (PO pick) — the iridescent "prism light sweep". Painted
/// on a FIXED dark brand backdrop (independent of the app's light/dark theme) so
/// the gradient always pops — on a light-mode device the cream background washed
/// the wordmark out. The Prism gradient sweeps across the wordmark, which scales
/// + fades in, while a glowing spectrum bar draws out underneath. Plays once and
/// navigates on completion (no repeating loop), so `pumpAndSettle()` flows
/// straight through it.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) _go();
    });

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.40, curve: Curves.easeOut),
  );
  late final Animation<double> _scale = Tween<double>(begin: 0.88, end: 1.0)
      .animate(CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
  ));
  // Slides the iridescence horizontally across the wordmark — the "sweep".
  late final Animation<double> _sweep = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.85, curve: Curves.easeInOut),
  );
  // Glowing spectrum bar draws out from centre once the wordmark has landed.
  late final Animation<double> _bar = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.40, 0.92, curve: Curves.easeOutCubic),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  void _go() {
    if (!mounted) return;
    final onboarded = ref.read(onboardingShownProvider);
    context.go(onboarded ? Routes.library : Routes.onboarding);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      // Fixed dark brand backdrop so the iridescent wordmark always pops,
      // regardless of the app's light/dark theme.
      backgroundColor: PrismColors.dark.bg,
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: _fade.value,
                child: Transform.scale(
                  scale: _scale.value,
                  child: ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (bounds) {
                      // A gradient three times the wordmark width, slid
                      // left→right so the prism colours sweep across as it
                      // appears. Symmetric stops keep the edges from popping.
                      final shift = (_sweep.value * 2 - 1) * bounds.width;
                      return const LinearGradient(
                        colors: [
                          PrismGradient.pink,
                          PrismGradient.violet,
                          PrismGradient.cyan,
                          PrismGradient.violet,
                          PrismGradient.pink,
                        ],
                        stops: [0.0, 0.25, 0.5, 0.75, 1.0],
                      ).createShader(Rect.fromLTWH(
                          -bounds.width + shift, 0, bounds.width * 3, bounds.height));
                    },
                    child: Text(
                      'Holdable',
                      style: (t.displayLarge ?? const TextStyle()).copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Container(
                height: 4,
                width: 170 * _bar.value,
                decoration: BoxDecoration(
                  gradient: PrismGradient.linear,
                  borderRadius: const BorderRadius.all(Radius.circular(3)),
                  boxShadow: [
                    BoxShadow(
                      color: PrismGradient.violet
                          .withValues(alpha: 0.55 * _bar.value),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
