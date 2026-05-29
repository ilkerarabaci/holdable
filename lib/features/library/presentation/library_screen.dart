import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../app/theme_controller.dart';
import '../../import/data/import_service.dart';
import '../../import/presentation/import_sheet.dart';
import '../data/library_controller.dart';
import '../domain/library_model.dart';
import 'model_card.dart';

/// Runs the file-picker import and shows feedback. Shared by the FAB and the
/// import sheet's "Files" row.
Future<void> _runImport(BuildContext context, WidgetRef ref) async {
  final result = await ref.read(importServiceProvider).pickAndImport();
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  switch (result.status) {
    case ImportStatus.added:
      messenger.showSnackBar(
        SnackBar(content: Text('Added "${result.model!.name}"')),
      );
    case ImportStatus.cancelled:
      break;
    case ImportStatus.unsupported:
    case ImportStatus.error:
      messenger.showSnackBar(
        SnackBar(content: Text(result.message ?? 'Import failed')),
      );
  }
}

/// Library: empty state when the wallet is empty, otherwise a grid of
/// liquid-glass model cards. FAB opens the import sheet.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(libraryControllerProvider);
    final mode = ref.watch(themeControllerProvider);
    final isDark = mode == ThemeMode.dark;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(isDark: isDark, count: models.length),
            Expanded(
              child: models.isEmpty
                  ? const _EmptyState()
                  : _ModelGrid(),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => ImportSheet.show(
          context,
          onPickFiles: () => _runImport(context, ref),
        ),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.box, size: 40, color: c.textMuted),
            const SizedBox(height: 16),
            Text('Your shelf is empty.',
                style: t.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('Drop a .obj or .stl to begin.',
                style: t.bodyMedium?.copyWith(color: c.textMuted),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ModelGrid extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(libraryControllerProvider);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.82,
      ),
      itemCount: models.length,
      itemBuilder: (context, i) {
        final m = models[i];
        return ModelCard(
          model: m,
          // Liquid-glass blur only while the set is small (perf guard).
          blur: models.length <= 6,
          onTap: () => context.push(Routes.viewer, extra: m),
          onLongPress: () => _showActions(context, ref, m),
        );
      },
    );
  }

  void _showActions(BuildContext context, WidgetRef ref, LibraryModel model) {
    final id = model.id;
    final name = model.name;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.eye),
              title: const Text('Open'),
              onTap: () {
                Navigator.pop(context);
                context.push(Routes.viewer, extra: model);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(context, ref, id, name);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.share2),
              title: const Text('Share'),
              onTap: () => Navigator.pop(context), // D5
            ),
            ListTile(
              leading: const Icon(LucideIcons.trash2),
              title: const Text('Delete'),
              onTap: () {
                ref.read(libraryControllerProvider.notifier).remove(id);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(
      BuildContext context, WidgetRef ref, String id, String current) {
    final controller = TextEditingController(text: current);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename model'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => _submitRename(ctx, ref, id, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => _submitRename(ctx, ref, id, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _submitRename(
      BuildContext ctx, WidgetRef ref, String id, String value) {
    final name = value.trim();
    if (name.isNotEmpty) {
      ref.read(libraryControllerProvider.notifier).rename(id, name);
    }
    Navigator.pop(ctx);
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.isDark, required this.count});

  final bool isDark;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Text('Library', style: t.displayMedium),
          const SizedBox(width: 10),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('$count',
                  style: t.labelSmall?.copyWith(color: c.textMuted)),
            ),
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
