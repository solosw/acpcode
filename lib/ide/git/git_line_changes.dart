// The lines of an open file changed since its last commit, marked by its
// line numbers as JetBrains IDEs' change markers and VS Code's quick diff
// (`dirtydiffDecorator.ts`) mark them: a bar by lines added or modified, a
// wedge where lines were deleted, each also on the overview ruler. A press
// on one shows the change (see ide_line_change_popup.dart).

import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'package:bao_editor/monaco/flutter/diff_editor_model.dart';
import 'package:bao_editor/monaco/flutter/document_snapshot.dart';
import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_decorations.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/range_mapping.dart';

import 'git_model.dart';
import 'git_repository.dart';

/// [document], the file at [path] in [repository], against its text at
/// HEAD: compared again as it is edited, and HEAD's read again as it moves
/// (after a status). No changes for a file HEAD has not got (a new one).
class IdeGitLineChanges extends ChangeNotifier {
  IdeGitLineChanges({
    required this.repository,
    required this.path,
    required this.document,
  }) {
    model = DiffEditorModel(
      original: _head,
      modified: document,
      ignoreTrimWhitespace: false,
    )..addListener(notifyListeners);
    repository.addListener(_statusChanged);
    _statusChanged();
  }

  final IdeGitRepository repository;
  final String path;
  final EditorDocumentModel document;

  final ValueNotifier<String?> _head = ValueNotifier(null);
  late final DiffEditorModel model;

  /// HEAD's commit for each status: one `rev-parse` however many files
  /// are open.
  static final Expando<Future<String?>> _heads = Expando();

  IdeGitState? _state;
  String? _headId;
  int _request = 0;
  bool _disposed = false;

  /// The file's text at HEAD; null while it is read, or where it has none.
  String? get original => _head.value;

  /// The changes, in order; none until compared.
  List<DetailedLineRangeMapping> get changes =>
      _head.value == null ? const [] : model.mappings ?? const [];

  void _statusChanged() {
    final state = repository.state;
    if (state == null || identical(state, _state)) return;
    _state = state;
    unawaited(_read(state));
  }

  Future<void> _read(IdeGitState state) async {
    final request = ++_request;
    final id = await (_heads[state] ??= repository.service
        .revParse('HEAD')
        .catchError((Object _) => null));
    if (_disposed || request != _request) return;
    if (id == _headId && id != null) return;
    _headId = id;
    String? text;
    if (id != null) {
      try {
        text = await repository.service.show(id, path);
      } on Object {
        // Not in HEAD: nothing to mark.
      }
    }
    if (_disposed || request != _request) return;
    _head.value = text;
    // Compared again as it is set; nothing to compare without one.
    if (text == null) notifyListeners();
  }

  /// The change [lineNumber] is in or by: its lines, or for lines deleted,
  /// the line before them (the first, deleted before it).
  DetailedLineRangeMapping? changeAt(int lineNumber) {
    for (final change in changes) {
      final range = ideLineChangeLines(change);
      if (lineNumber >= range.first && lineNumber <= range.last) return change;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    repository.removeListener(_statusChanged);
    model.dispose();
    _head.dispose();
    super.dispose();
  }
}

/// The kind of a line change, as its mark shows it.
enum IdeLineChangeKind { added, modified, deleted }

IdeLineChangeKind ideLineChangeKind(LineRangeMapping change) =>
    change.original.isEmpty
    ? IdeLineChangeKind.added
    : change.modified.isEmpty
    ? IdeLineChangeKind.deleted
    : IdeLineChangeKind.modified;

/// The lines [change]'s mark is by (from 1): its own, or for lines deleted
/// the one before them, the first where they were before it.
({int first, int last}) ideLineChangeLines(LineRangeMapping change) {
  final range = change.modified;
  if (range.isEmpty) {
    final line = range.startLineNumber > 1 ? range.startLineNumber - 1 : 1;
    return (first: line, last: line);
  }
  return (first: range.startLineNumber, last: range.endLineNumberExclusive - 1);
}

/// The marks of [changes] in [text]: by the line numbers in the
/// `editorGutter.*Background` colours, and on the overview ruler's left.
List<EditorDecoration> ideLineChangeDecorations(
  List<LineRangeMapping> changes,
  DocumentSnapshot text,
  Color? Function(String id) color,
) {
  final decorations = <EditorDecoration>[];
  for (final change in changes) {
    final kind = ideLineChangeKind(change);
    final lines = ideLineChangeLines(change);
    if (lines.first > text.lineCount) continue;
    final last = lines.last.clamp(lines.first, text.lineCount);
    final name = switch (kind) {
      IdeLineChangeKind.added => 'added',
      IdeLineChangeKind.modified => 'modified',
      IdeLineChangeKind.deleted => 'deleted',
    };
    final gutter = color('editorGutter.${name}Background');
    if (gutter == null) continue;
    decorations.add(
      EditorDecoration(
        start: text.lineStarts[lines.first - 1],
        end: text.contentEnds[last - 1],
        changeBar: EditorChangeBar(
          gutter,
          deleted: kind == IdeLineChangeKind.deleted,
          above:
              kind == IdeLineChangeKind.deleted &&
              change.modified.startLineNumber == 1,
        ),
        overviewRulerColor: color('editorOverviewRuler.${name}Foreground'),
        overviewRulerLane: OverviewRulerLane.left,
      ),
    );
  }
  return decorations;
}

/// Lines [start] to [end] (from 1) of the document as they were at HEAD,
/// past [changes]: an end inside a change goes to the change's lines at
/// HEAD. Null where the lines are all new.
({int start, int end})? ideGitHeadLines(
  int start,
  int end,
  List<LineRangeMapping> changes,
) {
  int map(int line, {required bool first}) {
    var delta = 0;
    for (final change in changes) {
      final modified = change.modified;
      if (line < modified.startLineNumber) break;
      if (line < modified.endLineNumberExclusive) {
        return first
            ? change.original.startLineNumber
            : change.original.endLineNumberExclusive - 1;
      }
      delta += modified.length - change.original.length;
    }
    return line - delta;
  }

  final from = map(start, first: true);
  final to = map(end, first: false);
  return to < from ? null : (start: from, end: to);
}
