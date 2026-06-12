import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/theme/prism_colors.dart';
import '../../../app/theme/prism_gradient.dart';
import '../../../app/theme_controller.dart' show sharedPreferencesProvider;
import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';
import '../../ar/data/ar_export.dart';
import '../../ar/presentation/ar_view_screen.dart';
import '../data/bundled_textures.dart';
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

  // Light controls live on the SCREEN (not the Render panel) so they survive
  // the panel being rebuilt on every tab switch, and — persisted to prefs —
  // survive re-opening the viewer. (Was: panel-local state that snapped back to
  // defaults on every rebuild — the "sliders reset on exit/re-enter" bug.)
  static const _kLightIntensityKey = 'viewer_light_intensity';
  static const _kLightAngleKey = 'viewer_light_angle';
  static const _kEnvironmentKey = 'viewer_light_environment';
  double _lightIntensity = 1.0;
  double _lightAngle = 0.0;
  double _environment = 0.0;
  bool _lightApplied = false; // persisted light pushed to the scene once ready

  void _saveLight() {
    final prefs = ref.read(sharedPreferencesProvider);
    prefs.setDouble(_kLightIntensityKey, _lightIntensity);
    prefs.setDouble(_kLightAngleKey, _lightAngle);
    prefs.setDouble(_kEnvironmentKey, _environment);
  }

  @override
  void initState() {
    super.initState();
    _model = widget.model;
    final prefs = ref.read(sharedPreferencesProvider);
    _lightIntensity = prefs.getDouble(_kLightIntensityKey) ?? 1.0;
    _lightAngle = prefs.getDouble(_kLightAngleKey) ?? 0.0;
    _environment = prefs.getDouble(_kEnvironmentKey) ?? 0.0;
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
    if (!mounted) return;
    void apply() {
      if (!mounted) return;
      setState(() => _status = status);
      // Once the scene is up, push the user's persisted light settings onto it
      // (the scene loads at its own defaults). Only non-default values need a
      // call; do it once.
      if (!status.loading && !_lightApplied) {
        _lightApplied = true;
        if (_lightIntensity != 1.0) _scene.setLightIntensity(_lightIntensity);
        if (_lightAngle != 0.0) _scene.setLightAngle(_lightAngle);
        if (_environment != 0.0) _scene.setEnvironment(_environment);
      }
    }

    // The scene reports status synchronously from its initState (i.e. during
    // this screen's build) — setState would throw "called during build" and
    // kill the model load before it starts. Defer to the end of the frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
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

  /// Diagnostic: a previous session died inside the texture pipeline; show
  /// WHICH native step so the failing call can be pinpointed from a device
  /// screenshot (crash-trace file, see scene_view). Auto-texture is skipped
  /// for this session as crash-loop protection.
  void _showTextureCrashStep(String step) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Texture diagnostic'),
          content: Text(
              'Last session crashed in the texture pipeline at step:\n\n'
              '$step\n\n'
              'Texture auto-apply is off for this session. Please screenshot this.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK')),
          ],
        ),
      );
    });
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
              onTextureCrashDetected: _showTextureCrashStep,
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
                  onShading: _scene.setShading,
                  onTexture: _scene.setTextureAsset,
                  intensity: _lightIntensity,
                  angle: _lightAngle,
                  environment: _environment,
                  onLightIntensity: (v) {
                    _lightIntensity = v;
                    _scene.setLightIntensity(v);
                    _saveLight();
                  },
                  onLightAngle: (v) {
                    _lightAngle = v;
                    _scene.setLightAngle(v);
                    _saveLight();
                  },
                  onEnvironment: (v) {
                    _environment = v;
                    _scene.setEnvironment(v);
                    _saveLight();
                  },
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
                tooltip: 'Camera angles (front/top/side/iso)',
                active: current == _Tab.view, onTap: () => onSelect(_Tab.view)),
            _ToolButton(icon: LucideIcons.palette, label: 'Render',
                tooltip: 'Mode, shading, color, texture & light',
                active: current == _Tab.render, onTap: () => onSelect(_Tab.render)),
            _ToolButton(icon: LucideIcons.info, label: 'Info',
                tooltip: 'Model stats & memory',
                active: current == _Tab.info, onTap: () => onSelect(_Tab.info)),
            _ToolButton(icon: LucideIcons.scan, label: 'AR',
                tooltip: 'Place the model in your room', onTap: onAr),
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
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  /// One-line hint shown on long-press.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final color = active ? PrismGradient.violet : c.textPrimary;
    final button = InkWell(
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
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    // Cap the panel so it never swallows the viewport: controls scroll inside a
    // bounded area, leaving the upper ~half of the screen for the model. The
    // label stays pinned above the scroll region.
    final maxContentHeight = MediaQuery.sizeOf(context).height * 0.42;
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
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxContentHeight),
              child: SingleChildScrollView(
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.tooltip});
  final String label;
  final VoidCallback onTap;

  /// One-line hint, shown on long-press (standard Flutter tooltip behavior,
  /// so a normal tap still triggers the action).
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final button = OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textPrimary,
        side: BorderSide(color: c.borderHairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: Text(label),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
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
        _Chip(
            label: 'Front',
            tooltip: 'Look straight at the front',
            onTap: () => onView('front')),
        _Chip(
            label: 'Top',
            tooltip: 'Look down from above',
            onTap: () => onView('top')),
        _Chip(
            label: 'Side',
            tooltip: 'Look from the side',
            onTap: () => onView('side')),
        _Chip(
            label: 'Iso',
            tooltip: 'Three-quarter view (default)',
            onTap: () => onView('iso')),
      ]),
    );
  }
}

