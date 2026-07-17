import 'dart:async';
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
import '../../import/data/conversion_service.dart';
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
  // Drives the converting banner's live progress (upload % → cloud phases).
  // Only conversions emit progress, so the banner is raised lazily on the
  // first event — a plain native-format import shows no banner.
  final progress = ValueNotifier<ImportProgress?>(null);
  final cancel = CancelToken();
  final result = await ref.read(importServiceProvider).pickAndImport(
        confirmOversize: (size) => _confirmOversize(context, size),
        confirmDuplicate: (name) => _confirmDuplicate(context, name),
        cancel: cancel,
        onProgress: (p) {
          if (progress.value == null && context.mounted) {
            _showConvertingBanner(context, progress, onCancel: cancel.cancel);
          }
          progress.value = p;
        },
      );
  if (!context.mounted) return;
  // Clear the progress banner before showing the final result.
  final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
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

/// Persistent banner while a large file converts in the cloud (async Job path).
/// Shows live progress driven by [progress]: a determinate bar with % during
/// the upload (the bulk of the wait), then indeterminate for the cloud
/// convert/download phases. Cleared when the import resolves (see _runImport).
void _showConvertingBanner(
    BuildContext context, ValueNotifier<ImportProgress?> progress,
    {VoidCallback? onCancel}) {
  final c = context.prism;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        backgroundColor: c.surface,
        behavior: SnackBarBehavior.floating,
        // Match the job poll window (awaitJob, 30 min) so the banner doesn't
        // vanish mid-conversion on a slow, export-bound model.
        duration: const Duration(minutes: 30),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.borderHairline),
        ),
        content:
            _ConvertingBannerContent(progress: progress, onCancel: onCancel),
      ),
    );
}

/// Banner body. Stateful so it can tick an elapsed clock once per second during
/// the cloud convert/download phases: those report no sub-progress, so without
/// a clock the banner sits on a static "Converting…" for minutes on a dense,
/// export-bound model — which reads as frozen. The upload phase still shows the
/// live %; the clock makes the long cloud phase visibly alive.
class _ConvertingBannerContent extends StatefulWidget {
  const _ConvertingBannerContent({required this.progress, this.onCancel});
  final ValueNotifier<ImportProgress?> progress;
  final VoidCallback? onCancel;

  @override
  State<_ConvertingBannerContent> createState() =>
      _ConvertingBannerContentState();
}

class _ConvertingBannerContentState extends State<_ConvertingBannerContent> {
  final Stopwatch _elapsed = Stopwatch()..start();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onChange);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onChange);
    _ticker?.cancel();
    _elapsed.stop();
    super.dispose();
  }

  String get _clock {
    final s = _elapsed.elapsed.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    final p = widget.progress.value;
    final phase = p?.phase ?? ImportPhase.uploading;
    // Compress (#8, client-side gzip) + upload both have a real 0..1 fraction.
    final onDevice =
        phase == ImportPhase.uploading || phase == ImportPhase.compressing;
    final pct = (onDevice && p?.fraction != null)
        ? (p!.fraction! * 100).round()
        : null;
    final inCloud = !onDevice;
    final label = switch (phase) {
      ImportPhase.compressing =>
        pct != null ? 'Compressing $pct%' : 'Compressing…',
      ImportPhase.uploading => pct != null ? 'Uploading $pct%' : 'Uploading…',
      ImportPhase.converting => 'Converting in the cloud… · $_clock',
      ImportPhase.downloading => 'Downloading…',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$label — you can keep using Holdable.',
                style: t.bodyMedium?.copyWith(color: c.textPrimary),
              ),
            ),
            if (widget.onCancel != null)
              TextButton(
                onPressed: widget.onCancel,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Cancel',
                  style: t.labelLarge?.copyWith(color: PrismGradient.violet),
                ),
              ),
          ],
        ),
        // After a minute on the cloud phase, set expectations: dense models are
        // export-bound and can genuinely take a few minutes.
        if (inCloud && _elapsed.elapsed.inSeconds >= 60) ...[
          const SizedBox(height: 2),
          Text(
            'Detailed models can take a few minutes.',
            style: t.labelSmall?.copyWith(color: c.textMuted),
          ),
        ],
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            // Determinate while compressing/uploading; indeterminate once the
            // file is in the cloud (the Job's internal % isn't observable).
            value: onDevice ? p?.fraction : null,
            minHeight: 4,
            backgroundColor: c.borderHairline,
            valueColor:
                const AlwaysStoppedAnimation<Color>(PrismGradient.violet),
          ),
        ),
      ],
    );
  }
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
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    // #4: if a large conversion was still running when the app last closed, its
    // Cloud Run Job kept going server-side — resume it now. Post-frame so a
    // ScaffoldMessenger is available for the progress banner.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumePending());
  }

  Future<void> _resumePending() async {
    if (!mounted) return;
    final progress = ValueNotifier<ImportProgress?>(null);
    final result =
        await ref.read(importServiceProvider).resumePendingConversion(
      onProgress: (p) {
        if (progress.value == null && mounted) {
          _showConvertingBanner(context, progress);
        }
        progress.value = p;
      },
      confirmDuplicate: (name) => _confirmDuplicate(context, name),
    );
    if (result == null || !mounted) return; // nothing was pending
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    switch (result.status) {
      case ImportStatus.added:
        _showMaterialBalloon(context, result.model!);
      case ImportStatus.duplicate:
        messenger.showSnackBar(
          SnackBar(content: Text(result.message ?? 'Already in your library')),
        );
      case ImportStatus.error:
        messenger.showSnackBar(
          SnackBar(content: Text(result.message ?? 'Import failed')),
        );
      case ImportStatus.cancelled:
      case ImportStatus.unsupported:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
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
