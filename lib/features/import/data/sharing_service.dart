import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'import_service.dart';

/// Bridges the OS "Open with / Share to Holdable" flow into the import
/// pipeline. Handles both the cold-start payload and the warm stream. Only the
/// supported (.obj/.stl) paths are imported; the rest are ignored.
class SharingService {
  SharingService(this.ref);
  final Ref ref;
  StreamSubscription<List<SharedMediaFile>>? _sub;

  Future<void> start() async {
    // Warm path: files shared while the app is already running.
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) => _ingest(files.map((f) => f.path)),
      onError: (_) {},
    );
    // Cold path: files that launched the app.
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initial.isNotEmpty) {
      await _ingest(initial.map((f) => f.path));
      ReceiveSharingIntent.instance.reset();
    }
  }

  Future<void> _ingest(Iterable<String> paths) async {
    final importer = ref.read(importServiceProvider);
    for (final path in ImportService.supportedPaths(paths)) {
      await importer.importPath(path);
    }
  }

  void dispose() => _sub?.cancel();
}

final sharingServiceProvider = Provider<SharingService>((ref) {
  final service = SharingService(ref);
  ref.onDispose(service.dispose);
  return service;
});
