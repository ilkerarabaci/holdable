import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../onboarding/data/onboarding_controller.dart';

/// Brand splash shown for ~1.3s on cold start (PO #1), then hands off to the
/// onboarding gate (first run) or the library. Pairs with the Android 12 system
/// splash (res/values-v31/styles.xml): the OS paints the app icon while the
/// engine warms up, and this continues the brand moment and dissolves into the
/// app.
///
/// Appearance: variant B (PO pick) — the iridescent "prism light sweep". The
/// Prism gradient slides across the wordmark while a spectrum bar draws out
/// underneath. Plays once and navigates on completion (no repeating loop), so
/// `tester.pumpAndSettle()` flows straight through it.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) _go();
    });

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
  );
  // Slides the iridescence horizontally across the wordmark — the "sweep".
  late final Animation<double> _sweep = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.85, curve: Curves.easeInOut),
  );
  // Spectrum bar draws out from centre once the wordmark has landed.
  late final Animation<double> _bar = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.45, 0.92, curve: Curves.easeOutCubic),
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
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: c.bg,
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: _fade.value,
                child: ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) {
                    // A gradient three times the wordmark width, slid
                    // left→right so the prism colours sweep across as it fades
                    // in. Symmetric stops (pink→cyan→pink) keep the edges from
                    // popping as the band enters/leaves.
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
                    style: (t.displayMedium ?? const TextStyle())
                        .copyWith(color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                height: 3,
                width: 140 * _bar.value,
                decoration: const BoxDecoration(
                  gradient: PrismGradient.linear,
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