class _RenderPanel extends StatefulWidget {
  const _RenderPanel({
    required this.onMode,
    required this.onColor,
    required this.onTexture,
    required this.onShading,
    required this.intensity,
    required this.angle,
    required this.environment,
    required this.onLightIntensity,
    required this.onLightAngle,
    required this.onEnvironment,
  });
  final ValueChanged<String> onMode;
  final ValueChanged<Color> onColor;

  /// Shading preference: 'auto', 'smooth' or 'flat'.
  final ValueChanged<String> onShading;

  /// Bundled texture asset path, or null for "None" (back to flat color).
  final ValueChanged<String?> onTexture;

  /// Current light values, owned by the parent screen so they survive this
  /// panel being rebuilt on every tab switch (and are persisted across
  /// sessions). The sliders seed from these instead of resetting to defaults.
  final double intensity;
  final double angle;
  final double environment;
  final ValueChanged<double> onLightIntensity;
  final ValueChanged<double> onLightAngle;
  final ValueChanged<double> onEnvironment;

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
  String? _textureSel; // selected bundled texture asset path; null = none
  // Seed from the parent-owned values so the sliders don't snap back to
  // defaults each time this panel is rebuilt (tab switch / re-open).
  late double _intensity = widget.intensity; // light-rig multiplier
  late double _angle = widget.angle; // rig azimuth, radians
  late double _environment = widget.environment; // IBL amount (0 = off)

  void _pick(Color c) {
    // Color and texture are mutually exclusive — picking a color drops the
    // texture (the scene does the same on its side).
    setState(() {
      _current = c;
      _textureSel = null;
    });
    widget.onColor(c);
  }

