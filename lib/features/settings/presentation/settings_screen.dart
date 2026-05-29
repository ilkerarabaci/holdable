import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../app/theme_controller.dart';

/// Minimal settings: theme segmented control + version. Profile/storage/account
/// stay out of alpha scope (design-handoff §What to ship).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    final mode = ref.watch(themeControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('APPEARANCE',
              style: t.labelSmall?.copyWith(color: c.textMuted)),
          const SizedBox(height: 12),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
            ],
            selected: {mode == ThemeMode.light ? ThemeMode.light : ThemeMode.dark},
            onSelectionChanged: (s) =>
                ref.read(themeControllerProvider.notifier).set(s.first),
          ),
          const SizedBox(height: 28),
          Text('GETTING STARTED',
              style: t.labelSmall?.copyWith(color: c.textMuted)),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(LucideIcons.sparkles, color: c.textPrimary),
            title: const Text('Replay welcome tour'),
            subtitle: Text('See the intro screens again',
                style: t.bodyMedium?.copyWith(color: c.textMuted)),
            trailing: Icon(LucideIcons.chevronRight, color: c.textMuted),
            onTap: () => context.push(Routes.onboarding),
          ),
          const SizedBox(height: 16),
          Text('ABOUT', style: t.labelSmall?.copyWith(color: c.textMuted)),
          const SizedBox(height: 12),
          Text('Holdable — alpha', style: t.bodyLarge),
          Text('Your 3D, in your pocket. And in your hand.',
              style: t.bodyMedium?.copyWith(color: c.textMuted)),
        ],
      ),
    );
  }
}
