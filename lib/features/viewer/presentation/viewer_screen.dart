import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../app/theme/prism_colors.dart';
import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';

/// Interactive 3D viewer. Renders the model in a WebView running a bundled
/// three.js scene (OBJ/STL loaders, OrbitControls). Model bytes are passed to
/// JS as base64 over a channel — no CORS, no local server. Large-file chunking
/// is a follow-up (alpha budget: 50MB STL < 3s).
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({super.key, required this.model});

  final LibraryModel model;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

enum _Tab { view, render, info }

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  late final WebViewController _controller;
  _Tab _tab = _Tab.view;
  bool _loading = true;
  String? _error;
  int? _tris;
  int? _verts;
  int? _ms;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0E0E10))
      ..addJavaScriptChannel('ModelChannel', onMessageReceived: _onMessage)
      ..loadFlutterAsset('assets/3d-engine/viewer.html');
  }

  Future<void> _onMessage(JavaScriptMessage message) async {
    final raw = message.message;
    if (raw == 'ready') {
      await _sendModel();
      return;
    }
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      if (data['type'] == 'loaded') {
        setState(() {
          _loading = false;
          _tris = (data['tris'] as num?)?.toInt();
          _verts = (data['verts'] as num?)?.toInt();
          _ms = (data['ms'] as num?)?.toInt();
        });
      } else if (data['type'] == 'error') {
        setState(() {
          _loading = false;
          _error = data['message'] as String? ?? 'Failed to render';
        });
      } else if (data['type'] == 'thumb') {
        await _saveThumbnail(data['data'] as String);
      }
    } catch (_) {/* ignore non-JSON */}
  }

  /// Persists the base64 PNG thumbnail captured by the viewer and points the
  /// library model at it (shown on the card next time).
  Future<void> _saveThumbnail(String b64) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final thumbsDir = Directory('${docs.path}/thumbs');
      if (!thumbsDir.existsSync()) thumbsDir.createSync(recursive: true);
      final path = '${thumbsDir.path}/${widget.model.id}.png';
      await File(path).writeAsBytes(base64Decode(b64));
      await ref
          .read(libraryControllerProvider.notifier)
          .setThumbnail(widget.model.id, path);
    } catch (_) {/* best-effort */}
  }

  void _setMode(String mode) =>
      _controller.runJavaScript("window.setRenderMode('$mode')");
  void _setView(String which) =>
      _controller.runJavaScript("window.setView('$which')");

  Future<void> _sendModel() async {
    try {
      final bytes = await File(widget.model.filePath).readAsBytes();
      final b64 = base64Encode(bytes);
      // Send in 256KB chunks — a single arg this large trips Android's binder
      // limit (TransactionTooLargeException) on big models. base64 is quote/
      // backslash-free, so it embeds safely in a single-quoted JS literal.
      const chunkSize = 256 * 1024;
      for (var i = 0; i < b64.length; i += chunkSize) {
        final end = (i + chunkSize < b64.length) ? i + chunkSize : b64.length;
        await _controller.runJavaScript("window.appendChunk('${b64.substring(i, end)}')");
      }
      await _controller.runJavaScript("window.loadChunked('${widget.model.format.name}')");
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.prism;
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E10),
        foregroundColor: const Color(0xFFF5F5F7),
        title: Text(widget.model.name),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _controller)),
          if (_loading && _error == null)
            const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  "Couldn't render this model.",
                  style: TextStyle(color: c.textMuted),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (_tab == _Tab.view)
            Positioned(left: 0, right: 0, bottom: 0, child: _PresetPanel(onView: _setView)),
          if (_tab == _Tab.render)
            Positioned(left: 0, right: 0, bottom: 0, child: _RenderPanel(onMode: _setMode)),
          if (_tab == _Tab.info)
            Positioned(left: 0, right: 0, bottom: 0, child: _InfoPanel(
              model: widget.model, tris: _tris, verts: _verts, ms: _ms,
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

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.current, required this.onSelect});
  final _Tab current;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF16161A),
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
            _ToolButton(icon: LucideIcons.scan, label: 'AR',
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
    const muted = Color(0xFF6B6B73);
    final color = disabled
        ? muted
        : (active ? const Color(0xFF8B6CFF) : const Color(0xFFF5F5F7));
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
            Text(
              badge ?? label,
              style: TextStyle(
                fontSize: badge != null ? 9 : 11,
                color: color,
                fontFamily: badge != null ? 'monospace' : null,
                letterSpacing: badge != null ? 0.5 : 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared dark panel chrome for the viewer's bottom overlays.
class _Panel extends StatelessWidget {
  const _Panel({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xCC16161A),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11, letterSpacing: 1,
                    color: Color(0xFF8A8A95))),
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
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFF5F5F7),
        side: const BorderSide(color: Color(0x33FFFFFF)),
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
      child: Wrap(
        spacing: 10,
        children: [
          _Chip(label: 'Front', onTap: () => onView('front')),
          _Chip(label: 'Top', onTap: () => onView('top')),
          _Chip(label: 'Side', onTap: () => onView('side')),
          _Chip(label: 'Iso', onTap: () => onView('iso')),
        ],
      ),
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
      child: Wrap(
        spacing: 10,
        children: [
          _Chip(label: 'Solid', onTap: () => onMode('solid')),
          _Chip(label: 'Wireframe', onTap: () => onMode('wireframe')),
          _Chip(label: 'X-ray', onTap: () => onMode('xray')),
        ],
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.model, this.tris, this.verts, this.ms});
  final LibraryModel model;
  final int? tris;
  final int? verts;
  final int? ms;

  @override
  Widget build(BuildContext context) {
    String n(int? v) => v == null ? '—' : v.toString();
    final rows = <List<String>>[
      ['FORMAT', model.format.label],
      ['VERTICES', n(verts)],
      ['TRIANGLES', n(tris)],
      ['PARSE', ms == null ? '—' : '${ms}ms'],
    ];
    return Container(
      color: const Color(0xCC16161A),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(r[0],
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            letterSpacing: 1,
                            color: Color(0xFF8A8A95))),
                    Text(r[1],
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: Color(0xFFF5F5F7))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