  void _pickTexture(String? assetPath) {
    setState(() => _textureSel = assetPath);
    widget.onTexture(assetPath);
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
            _Chip(
                label: 'Solid',
                tooltip: 'Filled surfaces (default)',
                onTap: () => widget.onMode('solid')),
            _Chip(
                label: 'Wireframe',
                tooltip: 'Edges only — see the mesh structure',
                onTap: () => widget.onMode('wireframe')),
            _Chip(
                label: 'X-ray',
                tooltip: 'See-through surfaces',
                onTap: () => widget.onMode('xray')),
          ]),
          const SizedBox(height: 14),
          Text('SHADING',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  letterSpacing: 1,
                  color: c.textMuted)),
          const SizedBox(height: 10),
          Wrap(spacing: 10, children: [
            _Chip(
                label: 'Auto',
                tooltip: 'Picks smooth or faceted per model (default)',
                onTap: () => widget.onShading('auto')),
            _Chip(
                label: 'Smooth',
                tooltip: 'Rounded look — blends across facets',
                onTap: () => widget.onShading('smooth')),
            _Chip(
                label: 'Flat',
                tooltip: 'Crisp facets — low-poly look',
                onTap: () => widget.onShading('flat')),
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
            for (final (i, color) in _quick.indexed)
              _Swatch(
                color: color,
                tooltip: const ['Neutral', 'Pink', 'Violet', 'Cyan'][i],
                selected: color.toARGB32() == _current.toARGB32(),
                onTap: () => _pick(color),
              ),
            // Full-spectrum picker launcher (rainbow ring + palette glyph).
            _CustomSwatch(
              selected: _textureSel == null &&
                  !_quick.any((q) => q.toARGB32() == _current.toARGB32()),
              current: _current,
              onTap: _openFullPicker,
            ),
          ]),
          const SizedBox(height: 14),
          Text('TEXTURE',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  letterSpacing: 1,
                  color: c.textMuted)),
          const SizedBox(height: 10),
          Row(children: [
            _NoneSwatch(
              selected: _textureSel == null,
              onTap: () => _pickTexture(null),
            ),
            for (final t in kBundledTextures)
              _TextureSwatch(
                texture: t,
                selected: _textureSel == t.assetPath,
                onTap: () => _pickTexture(t.assetPath),
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
            tooltip: 'Brightness — how strong the lights are',
            value: _intensity,
            min: 0.2,
            max: 2.5,
            // Re-creates the rig — apply on release to avoid flicker mid-drag.
            onChanged: (v) => setState(() => _intensity = v),
            onChangeEnd: widget.onLightIntensity,
          ),
          _LightSlider(
            icon: LucideIcons.compass,
            tooltip: 'Light angle — turns where the light comes from',
            value: _angle,
            min: 0.0,
            max: 6.2831853, // 2π
            // Cheap (direction only) — drive live.
            onChanged: (v) {
              setState(() => _angle = v);
              widget.onLightAngle(v);
            },
          ),
          _LightSlider(
            icon: LucideIcons.globe, // environment / reflections (IBL), 0 = off
            tooltip: 'Environment reflections — 0 = off, right = shinier/realistic',
            value: _environment,
            min: 0.0,
            max: 1.0,
            // (Re)loads the IBL — apply on release.
            onChanged: (v) => setState(() => _environment = v),
            onChangeEnd: widget.onEnvironment,
          ),
        ],
      ),
    );
  }
}

/// A compact icon + slider row for a light control. [tooltip] gives a one-line
/// hint (tap or long-press the icon).
class _LightSlider extends StatelessWidget {
  const _LightSlider({
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.tooltip,
  });
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    final iconWidget = Icon(icon, size: 18, color: c.textMuted);
    return Row(children: [
      if (tooltip != null)
        Tooltip(
          message: tooltip!,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 3),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: iconWidget,
          ),
        )
      else
        iconWidget,
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
    return Tooltip(
      message: 'Custom color…',
      child: InkWell(
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
        child: Icon(Icons.add,
            size: 16, color: Colors.white.withValues(alpha: 0.9)),
      ),
      ),
    );
  }
}

/// A circular preview of a bundled texture (tap to apply it to the model).
class _TextureSwatch extends StatelessWidget {
  const _TextureSwatch({
    required this.texture,
    required this.selected,
    required this.onTap,
  });
  final BundledTexture texture;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: texture.name,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? c.textPrimary : c.borderHairline,
                width: selected ? 2 : 1,
              ),
              image: DecorationImage(
                image: AssetImage(texture.assetPath),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "No texture" swatch — restores the flat base color.
class _NoneSwatch extends StatelessWidget {
  const _NoneSwatch({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: 'None',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? c.textPrimary : c.borderHairline,
                width: selected ? 2 : 1,
              ),
            ),
            child: Icon(LucideIcons.ban, size: 16, color: c.textMuted),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(
      {required this.color,
      required this.onTap,
      this.selected = false,
      this.tooltip});
  final Color color;
  final VoidCallback onTap;
  final bool selected;

  /// One-line hint (the colour's name) shown on long-press.
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    Widget body = InkWell(
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
      );
    if (tooltip != null) body = Tooltip(message: tooltip!, child: body);
    return Padding(padding: const EdgeInsets.only(right: 12), child: body);
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
