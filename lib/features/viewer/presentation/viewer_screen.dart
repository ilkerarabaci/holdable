import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';
import '../data/gpu_support.dart';
import '../data/native_stats.dart';
import 'scene_view.dart';

/// Interactive 3D viewer. Renders the model natively with Thermion (Google
/// Filament) — see ADR-002; the prior flutter_scene line (ADR-001) was frozen
/// over an Impeller GPU-memory floor. The render surface, orbit controls,
/// render modes, preset cameras and thumbnail capture live in [ModelSceneView];
/// this screen owns the surrounding chrome (toolbar, panels, prev/next nav).
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({super.key, required this.model});

  final LibraryModel model;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

enum _Tab { view, render, info }

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  final ModelSceneController _scene = ModelSceneController();
  late LibraryModel _model;
  _Tab _tab = _Tab.view;
  ModelSceneStatus _status = const ModelSceneStatus(loading: true);

  /// null = still checking, false = device GPU can't run the native viewer.
  bool? _gpuSupported;

  /// Live PSS breakdown (KB) shown in the Info panel on non-release builds, so
  /// memory can be read on-device without `adb dumpsys meminfo`.
  Map<String, int>? _mem;
  Timer? _pssTimer;

  @override
  void initState() {
    super.initState();
    _model = widget.model;
    GpuSupport.isSupported().then((ok) {
      if (mounted) setState(() => _gpuSupported = ok);
    });
    if (!kReleaseMode) {
      _pssTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        final v = await NativeStats.memStats();
        if (mounted && v != null) setState(() => _mem = v);
      });
    }
  }

  @override
  void dispose() {
    _pssTimer?.cancel();
    super.dispose();
  }

  void _onStatus(ModelSceneStatus status) {
    if (mounted) setState(() => _status = status);
  }

  /// Persists the PNG thumbnail captured by the scene view.
  Future<void> _saveThumbnail(Uint8List bytes) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final thumbsDir = Directory('${docs.path}/thumbs');
      if (!thumbsDir.existsSync()) thumbsDir.createSync(recursive: true);
      final path = '${thumbsDir.path}/${_model.id}.png';
      await File(path).writeAsBytes(bytes);
      await ref
          .read(libraryControllerProvider.notifier)
          .setThumbnail(_model.id, path);
    } catch (_) {/* best-effort */}
  }

  /// Loads a different model into the existing scene (prev/next nav).
  void _goTo(LibraryModel m) {
    setState(() {
      _model = m;
      _status = const ModelSceneStatus(loading: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final models = ref.watch(libraryControllerProvider);
    final index = models.indexWhere((m) => m.id == _model.id);
    final prev = index > 0 ? models[index - 1] : null;
    final next = (index >= 0 && index < models.length - 1)
        ? models[index + 1]
        : null;

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        foregroundColor: c.textPrimary,
        title: Text(_model.name),
        actions: [
          IconButton(
            tooltip: 'Previous',
            icon: const Icon(LucideIcons.chevronLeft),
            onPressed: prev == null ? null : () => _goTo(prev),
          ),
          IconButton(
            tooltip: 'Next',
            icon: const Icon(LucideIcons.chevronRight),
            onPressed: next == null ? null : () => _goTo(next),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _gpuSupported == null
          ? const Center(child: CircularProgressIndicator())
          : _gpuSupported == false
              ? const _UnsupportedGpu()
              : Stack(
        children: [
          Positioned.fill(
            child: ModelSceneView(
              controller: _scene,
              filePath: _model.filePath,
              format: _model.format.name,
              background: c.bg,
              onStatus: _onStatus,
              onThumbnail: _saveThumbnail,
            ),
          ),
          if (_status.loading && _status.error == null)
            const Center(child: CircularProgressIndicator()),
          if (_status.error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text("Couldn't render this model.",
                    style: TextStyle(color: c.textMuted),
                    textAlign: TextAlign.center),
              ),
            ),
          if (_tab == _Tab.view)
            Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _PresetPanel(onView: _scene.setView)),
          if (_tab == _Tab.render)
            Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _RenderPanel(onMode: _scene.setRenderMode)),
          if (_tab == _Tab.info)
            Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _InfoPanel(
                  model: _model,
                  tris: _status.tris,
                  verts: _status.verts,
                  ms: _status.parseMs,
                  mem: _mem,
                )),
        ],
      ),
      bottomNavigationBar: _Toolbar(
        current: _tab,
        onSelect: (t) => setState(() => _tab = t),
      ),
    );
  }
}

