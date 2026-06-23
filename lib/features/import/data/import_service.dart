import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../library/data/library_controller.dart';
import '../../library/domain/library_model.dart';
import 'conversion_service.dart';

/// Outcome of an import attempt, surfaced to the UI for feedback.
enum ImportStatus { added, cancelled, unsupported, duplicate, error }

class ImportResult {
  const ImportResult(this.status, {this.model, this.message});
  final ImportStatus status;
  final LibraryModel? model;
  final String? message;
}

/// Phase of an in-flight import that needs cloud conversion (the async Job
/// path), surfaced to the UI so it can show real progress instead of an
/// indeterminate spinner.
enum ImportPhase { uploading, converting, downloading }

class ImportProgress {
  const ImportProgress(this.phase, {this.fraction});
  final ImportPhase phase;

  /// 0..1 during [ImportPhase.uploading]; null = indeterminate (cloud phases).
  final double? fraction;
}

/// Imports models into the wallet. Two entry points share one copy-and-register
/// core: the file picker ([pickAndImport]) and incoming shares ([importPath]).
/// Alpha = local-only.
class ImportService {
  ImportService(this.ref);
  final Ref ref;

  /// Filters a set of incoming paths down to supported model files. Pure, so
  /// the share-intent handler can be reasoned about and tested without IO.
  static List<String> supportedPaths(Iterable<String> paths) => [
        for (final p in paths)
          if (ModelFormat.fromExtension(_ext(p)) != null ||
              kConvertibleExtensions.contains(_ext(p).toLowerCase()))
            p,
      ];

