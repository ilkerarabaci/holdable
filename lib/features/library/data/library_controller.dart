import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/library_model.dart';

/// Holds the wallet's models. In-memory for D3; D4 backs this with a Drift
/// repository (load on build, persist add/remove). The presentation layer
/// only depends on this controller, so swapping the backing store later is
/// invisible to the UI.
class LibraryController extends Notifier<List<LibraryModel>> {
  @override
  List<LibraryModel> build() => const [];

  void add(LibraryModel model) {
    state = [model, ...state];
  }

  void remove(String id) {
    state = state.where((m) => m.id != id).toList();
  }

  void rename(String id, String name) {
    state = [
      for (final m in state) m.id == id ? m.copyWith(name: name) : m,
    ];
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, List<LibraryModel>>(
        LibraryController.new);
