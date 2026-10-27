// A file's Git blame by each of its lines, in a column by its line numbers:
// JetBrains IDEs' Annotate with Git Blame. When each line was last changed
// and by whom, older ones fainter; pressed, the commit in the Git log.
//
// The file as saved is blamed, so Git tells its uncommitted lines; lines
// edited since show nothing, the others are mapped past the edits (as
// git_blame.dart maps a line with a caret).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:bao_editor/monaco/flutter/diff_editor_model.dart';
import 'package:bao_editor/monaco/flutter/editor_document_model.dart';

import 'git_blame.dart' show ideGitSavedLineNumber;
import 'git_model.dart';
import 'git_repository.dart';

/// [document]'s blame, the file at [path] in [repository]: read again as
/// the file is saved ([sync]) or HEAD moves (a status).
class IdeGitAnnotations extends ChangeNotifier {
  IdeGitAnnotations({
    required this.repository,
    required this.path,
    required this.document,
  }) {
    _edits = DiffEditorModel(
      original: _saved,
      modified: document,
      ignoreTrimWhitespace: false,
    )..addListener(_changed);
    repository.addListener(_statusChanged);
    _state = repository.state;
    unawaited(_read());
  }

  final IdeGitRepository repository;
  final String path;
  final EditorDocumentModel document;

  /// The text blamed: the file as saved.
  late final ValueNotifier<String?> _saved = ValueNotifier(document.savedText);

  /// The edits since it was saved.
  late final DiffEditorModel _edits;

  IdeGitState? _state;
  int _request = 0;
  bool _disposed = false;

  /// Each range of the saved text with its commit, by first line.
  List<(int, int, IdeGitBlameInformation)>? _ranges;

  /// Each commit's age among the file's: 0 the newest, 1 the oldest.
  Map<String, double> _ages = const {};

  /// Whether the blame has been read.
  bool get loaded => _ranges != null;

  /// Reads the blame again where the file was saved since.
  void sync() {
    if (_disposed || identical(_saved.value, document.savedText)) return;
    _saved.value = document.savedText;
    unawaited(_read());
  }

  void _statusChanged() {
    final state = repository.state;
    if (identical(state, _state)) return;
    _state = state;
    unawaited(_read());
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _read() async {
    final request = ++_request;
    List<IdeGitBlameInformation>? blame;
    try {
      blame = await repository.service.blame(path);
    } on Object {
      blame = null;
    }
    if (_disposed || request != _request) return;
    final ranges = [
      for (final information in blame ?? const <IdeGitBlameInformation>[])
        for (final range in information.ranges)
          (range.startLineNumber, range.endLineNumber, information),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    // Ranked by date: ten shades from the newest to the oldest.
    final dates = {
      for (final (_, _, information) in ranges)
        if (!information.uncommitted && information.authorDate != null)
          information.hash: information.authorDate!,
    };
    final order = dates.keys.toList()
      ..sort((a, b) => dates[b]!.compareTo(dates[a]!));
    _ages = {
      for (final (index, hash) in order.indexed)
        hash: order.length < 2 ? 0 : index / (order.length - 1),
    };
    _ranges = ranges;
    notifyListeners();
  }

  /// The commit that last changed [lineNumber] of the editor's text (from
  /// 1); null for a line not committed yet, edited since it was saved, or
  /// while the blame or the edits are read.
  IdeGitBlameInformation? at(int lineNumber) {
    final ranges = _ranges;
    if (ranges == null) return null;
    var line = lineNumber;
    if (document.isDirty) {
      final edits = _edits.mappings;
      if (edits == null) return null;
      final saved = ideGitSavedLineNumber(lineNumber, edits);
      if (saved == null) return null;
      line = saved;
    }
    var low = 0;
    var high = ranges.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (ranges[middle].$1 <= line) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return null;
    final (_, end, information) = ranges[low - 1];
    if (line > end || information.uncommitted) return null;
    return information;
  }

  /// How old [commit] is among the file's: 0 the newest, 1 the oldest.
  double ageOf(IdeGitBlameInformation commit) => _ages[commit.hash] ?? 1;

  @override
  void dispose() {
    _disposed = true;
    repository.removeListener(_statusChanged);
    _edits.dispose();
    _saved.dispose();
    super.dispose();
  }
}
