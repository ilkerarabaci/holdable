import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme/prism_theme.dart';
import 'theme_controller.dart';

class HoldableApp extends ConsumerWidget {
  const HoldableApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeControllerProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Holdable',
      debugShowCheckedModeBanner: false,
      theme: PrismTheme.light,
      darkTheme: PrismTheme.dark,
      themeMode: mode,
      // 350ms cross-fade between token values on theme switch
      // (docs/design-handoff.md §Interactions).
      themeAnimationDuration: const Duration(milliseconds: 350),
      themeAnimationCurve: Curves.easeInOut,
      routerConfig: router,
    );
  }
}
