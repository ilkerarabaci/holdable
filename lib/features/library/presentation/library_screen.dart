import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/router.dart';
import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../../app/theme_controller.dart';
import '../../../shared/utils/format.dart';
import '../../import/data/import_service.dart';
import '../../import/data/sample_models.dart';
import '../../import/domain/material_support.dart';
import '../../import/presentation/import_sheet.dart';
import '../data/library_controller.dart';
import '../domain/library_model.dart';
import 'model_card.dart';

/// Lets the user pick a bundled sample model, then imports it.
Future<void> _pickSample(BuildContext context, WidgetRef ref) async {
  final selected = await showModalBottomSheet<SampleModel>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    // Scroll-controlled + a scrollable list so every sample is reachable — the
    // fixed-height Column cut off the last entries (Torus/Sphere) off-screen.
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Sample models'),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final s in kSampleModels)
                  ListTile(
                    leading: const Icon(LucideIcons.box),
                    title: Text(s.name),
                    // Surface the format so the new ones (GLB/glTF/PLY) read.
                    subtitle: Text('.${s.asset.split('.').last.toUpperCase()}'),
                    onTap: () => Navigator.pop(context, s),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  final result = await ref.read(importServiceProvider).importAsset(
        selected.asset,
        selected.name,
        confirmDuplicate: (name) => _confirmDuplicate(context, name),
      );
  if (!context.mounted) return;
  if (result.status == ImportStatus.added) {
    _showMaterialBalloon(context, result.model!);
  } else if (result.status == ImportStatus.duplicate) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message ?? 'Already in your library')),
    );
  }
}

/// Runs the file-picker import and shows feedback. Shared by the FAB and the
/// import sheet's "Files" row.
Future<void> _runImport(BuildContext context, WidgetRef ref) async {
  final result = await ref.read(importServiceProvider).pickAndImport(
        confirmOversize: (size) => _confirmOversize(context, size),
        confirmDuplicate: (name) => _confirmDuplicate(context, name),
      );
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  switch (result.status) {
    case ImportStatus.added:
      // PO #7: the success toast doubles as the per-format material note.
      _showMaterialBalloon(context, result.model!);
    case ImportStatus.cancelled:
      break;
    case ImportStatus.duplicate:
      messenger.showSnackBar(
        SnackBar(content: Text(result.message ?? 'Already in your library')),
      );
    case ImportStatus.unsupported:
    case ImportStatus.error:
      messenger.showSnackBar(
        SnackBar(content: Text(result.message ?? 'Import failed')),
      );
  }
}

/// Prism-voice confirmation for a file past the soft size cap
/// ([kMaxImportBytes]). Returns true if the user chooses to load it anyway.
Future<bool> _confirmOversize(BuildContext context, int sizeBytes) async {
  final c = context.prism;
  final t = Theme.of(context).textTheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.borderHairline),
      ),
      title: Text('Heavy model', style: t.titleMedium),
      content: Text(
        '${bytesToHuman(sizeBytes)} is past the comfortable range. '
        'It may load slowly and run hot.',
        style: t.bodyMedium?.copyWith(color: c.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: TextStyle(color: c.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('Load anyway', style: TextStyle(color: c.textPrimary)),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Prism-voice confirmation when the picked file is already in the library
/// (PO #3) — re-importing was refused outright before. Returns true to add a
/// second copy anyway.
Future<bool> _confirmDuplicate(BuildContext context, String name) async {
  final c = context.prism;
  final t = Theme.of(context).textTheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.borderHairline),
      ),
      title: Text('Already in your library', style: t.titleMedium),
      content: Text(
        '"$name" is already on your shelf. Import another copy?',
        style: t.bodyMedium?.copyWith(color: c.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: TextStyle(color: c.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('Import again', style: TextStyle(color: c.textPrimary)),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// PO #7 — after an import, tell the user how much of the model's appearance
/// (materials/textures) loads for its format, tinted by support level. Doubles
/// as the "added" confirmation. Default placement: a floating balloon right
/// after import (the A/B alternative is an always-on legend in the import sheet).
void _showMaterialBalloon(BuildContext context, LibraryModel model) {
  final c = context.prism;
  final t = Theme.of(context).textTheme;
  final support = materialSupportFor(model.format);
  final (IconData icon, Color tint) = switch (support) {
    MaterialSupport.full => (Icons.check_circle_outline, PrismGradient.cyan),
    MaterialSupport.conditional => (Icons.info_outline, PrismGradient.violet),
    MaterialSupport.partial => (Icons.info_outline, PrismGradient.violet),
    MaterialSupport.none => (Icons.layers_outlined, c.textMuted),
  };
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        backgroundColor: c.surface,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.borderHairline),
        ),
        content: Row(
          children: [
            Icon(icon, color: tint, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Added "${model.name}"',
                      style: t.bodyMedium?.copyWith(color: c.textPrimary)),
                  const SizedBox(height: 2),
                  Text('${model.format.label} · ${support.title}',
                      style: t.labelSmall?.copyWith(color: c.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
          onPickSamples: () => _pickSample(context, ref),
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
            Text(
                'Drop an .obj, .stl, .glb, .gltf, .ply,\n'
                '.3mf, .off, .dae, .3ds or .fbx to begin.',
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
              onTap: () async {
                Navigator.pop(context);
                await _shareModel(context, model);
              },
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

  /// Shares the model's file out to other apps via the system share sheet.
  /// Uses a friendly `<name>.<ext>` filename even though the file on disk is
  /// stored as `<id>.<ext>`.
  Future<void> _shareModel(BuildContext context, LibraryModel model) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!File(model.filePath).existsSync()) {
      messenger.showSnackBar(
        const SnackBar(content: Text("That model's file is missing.")),
      );
      return;
    }
    final fileName = '${model.name}.${model.format.fileExtension}';
    // iPad needs the originating rect for the share popover. This is called from
    // a GridView item context whose render object is a RenderSliver (NOT a
    // RenderBox), so an `as RenderBox?` cast THROWS — and since this ran before
    // shareXFiles, the share silently died and the sheet never opened (the
    // alpha.11/12 bug). Use a safe `is` check, falling back to the screen rect.
    Rect? origin;
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      origin = ro.localToGlobal(Offset.zero) & ro.size;
    } else {
      final size = MediaQuery.maybeOf(context)?.size;
      if (size != null) {
        origin = Rect.fromCenter(
            center: size.center(Offset.zero), width: 1, height: 1);
      }
    }
    try {
      await Share.shareXFiles(
        [
          // Explicit MIME — .obj/.stl have no registered type, so without this
          // some receivers get an empty type and reject the file.
          XFile(model.filePath,
              name: fileName, mimeType: 'application/octet-stream'),
        ],
        subject: model.name,
        fileNameOverrides: [fileName],
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't share: $e")),
      );
    }
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
