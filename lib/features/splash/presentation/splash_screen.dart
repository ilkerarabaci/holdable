import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../../onboarding/data/onboarding_controller.dart';

/// Brand splash shown for ~1.1s on cold start (PO #1), then hands off to the
/// onboarding gate (first run) or the library. Pairs with the Android 12 system
/// splash (res/values-v31/styles.xml): the OS paints the app icon while the
/// engine warms up, and this continues the brand moment and dissolves into the
/// app — so there's no jarring jump from system splash to a bare screen.
///
/// The animation plays once and navigates on completion (no repeating loop), so
/// `tester.pumpAndSettle()` flows straight through it. Appearance is the PO's
/// A/B choice; this is variant A — the minimal gradient wordmark.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) _go();
    });

  // Wordmark fades + settles up first; the tagline follows.
  late final Animation<double> _markFade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
  );
  late final Animation<double> _markScale = Tween<double>(begin: 0.94, end: 1.0)
      .animate(CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
  ));
  late final Animation<double> _taglineFade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.45, 0.9, curve: Curves.easeOut),
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
                opacity: _markFade.value,
                child: Transform.scale(
                  scale: _markScale.value,
                  child: GradientText('Holdable', style: t.displayMedium),
                ),
              ),
              const SizedBox(height: 10),
              Opacity(
                opacity: _taglineFade.value,
                child: Text(
                  'your 3D, in your pocket',
                  style: t.bodyMedium?.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