  Future<ImportResult> pickAndImport({
    Future<bool> Function(int sizeBytes)? confirmOversize,
    Future<bool> Function(String name)? confirmDuplicate,
    void Function(ImportProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    final FilePickerResult? result;
    try {
      // Use FileType.any, NOT FileType.custom with allowedExtensions: on
      // Android the Storage Access Framework greys out files whose extension
      // has no registered MIME type (.obj / .stl don't), so the user can't
      // select their own model — they could only get one in via the share
      // intent. FileType.any shows everything; we validate the extension
      // ourselves in [importPath] (returns ImportStatus.unsupported otherwise).
      result = await FilePicker.platform.pickFiles(type: FileType.any);
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
    if (result == null || result.files.isEmpty) {
      return const ImportResult(ImportStatus.cancelled);
    }
    final picked = result.files.single;
    if (picked.path == null) {
      return const ImportResult(ImportStatus.unsupported);
    }
    // Soft cap: very large models load slowly and can push memory past budget
    // (see docs/perf-w3-baseline.md). Let the UI confirm before importing.
    if (picked.size > kMaxImportBytes && confirmOversize != null) {
      final proceed = await confirmOversize(picked.size);
      if (!proceed) return const ImportResult(ImportStatus.cancelled);
    }
    return importPath(picked.path!,
        displayName: picked.name,
        size: picked.size,
        confirmDuplicate: confirmDuplicate,
        onProgress: onProgress,
        cancel: cancel);
  }

  /// Copies the file at [path] into app storage and registers it. Used by both
  /// the picker and the share-intent flow.
  Future<ImportResult> importPath(String path,
      {String? displayName,
      int? size,
      Future<bool> Function(String name)? confirmDuplicate,
      void Function(ImportProgress)? onProgress,
      CancelToken? cancel}) async {
    final format = ModelFormat.fromExtension(_ext(path));
    if (format == null) {
      // Not natively parseable — but if it's a convertible format (.blend,
      // USD, …) route it through the conversion service, which returns a glb.
      final ext = _ext(path).toLowerCase();
      if (kConvertibleExtensions.contains(ext)) {
        return _importViaConversion(path, ext,
            displayName: displayName,
            confirmDuplicate: confirmDuplicate,
            onProgress: onProgress,
            cancel: cancel);
      }
      if (kUnsupportedCadExtensions.contains(ext)) {
        return ImportResult(ImportStatus.unsupported,
            message:
                "Holdable can't open .$ext directly. Export a STEP (.step) or "
                'IGES (.iges) file from your CAD tool and import that instead.');
      }
      return const ImportResult(ImportStatus.unsupported,
          message: 'Supported formats: .obj, .stl, .glb, .gltf, .ply, .3mf, .off, .dae, .3ds, .fbx (ASCII)');
    }
    try {
      final source = File(path);
      final name =
          _baseName(displayName ?? path.split(Platform.pathSeparator).last);
      final resolvedSize = size ?? source.lengthSync();
      // A model already in the wallet (same name+size+format) is refused unless
      // the user confirms a re-import (PO #3). Checked before copying so a
      // declined duplicate doesn't leave an orphaned file.
      if (_isDuplicate(name, resolvedSize, format) &&
          !await _confirmReimport(confirmDuplicate, name)) {
        return ImportResult(ImportStatus.duplicate,
            message: '"$name" is already in your library.');
      }
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.${format.fileExtension}';
      await source.copy(dest);

      final model = LibraryModel(
        id: id,
        name: name,
        format: format,
        sizeBytes: resolvedSize,
        filePath: dest,
        importedAt: now,
      );
      await ref.read(libraryControllerProvider.notifier).add(model);
      return ImportResult(ImportStatus.added, model: model);
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  /// Sends a non-native file ([ext] in [kConvertibleExtensions]) to the
  /// conversion service, then imports the returned glb as a normal model — so
  /// the viewer/AR see a plain glb and nothing downstream needs to change.
  Future<ImportResult> _importViaConversion(String path, String ext,
      {String? displayName,
      Future<bool> Function(String name)? confirmDuplicate,
      void Function(ImportProgress)? onProgress,
      CancelToken? cancel}) async {
    try {
      final source = File(path);
      final name =
          _baseName(displayName ?? path.split(Platform.pathSeparator).last);
      final bytes = source.lengthSync();
      // Above the async ceiling we still refuse (don't burn upload data on an
      // absurd file). Otherwise: small, fast-converting files go in-request;
      // anything over the sync cap — OR an export-bound format like .blend that
      // times out the sync request at any size — converts in a Cloud Run Job.
      if (bytes > kMaxAsyncUploadBytes) {
        final mb = (bytes / (1024 * 1024)).round();
        final cap = kMaxAsyncUploadBytes ~/ (1024 * 1024);
        return ImportResult(ImportStatus.error,
            message: 'This file is ${mb}MB. The limit is ${cap}MB.');
      }
      const svc = ConversionService();
      final glb = conversionNeedsAsyncJob(
              bytes: bytes, ext: ext, syncMaxBytes: kSyncConvertMax)
          ? await (() async {
              // Big file → async Job. Stream the upload (reporting %), poll,
              // then download the mobile-fit glb the Job produced.
              onProgress
                  ?.call(const ImportProgress(ImportPhase.uploading, fraction: 0));
              var lastPct = -1;
              final jobId = await svc.enqueueLargeConversion(source, ext,
                  cancel: cancel,
                  onUploadProgress: (sent, total) {
                if (total <= 0 || onProgress == null) return;
                final pct = sent * 100 ~/ total;
                if (pct == lastPct) return; // throttle to whole-percent steps
                lastPct = pct;
                onProgress(ImportProgress(ImportPhase.uploading,
                    fraction: sent / total));
              });
              // Persist now: the Job runs server-side, so a kill/restart from
              // here on can resume instead of losing the conversion (#4).
              await _savePending(jobId, name);
              onProgress?.call(const ImportProgress(ImportPhase.converting));
              final status = await svc.awaitJob(jobId, cancel: cancel);
              if (!status.isDone || status.downloadUrl == null) {
                throw ConversionException(status.error ?? 'Conversion failed.');
              }
              onProgress?.call(const ImportProgress(ImportPhase.downloading));
              return svc.downloadJobGlb(status.downloadUrl!, cancel: cancel);
            })()
          : await svc.convertToGlb(source.readAsBytesSync(), ext);

      final result =
          await _saveGlb(glb, name, confirmDuplicate: confirmDuplicate);
      await _clearPending(); // resolved — nothing left to resume
      return result;
    } on CancelledException {
      await _clearPending();
      return const ImportResult(ImportStatus.cancelled);
    } on ConversionException catch (e) {
      await _clearPending();
      // A force-closed client (cancel) surfaces as a transport error — classify
      // it as a cancellation, not a failure, when the token says so.
      if (cancel?.isCancelled ?? false) {
        return const ImportResult(ImportStatus.cancelled);
      }
      return ImportResult(ImportStatus.error, message: e.message);
    } catch (e) {
      await _clearPending();
      if (cancel?.isCancelled ?? false) {
        return const ImportResult(ImportStatus.cancelled);
      }
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  /// Writes [glb] as a model named [name] and registers it in the wallet.
  /// Shared by the conversion import path and the restart-resume path.
  Future<ImportResult> _saveGlb(Uint8List glb, String name,
      {Future<bool> Function(String name)? confirmDuplicate}) async {
    if (_isDuplicate(name, glb.length, ModelFormat.glb) &&
        !await _confirmReimport(confirmDuplicate, name)) {
      return ImportResult(ImportStatus.duplicate,
          message: '"$name" is already in your library.');
    }
    final docs = await getApplicationDocumentsDirectory();
    final modelsDir = Directory('${docs.path}/models');
    if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final dest = '${modelsDir.path}/$id.glb';
    await File(dest).writeAsBytes(glb);

    final model = LibraryModel(
      id: id,
      name: name,
      format: ModelFormat.glb,
      sizeBytes: glb.length,
      filePath: dest,
      importedAt: now,
    );
    await ref.read(libraryControllerProvider.notifier).add(model);
    return ImportResult(ImportStatus.added, model: model);
  }

  // --- Restart-resume of an in-flight large conversion (#4) ------------------
  // The Cloud Run Job runs server-side, independent of the app. Persisting the
  // jobId while it's in flight lets a kill/restart mid-conversion pick it back
  // up instead of silently dropping the import.
  static const String _kPendingKey = 'holdable_pending_conversion_v1';

  Future<void> _savePending(String jobId, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kPendingKey, jsonEncode({'jobId': jobId, 'name': name}));
    } catch (_) {/* persistence is best-effort */}
  }

  Future<void> _clearPending() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_kPendingKey);
    } catch (_) {/* best-effort */}
  }

  /// If a large conversion was still running when the app closed, resume polling
  /// its Cloud Run Job, download the result and import it. Returns null when
  /// nothing was pending. Call once on app/library start.
  Future<ImportResult?> resumePendingConversion({
    void Function(ImportProgress)? onProgress,
    Future<bool> Function(String name)? confirmDuplicate,
  }) async {
    String? raw;
    try {
      raw = (await SharedPreferences.getInstance()).getString(_kPendingKey);
    } catch (_) {
      return null;
    }
    if (raw == null) return null;
    String? jobId;
    var name = 'Model';
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      jobId = j['jobId'] as String?;
      name = (j['name'] as String?) ?? name;
    } catch (_) {/* corrupt record — cleared below */}
    if (jobId == null) {
      await _clearPending();
      return null;
    }
    const svc = ConversionService();
    try {
      onProgress?.call(const ImportProgress(ImportPhase.converting));
      final status = await svc.awaitJob(jobId);
      if (!status.isDone || status.downloadUrl == null) {
        await _clearPending();
        return ImportResult(ImportStatus.error,
            message: status.error ?? 'Conversion failed.');
      }
      onProgress?.call(const ImportProgress(ImportPhase.downloading));
      final glb = await svc.downloadJobGlb(status.downloadUrl!);
      final result =
          await _saveGlb(glb, name, confirmDuplicate: confirmDuplicate);
      await _clearPending();
      return result;
    } on ConversionException catch (e) {
      await _clearPending();
      return ImportResult(ImportStatus.error, message: e.message);
    } catch (e) {
      await _clearPending();
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  /// Imports a bundled CC0 sample model (from assets/sample_models/) into the
  /// wallet — used by the import sheet's "Sample models" option.
  Future<ImportResult> importAsset(String assetPath, String displayName,
      {Future<bool> Function(String name)? confirmDuplicate}) async {
    final format = ModelFormat.fromExtension(_ext(assetPath));
    if (format == null) return const ImportResult(ImportStatus.unsupported);
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      if (_isDuplicate(displayName, bytes.length, format) &&
          !await _confirmReimport(confirmDuplicate, displayName)) {
        return ImportResult(ImportStatus.duplicate,
            message: '"$displayName" is already in your library.');
      }
      final docs = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${docs.path}/models');
      if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

      final now = DateTime.now();
      final id = now.microsecondsSinceEpoch.toString();
      final dest = '${modelsDir.path}/$id.${format.fileExtension}';
      await File(dest).writeAsBytes(bytes);

      final model = LibraryModel(
        id: id,
        name: displayName,
        format: format,
        sizeBytes: bytes.length,
        filePath: dest,
        importedAt: now,
      );
      await ref.read(libraryControllerProvider.notifier).add(model);
      return ImportResult(ImportStatus.added, model: model);
    } catch (e) {
      return ImportResult(ImportStatus.error, message: '$e');
    }
  }

  /// True if a model with the same display name, byte size and format is already
  /// in the wallet — the practical signal for an exact re-import (each import
  /// gets a fresh id + copied file, so paths never match).
  bool _isDuplicate(String name, int sizeBytes, ModelFormat format) {
    final existing = ref.read(libraryControllerProvider);
    return existing.any((m) =>
        m.name == name && m.sizeBytes == sizeBytes && m.format == format);
  }

  /// Returns true only when the user explicitly chose to re-import a model
  /// that's already in the wallet (PO #3). With no callback — e.g. the
  /// background share-intent path, which has no UI to ask — duplicates stay
  /// refused, preserving the prior behaviour.
  static Future<bool> _confirmReimport(
      Future<bool> Function(String name)? confirm, String name) async {
    if (confirm == null) return false;
    return confirm(name);
  }

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot + 1) : '';
  }

