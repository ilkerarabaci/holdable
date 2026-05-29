import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../data/onboarding_controller.dart';

/// D1 minimal onboarding. Expanded to the 3-screen flow (page dots, per-screen
/// copy, 'more formats soon' badge) in D2. For now it presents the welcome
/// pane and a single Continue that marks onboarding shown and enters the
/// library.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('HOLDABLE',
                  style: t.labelSmall?.copyWith(color: c.textMuted)),
              const SizedBox(height: 16),
              GradientText(
                'Hold the work,\nnot the format.',
                style: t.displayLarge,
              ),
              const SizedBox(height: 12),
              Text(
                'Your 3D, in your pocket. And in your hand.',
                style: t.bodyLarge?.copyWith(color: c.textMuted),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    await ref.read(onboardingShownProvider.notifier).markShown();
                    if (context.mounted) context.go(Routes.library);
                  },
                  child: const Text('Enter studio'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
