import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../../shared/utils/format.dart';
import '../../../shared/widgets/prism_card.dart';
import '../domain/library_model.dart';

/// A library grid tile: liquid-glass card with a thumbnail area and the
/// model's name + mono metadata. Thumbnail is a placeholder until D4 wires
/// real generation.
class ModelCard extends StatelessWidget {
  const ModelCard({
    super.key,
    required this.model,
    this.onTap,
    this.onLongPress,
    this.blur = true,
  });

  final LibraryModel model;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final t = Theme.of(context).textTheme;

    return PrismCard(
      onTap: onTap,
      onLongPress: onLongPress,
      blur: blur,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Center(
              child: _ThumbPlaceholder(thumbnailPath: model.thumbnailPath),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            model.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.bodyLarge?.copyWith(color: c.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            '${model.format.label} · ${bytesToHuman(model.sizeBytes)}',
            style: t.labelSmall?.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder({this.thumbnailPath});

  final String? thumbnailPath;

  @override
  Widget build(BuildContext context) {
    final path = thumbnailPath;
    if (path != null && File(path).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        ),
      );
    }
    // Placeholder gradient mark until a thumbnail is generated (on first view).
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (b) => PrismGradient.diagonal.createShader(
        Rect.fromLTWH(0, 0, b.width, b.height),
      ),
      child: const Icon(LucideIcons.box, size: 44),
    );
  }
}