  static String _baseName(String fileName) {
    final slash = fileName.lastIndexOf(RegExp(r'[\\/]'));
    final name = slash >= 0 ? fileName.substring(slash + 1) : fileName;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}

/// Soft cap for imports. Files larger than this prompt a confirmation before
/// loading — alpha scope is <=50 MB; 60 leaves headroom. A 50 MB STL already
/// sits near the 200 MB PSS budget (docs/perf-w3-baseline.md), so this guards
/// against accidentally importing something that loads slowly / runs hot.
const kMaxImportBytes = 60 * 1024 * 1024;

/// Files up to this size convert SYNCHRONOUSLY (≤28 MB POST direct, 28-200 MB
/// via the GCS-upload path). Anything larger converts in an ASYNC Cloud Run Job
/// instead of being refused. 200 MB = the paid-tier sync ceiling.
/// TODO(tier): drop to ~50 MB for free once entitlements ship.
const kSyncConvertMax = 200 * 1024 * 1024;

/// Upper bound for the async (>200 MB) path — an abuse ceiling, not a product
/// wall. Above this we refuse before burning the user's upload data.
const kMaxAsyncUploadBytes = 2 * 1024 * 1024 * 1024;

/// Proprietary / closed CAD formats we deliberately do NOT convert: there's no
/// open reader (FreeCAD/OpenCASCADE can't parse them — they'd need a licensed
/// commercial engine). When one is imported we point the user at the
/// interchange formats we DO support (STEP/IGES), which every CAD tool exports.
const Set<String> kUnsupportedCadExtensions = {
  'sldprt', 'sldasm', // SolidWorks
  'ipt', 'iam', // Inventor
  'catpart', 'catproduct', // CATIA
  'f3d', 'f3z', // Fusion 360
  'dwg', 'dxf', // AutoCAD (and mostly 2D)
  'x_t', 'x_b', // Parasolid
  'sat', // ACIS
};

final importServiceProvider = Provider<ImportService>(ImportService.new);