/// Shown when the device's GPU can't run the native renderer (no Vulkan on
/// Android; flutter_scene crashes on the GLES backend).
class _UnsupportedGpu extends StatelessWidget {
  const _UnsupportedGpu();

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.triangleAlert, size: 40, color: c.textMuted),
            const SizedBox(height: 16),
            Text(
              "This device's GPU isn't supported yet.",
              style: TextStyle(color: c.textPrimary, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'The 3D viewer needs a Vulkan-capable GPU.',
              style: TextStyle(color: c.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.current, required this.onSelect});
  final _Tab current;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Container(
      color: c.surface,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ToolButton(icon: LucideIcons.move3d, label: 'View',
                active: current == _Tab.view, onTap: () => onSelect(_Tab.view)),
            _ToolButton(icon: LucideIcons.palette, label: 'Render',
                active: current == _Tab.render, onTap: () => onSelect(_Tab.render)),
            _ToolButton(icon: LucideIcons.info, label: 'Info',
                active: current == _Tab.info, onTap: () => onSelect(_Tab.info)),
            const _ToolButton(icon: LucideIcons.scan, label: 'AR',
                disabled: true, badge: 'SOON'),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    this.active = false,
    this.disabled = false,
    this.badge,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final bool disabled;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final color = disabled
        ? c.textMuted
        : (active ? PrismGradient.violet : c.textPrimary);
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(badge ?? label,
                style: TextStyle(
                  fontSize: badge != null ? 9 : 11,
                  color: color,
                  fontFamily: badge != null ? 'monospace' : null,
                )),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Container(
      color: c.surface.withValues(alpha: 0.92),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: 'monospace', fontSize: 11, letterSpacing: 1,
                    color: c.textMuted)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textPrimary,
        side: BorderSide(color: c.borderHairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: Text(label),
    );
  }
}

class _PresetPanel extends StatelessWidget {
  const _PresetPanel({required this.onView});
  final ValueChanged<String> onView;
  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'VIEW',
      child: Wrap(spacing: 10, children: [
        _Chip(label: 'Front', onTap: () => onView('front')),
        _Chip(label: 'Top', onTap: () => onView('top')),
        _Chip(label: 'Side', onTap: () => onView('side')),
        _Chip(label: 'Iso', onTap: () => onView('iso')),
      ]),
    );
  }
}

class _RenderPanel extends StatelessWidget {
  const _RenderPanel({required this.onMode});
  final ValueChanged<String> onMode;
  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'RENDER',
      child: Wrap(spacing: 10, children: [
        _Chip(label: 'Solid', onTap: () => onMode('solid')),
        _Chip(label: 'Wireframe', onTap: () => onMode('wireframe')),
        _Chip(label: 'X-ray', onTap: () => onMode('xray')),
      ]),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.model,
    this.tris,
    this.verts,
    this.ms,
    this.mem,
  });
  final LibraryModel model;
  final int? tris;
  final int? verts;
  final int? ms;
  final Map<String, int>? mem;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    String n(int? v) => v == null ? '—' : v.toString();
    String mb(String k) {
      final kb = mem?[k];
      return kb == null ? '—' : '${(kb / 1024).round()} MB';
    }

    final rows = <List<String>>[
      ['FORMAT', model.format.label],
      ['VERTICES', n(verts)],
      ['TRIANGLES', n(tris)],
      ['PARSE', ms == null ? '—' : '${ms}ms'],
      if (mem != null) ...[
        ['MEMORY (PSS)', mb('total')],
        ['• GRAPHICS', mb('graphics')],
        ['• NATIVE', mb('native')],
        ['• DART', mb('java')],
        ['• CODE', mb('code')],
      ],
    ];
    return _Panel(
      label: 'INFO',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(r[0],
                      style: TextStyle(
                          fontFamily: 'monospace', fontSize: 11,
                          letterSpacing: 1, color: c.textMuted)),
                  Text(r[1],
                      style: TextStyle(
                          fontFamily: 'monospace', fontSize: 13,
                          color: c.textPrimary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
