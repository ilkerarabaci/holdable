import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../data/onboarding_controller.dart';

/// 3-screen onboarding shown on first launch only (sprint-1-goal §D2).
/// Panes mirror the Prism prototype (ob1/ob2/ob3) with the alpha adjustment:
/// ob2 advertises .obj + .stl + a muted "more soon" badge instead of .blend.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _panes = <_Pane>[
    _Pane(
      kicker: 'HOLDABLE',
      title: 'Hold the work,\nnot the format.',
      body: 'Your 3D, in your pocket. And in your hand.',
    ),
    _Pane(
      kicker: 'IMPORT',
      title: 'Drop one in.',
      body: 'Bring a model straight from Files or another app.',
      formats: ['.OBJ', '.STL'],
    ),
    _Pane(
      kicker: 'VIEW',
      title: 'Spin it,\nsqueeze it.',
      body: 'Drag to rotate, pinch to zoom. Your model, in your hand.',
    ),
  ];

  bool get _isLast => _page == _panes.length - 1;

  Future<void> _next() async {
    if (_isLast) {
      await ref.read(onboardingShownProvider.notifier).markShown();
      if (mounted) context.go(Routes.library);
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOut,
    );
  }

  /// Steps back one pane. No-op on the first pane.
  void _back() {
    if (_page == 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return PopScope(
      // On panes after the first, a back gesture rewinds one pane instead of
      // leaving onboarding.
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _panes.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _PaneView(pane: _panes[i]),
              ),
            ),
            _Dots(count: _panes.length, active: _page),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(_isLast ? 'Enter studio' : 'Continue'),
                ),
              ),
            ),
          ],
        ),
      ),
      // Skip jumps to the library and marks onboarding done.
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        // Back arrow appears after the first pane to step back through panes.
        automaticallyImplyLeading: false,
        leading: _page == 0
            ? null
            : IconButton(
                icon: Icon(Icons.arrow_back, color: c.textMuted),
                onPressed: _back,
              ),
        actions: [
          if (!_isLast)
            TextButton(
              onPressed: () async {
                await ref.read(onboardingShownProvider.notifier).markShown();
                if (context.mounted) context.go(Routes.library);
              },
              child: Text('Skip', style: TextStyle(color: c.textMuted)),
            ),
        ],
      ),
      extendBodyBehindAppBar: true,
      ),
    );
  }
}

class _Pane {
  const _Pane({
    required this.kicker,
    required this.title,
    required this.body,
    this.formats,
  });

  final String kicker;
  final String title;
  final String body;
  final List<String>? formats;
}

class _PaneView extends StatelessWidget {
  const _PaneView({required this.pane});

  final _Pane pane;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Text(pane.kicker, style: t.labelSmall?.copyWith(color: c.textMuted)),
          const SizedBox(height: 16),
          GradientText(pane.title, style: t.displayLarge),
          const SizedBox(height: 12),
          Text(pane.body, style: t.bodyLarge?.copyWith(color: c.textMuted)),
          if (pane.formats != null) ...[
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...pane.formats!.map((f) => _FormatChip(label: f)),
                Text('· more formats soon',
                    style: t.labelSmall?.copyWith(color: c.textMuted)),
              ],
            ),
          ],
          const Spacer(flex: 2),
        ],
      ),
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.borderHairline),
      ),
      child: Text(label,
          style: t.labelSmall?.copyWith(color: c.textPrimary)),
    );
  }
}

/// Page indicator. Active dot wears the brand gradient; the rest are hairline.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isActive = i == active;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 6,
          width: isActive ? 22 : 6,
          decoration: BoxDecoration(
            gradient: isActive ? PrismGradient.linear : null,
            color: isActive ? null : c.textMuted.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}
