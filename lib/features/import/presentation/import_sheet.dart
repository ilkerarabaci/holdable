import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/theme/prism_colors.dart';

/// Bottom sheet for adding a model (design-handoff §import-sheet).
/// D3: presents Files / URL / Sample rows. "Files" is wired to the picker in
/// D4; URL + Sample stay stubbed for alpha (closed with a "soon" snackbar).
class ImportSheet extends ConsumerWidget {
  const ImportSheet({super.key, this.onPickFiles});

  /// Injected in D4 (file_picker flow). Null = stubbed.
  final Future<void> Function()? onPickFiles;

  static Future<void> show(BuildContext context,
      {Future<void> Function()? onPickFiles}) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ImportSheet(onPickFiles: onPickFiles),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;

    void soon(String what) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$what — coming soon')),
      );
    }

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: c.borderHairline),
        ),
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: c.textMuted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Add a model',
                    style: t.titleLarge),
              ),
            ),
            const SizedBox(height: 8),
            _Row(
              icon: LucideIcons.folderOpen,
              title: 'Files',
              subtitle: 'Pick a .obj or .stl from your device',
              onTap: () async {
                if (onPickFiles != null) {
                  Navigator.of(context).pop();
                  await onPickFiles!();
                } else {
                  soon('File import');
                }
              },
            ),
            _Row(
              icon: LucideIcons.link,
              title: 'From URL',
              subtitle: 'Paste a direct link to a model',
              onTap: () => soon('URL import'),
            ),
            _Row(
              icon: LucideIcons.sparkles,
              title: 'Sample models',
              subtitle: 'Try Holdable with a curated set',
              onTap: () => soon('Sample models'),
            ),
            const SizedBox(height: 4),
          ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;
    return ListTile(
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: Icon(icon, color: c.textPrimary),
      title: Text(title, style: t.bodyLarge),
      subtitle: Text(subtitle, style: t.bodyMedium?.copyWith(color: c.textMuted)),
    );
  }
}
