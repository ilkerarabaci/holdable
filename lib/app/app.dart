import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/import/data/sharing_service.dart';
import 'router.dart';
import 'theme/prism_theme.dart';
import 'theme_controller.dart';

class HoldableApp extends ConsumerStatefulWidget {
  const HoldableApp({super.key, this.bootstrapSharing = true});

  /// Disabled in widget tests so the share-intent platform channel isn't hit.
  final bool bootstrapSharing;

  @override
  ConsumerState<HoldableApp> createState() => _HoldableAppState();
}

class _HoldableAppState extends ConsumerState<HoldableApp> {
  @override
  void initState() {
    super.initState();
    if (widget.bootstrapSharing) {
      // Best-effort: incoming shares import in the background.
      ref.read(sharingServiceProvider).start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeControllerProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Holdable',
      debugShowCheckedModeBanner: false,
      theme: PrismTheme.light,
      darkTheme: PrismTheme.dark,
      themeMode: mode,
      // Instant theme switch. MaterialApp's cross-fade renders the old and new
      // themes stacked and fades between them, which for a full dark<->light
      // flip passes through a muddy grey mid-frame that reads as a glitch.
      // (The design-handoff's "350ms cross-fade" needs a custom reveal; a clean
      // instant swap is the stable choice for alpha.)
      themeAnimationDuration: Duration.zero,
      routerConfig: router,
    );
  }
}
