import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';
import '../../ar/data/ar_export.dart';
import '../../ar/presentation/ar_view_screen.dart';
import '../data/gpu_support.dart';
import '../data/native_stats.dart';
import '../data/thumbnail_service.dart' show kThumbnailVersionSuffix;
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

enum _Tab { none, view, render, info }

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  final ModelSceneController _scene = ModelSceneController();
  late LibraryModel _model;
  // Open clean (model unobstructed); panels are dismissible overlays toggled
  // from the toolbar, closed by back / tapping the scene.
  _Tab _tab = _Tab.none;
  ModelSceneStatus _status = const ModelSceneStatus(loading: true);

  /// null = still checking, false = device GPU can't run the native viewer.
  bool? _gpuSupported;

  /// Live PSS breakdown (KB) shown in the Info panel on non-release builds, so
  /// memory can be read on-device without `adb dumpsys meminfo`.
  Map<String, int>? _mem;
  Timer? _pssTimer;

  /// App version + build (e.g. "0.3.0+3"), shown in the Info panel so the build
  /// under test is identifiable on-device.
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    _model = widget.model;
    GpuSupport.isSupported().then((ok) {
      if (mounted) setState(() => _gpuSupported = ok);
    });
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _appVersion = '${info.version}+${info.buildNumber}');
      }
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
      // Version-stamped name so the library can tell fresh CPU thumbnails from
      // stale ones left by older (Thermion GPU-capture) builds.
      final path = '${thumbsDir.path}/${_model.id}$kThumbnailVersionSuffix';
      await File(path).writeAsBytes(bytes);
      await ref
          .read(libraryControllerProvider.notifier)
          .setThumbnail(_model.id, path);
    } catch (_) {/* best-effort */}
  }

  /// Exports the current model to a temp GLB and opens the AR placement screen.
  Future<void> _openAr() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Preparing AR…')));
    final name = await exportModelToGlb(
      filePath: _model.filePath,
      format: _model.format.fileExtension,
    );
    if (!mounted) return;
    if (name == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't prepare this model for AR.")),
      );
      return;
    }
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => ArViewScreen(glbAbsolutePath: name, title: _model.name),
    ));
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

    return PopScope(
      // Back closes an open panel first; only pops the viewer when none is open.
      canPop: _tab == _Tab.none,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = _Tab.none);
      },
      child: Scaffold(
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
              format: _model.format.fileExtension,
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
          // Tap the scene (anywhere but the panel) to dismiss an open panel.
          // Translucent + tap-only so orbit/pan drags still reach the scene.
          if (_tab != _Tab.none)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _tab = _Tab.none),
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
                child: _RenderPanel(
                  onMode: _scene.setRenderMode,
                  onColor: _scene.setColor,
                  onLightIntensity: _scene.setLightIntensity,
                  onLightAngle: _scene.setLightAngle,
                )),
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
                  appVersion: _appVersion,
                )),
        ],
      ),
      bottomNavigationBar: _Toolbar(
        current: _tab,
        // Re-tapping the active tab closes its panel.
        onSelect: (t) => setState(() => _tab = _tab == t ? _Tab.none : t),
        onAr: _openAr,
      ),
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
  const _Toolbar({required this.current, required this.onSelect, this.onAr});
  final _Tab current;
  final ValueChanged<_Tab> onSelect;
  final VoidCallback? onAr;

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
            _ToolButton(icon: LucideIcons.scan, label: 'AR', onTap: onAr),
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
    this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final color = active ? PrismGradient.violet : c.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
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

class _RenderPanel extends StatefulWidget {
  const _RenderPanel({
    required this.onMode,
    required this.onColor,
    required this.onLightIntensity,
    required this.onLightAngle,
  });
  final ValueChanged<String> onMode;
  final ValueChanged<Color> onColor;
  final ValueChanged<double> onLightIntensity;
  final ValueChanged<double> onLightAngle;

  @override
  State<_RenderPanel> createState() => _RenderPanelState();
}

