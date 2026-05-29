import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../app/theme_controller.dart';

/// D1 library shell: header (brand + theme toggle + profile), empty state.
/// Grid/list, liquid-glass cards and the import sheet arrive in D3.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    final mode = ref.watch(themeControllerProvider);
    final isDark = mode == ThemeMode.dark;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(isDark: isDark),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.box, size: 40, color: c.textMuted),
                      const SizedBox(height: 16),
                      Text(
                        'Your shelf is empty.',
                        style: t.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Drop a .obj or .stl to begin.',
                        style: t.bodyMedium?.copyWith(color: c.textMuted),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // D3: open import bottom sheet (Files / URL / Sample).
          showModalBottomSheet<void>(
            context: context,
            builder: (_) => const SizedBox(
              height: 160,
              child: Center(child: Text('Import sheet — coming in D3')),
            ),
          );
        },
        child: const Icon(LucideIcons.plus),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Text('Library', style: t.displayMedium),
          const Spacer(),
          IconButton(
            tooltip: isDark ? 'Light mode' : 'Dark mode',
            icon: Icon(isDark ? LucideIcons.sun : LucideIcons.moon,
                color: c.textMuted),
            onPressed: () => ref.read(themeControllerProvider.notifier).toggle(),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: Icon(LucideIcons.user, color: c.textMuted),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
    );
  }
}