class _RenderPanelState extends State<_RenderPanel> {
  // Neutral default plus the three Prism accents (quick picks).
  static const Color _neutral = Color(0xFFD1D1DB);
  static const _quick = [
    _neutral,
    PrismGradient.pink,
    PrismGradient.violet,
    PrismGradient.cyan,
  ];

  Color _current = _neutral;
  double _intensity = 1.0; // light-rig multiplier (matches scene default)
  double _angle = 0.0; // rig azimuth, radians

  void _pick(Color c) {
    setState(() => _current = c);
    widget.onColor(c);
  }

  /// Opens a full HSV colour picker so any colour (not just the presets) can be
  /// applied. Updates live as the user drags.
  Future<void> _openFullPicker() async {
    final p = context.prism;
    Color temp = _current;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ColorPicker(
                pickerColor: temp,
                onColorChanged: (c) {
                  temp = c;
                  widget.onColor(c); // live preview on the model
                },
                enableAlpha: false,
                hexInputBar: true,
                labelTypes: const [],
                pickerAreaHeightPercent: 0.7,
                portraitOnly: true,
                displayThumbColor: true,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    setState(() => _current = temp);
                    Navigator.of(sheetCtx).pop();
                  },
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Ensure the model ends on the confirmed colour.
    widget.onColor(_current);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return _Panel(
      label: 'RENDER',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 10, children: [
            _Chip(label: 'Solid', onTap: () => widget.onMode('solid')),
            _Chip(label: 'Wireframe', onTap: () => widget.onMode('wireframe')),
            _Chip(label: 'X-ray', onTap: () => widget.onMode('xray')),
          ]),
          const SizedBox(height: 14),
          Text('COLOR',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  letterSpacing: 1,
                  color: c.textMuted)),
          const SizedBox(height: 10),
          Row(children: [
            for (final color in _quick)
              _Swatch(
                color: color,
                selected: color.toARGB32() == _current.toARGB32(),
                onTap: () => _pick(color),
              ),
            // Full-spectrum picker launcher (rainbow ring + palette glyph).
            _CustomSwatch(
              selected: !_quick
                  .any((q) => q.toARGB32() == _current.toARGB32()),
              current: _current,
              onTap: _openFullPicker,
            ),
          ]),
          const SizedBox(height: 14),
          Text('LIGHT',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  letterSpacing: 1,
                  color: c.textMuted)),
          _LightSlider(
            icon: LucideIcons.sun,
            value: _intensity,
            min: 0.2,
            max: 2.5,
            // Re-creates the rig — apply on release to avoid flicker mid-drag.
            onChanged: (v) => setState(() => _intensity = v),
            onChangeEnd: widget.onLightIntensity,
          ),
          _LightSlider(
            icon: LucideIcons.compass,
            value: _angle,
            min: 0.0,
            max: 6.2831853, // 2π
            // Cheap (direction only) — drive live.
            onChanged: (v) {
              setState(() => _angle = v);
              widget.onLightAngle(v);
            },
          ),
        ],
      ),
    );
  }
}

/// A compact icon + slider row for a light control.
class _LightSlider extends StatelessWidget {
  const _LightSlider({
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
  });
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Row(children: [
      Icon(icon, size: 18, color: c.textMuted),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
    ]);
  }
}

/// A rainbow-ringed swatch that opens the full HSV picker.
class _CustomSwatch extends StatelessWidget {
  const _CustomSwatch(
      {required this.selected, required this.current, required this.onTap});
  final bool selected;
  final Color current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ]),
          border: Border.all(
            color: selected ? c.textPrimary : c.borderHairline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Icon(Icons.add, size: 16, color: Colors.white.withValues(alpha: 0.9)),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(
      {required this.color, required this.onTap, this.selected = false});
  final Color color;
  final VoidCallback onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? c.textPrimary : c.borderHairline,
              width: selected ? 2 : 1,
            ),
          ),
        ),
      ),
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
    this.appVersion,
  });
  final LibraryModel model;
  final int? tris;
  final int? verts;
  final int? ms;
  final Map<String, int>? mem;
  final String? appVersion;

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
      ['APP', appVersion ?? '—'],
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
