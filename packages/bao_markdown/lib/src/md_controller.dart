import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'md_blocks.dart';
import 'md_inline.dart';
import 'md_lines.dart';

/// An edit of the text: [start] to [end] (before it) replaced by [text].
@immutable
class MdChange {
  const MdChange(this.start, this.end, this.text, this.splice, this.parsed);

  final int start;
  final int end;
  final String text;

  /// The lines it replaced, and those it put in.
  final MdSplice splice;

  /// The lines whose kinds were read again (first and last, inclusive).
  final (int, int) parsed;
}

/// What an edit was, for Undo to take back typing as one step.
enum MdEditKind { typing, deleting, other }

/// A change of a text: [start] to [end] (before it) replaced by [text].
@immutable
class MdTextEdit {
  const MdTextEdit(this.start, this.end, this.text);

  final int start;
  final int end;
  final String text;
}

/// Where a [MarkdownController]'s text is kept when it is another's: an
/// editor's document, which other views edit too. The controller edits it
/// through this, and shows what it is told changed (its own edits too);
/// Undo is the source's, one for all its views.
abstract interface class MarkdownTextSource {
  String get text;

  /// [onEdits] told of each change of the text, at once (before the edit
  /// that made it returns): its edits in order, each in the text the one
  /// before left. What stops it is returned.
  void Function() listen(void Function(List<MdTextEdit> edits) onEdits);

  /// [start] to [end] replaced by [text]: a step of Undo's, or, [join]ed,
  /// part of the last one. [before] and [after] are the selections Undo
  /// and Redo put back.
  void edit(
    int start,
    int end,
    String text, {
    required TextSelection before,
    required TextSelection after,
    required bool join,
  });

  /// The next edit starts a step of its own.
  void breakStep();

  bool get canUndo;
  bool get canRedo;

  /// The last step taken back (done again); false when there was none.
  bool undo();
  bool redo();

  /// The selection the last [undo] or [redo] put back, if it kept one.
  TextSelection? get restoredSelection;
}

/// An edit Undo takes back: [removed] at [start] gave way to [inserted].
class _Edit {
  _Edit(this.start, this.removed, this.inserted);

  final int start;
  String removed;
  String inserted;
}

class _Step {
  _Step(this.edits, this.before, this.after, this.kind, this.at);

  /// In the order they were made.
  final List<_Edit> edits;
  final TextSelection before;
  TextSelection after;
  final MdEditKind kind;
  DateTime at;
}

/// A markdown text being edited: the text itself (nothing else is kept of
/// it), its selection, what an input method is composing, and its Undo.
///
/// Its listeners are told of every change of the text or the selection;
/// [selectionListenable] only of the selection's, [textVersion] tells
/// which it was.
class MarkdownController extends ChangeNotifier {
  MarkdownController({
    String text = '',
    TextSelection selection = const TextSelection.collapsed(offset: 0),
    this.plain = false,
    this.inline = false,
  }) : _lines = MdLines(text),
       _source = null {
    _blocks = MdBlocks(_lines, plain: plain || inline);
    _selection = ValueNotifier(_clamp(selection));
  }

  /// [source]'s text, edited there (see [MarkdownTextSource]).
  MarkdownController.of(
    MarkdownTextSource source, {
    TextSelection selection = const TextSelection.collapsed(offset: 0),
    this.plain = false,
    this.inline = false,
  }) : _lines = MdLines(source.text),
       _source = source {
    _blocks = MdBlocks(_lines, plain: plain || inline);
    _selection = ValueNotifier(_clamp(selection));
    _stopListening = source.listen(_sourceChanged);
  }

  final MdLines _lines;

  /// Text, not markdown: its lines shown as they are written, nothing in
  /// them but its atoms ([MdAtoms]) shown otherwise; Enter only a line.
  final bool plain;

  /// Markdown's runs only (a table's cell): every line a paragraph, its
  /// marks (bold, code, links…) markdown's.
  final bool inline;

  /// Where the text is kept, when it is another's.
  final MarkdownTextSource? _source;
  void Function()? _stopListening;

  /// An edit of this controller's is being made in [_source].
  bool _editing = false;
  late final MdBlocks _blocks;
  late final ValueNotifier<TextSelection> _selection;

  /// The text, as it was given and edited.
  String get text => _lines.text;

  int get length => _lines.length;

  MdLines get lines => _lines;
  MdBlocks get blocks => _blocks;

  /// Changes with every edit of the text (not of the selection).
  int get textVersion => _textVersion;
  int _textVersion = 0;

  /// The last edit of the text.
  MdChange? get lastChange => _lastChange;
  MdChange? _lastChange;

  TextSelection get selection => _selection.value;
  set selection(TextSelection value) {
    final clamped = _clamp(value);
    if (clamped == _selection.value) return;
    _selection.value = clamped;
    notifyListeners();
  }

  /// Told only of the selection's changes.
  ValueListenable<TextSelection> get selectionListenable => _selection;

  /// What an input method is composing (pinyin…), in the text; empty for
  /// nothing.
  TextRange get composing => _composing;
  TextRange _composing = TextRange.empty;
  set composing(TextRange value) {
    if (value == _composing) return;
    _composing = value;
    notifyListeners();
  }

  bool get isComposing => _composing.isValid && !_composing.isCollapsed;

  /// The text from [start] to [end].
  String substring(int start, [int? end]) => _lines.substring(start, end);

  /// The selected text.
  String get selectedText =>
      selection.isValid ? substring(selection.start, selection.end) : '';

  TextSelection _clamp(TextSelection selection) {
    if (!selection.isValid) return selection;
    final length = _lines.length;
    return selection.copyWith(
      baseOffset: selection.baseOffset.clamp(0, length),
      extentOffset: selection.extentOffset.clamp(0, length),
    );
  }

  // --- Lines ---------------------------------------------------------------

  /// The line [offset] is in.
  int lineAt(int offset) => _lines.lineAt(offset);

  int lineStart(int line) => _lines.lineStart(line);

  /// Before the line's `\r\n` (or `\n`).
  int lineEnd(int line) => _lines.lineEnd(line);

  MdLineInfo infoOf(int line) => _blocks.info(line);

  /// The markdown runs of [line]'s text (none for one that is code, a
  /// table's…), as the line's text reads now.
  List<MdInline> inlinesOf(int line) {
    final info = _blocks.info(line);
    if (!info.hasInline) return const [];
    final id = _lines.idOf(line);
    final text = _lines.line(line);
    final cached = _inlines[id];
    if (cached != null &&
        identical(cached.text, text) &&
        cached.info == info &&
        cached.definitions == _blocks.definitionsVersion) {
      return cached.runs;
    }
    final runs = plain
        ? MdAtoms.parse(text, info.contentStart, info.contentEnd)
        : parseInline(
            text,
            info.contentStart,
            info.contentEnd,
            definitions: _blocks.definitions,
          );
    _inlines[id] = (
      text: text,
      info: info,
      definitions: _blocks.definitionsVersion,
      runs: runs,
    );
    return runs;
  }

  final Map<
    int,
    ({String text, MdLineInfo info, int definitions, List<MdInline> runs})
  >
  _inlines = {};

  /// The lines of the block [line] is in, a fence's, a table's…: the
  /// line's alone for one of a single line.
  (int, int) blockOf(int line) {
    final info = _blocks.info(line);
    bool same(MdLineInfo other) => switch (info.kind) {
      _ when info.isFence => other.isFence,
      _ when info.isTable => other.isTable,
      _ when info.isMath => other.isMath,
      MdLineKind.html => other.kind == MdLineKind.html,
      MdLineKind.frontMatter => other.kind == MdLineKind.frontMatter,
      MdLineKind.indentedCode => other.kind == MdLineKind.indentedCode,
      _ => false,
    };
    if (info.kind == MdLineKind.heading && info.setext) {
      return (line, math.min(line + 1, _lines.lineCount - 1));
    }
    if (info.kind == MdLineKind.setextUnderline) return (line - 1, line);
    bool opens(MdLineInfo info) =>
        info.kind == MdLineKind.fenceOpen ||
        info.kind == MdLineKind.mathOpen ||
        info.kind == MdLineKind.tableHead;
    bool closes(MdLineInfo info) =>
        info.kind == MdLineKind.fenceClose || info.kind == MdLineKind.mathClose;
    var first = line;
    while (first > 0 &&
        !opens(_blocks.info(first)) &&
        same(_blocks.info(first - 1)) &&
        !closes(_blocks.info(first - 1))) {
      first--;
    }
    var last = line;
    while (last + 1 < _lines.lineCount &&
        !closes(_blocks.info(last)) &&
        same(_blocks.info(last + 1)) &&
        !opens(_blocks.info(last + 1))) {
      last++;
    }
    return (first, last);
  }

  // --- Editing ---------------------------------------------------------------

  /// [start] to [end] replaced by [replacement], the selection then
  /// [selection] (else after it). A step of Undo's, joined to the one
  /// before when both are typing (or deleting) where the other ended, a
  /// moment apart.
  void replace(
    int start,
    int end,
    String replacement, {
    TextSelection? selection,
    MdEditKind kind = MdEditKind.other,
    TextRange composing = TextRange.empty,
  }) {
    start = start.clamp(0, length);
    end = end.clamp(start, length);
    final removed = _lines.substring(start, end);
    if (removed == replacement &&
        (selection == null || selection == this.selection)) {
      return;
    }
    final before = this.selection;
    final after =
        selection ??
        TextSelection.collapsed(offset: start + replacement.length);
    if (_source case final source?) {
      final join = _joins(start, end, replacement, kind);
      _editing = true;
      try {
        source.edit(
          start,
          end,
          replacement,
          before: before,
          after: after,
          join: join,
        );
      } finally {
        _editing = false;
      }
      _composing = composing;
      _selection.value = _clamp(after);
      notifyListeners();
      return;
    }
    _apply(start, end, replacement);
    final group = _group;
    if (group != null) {
      group.edits.add(_Edit(start, removed, replacement));
      group.after = after;
    } else {
      _record(start, removed, replacement, before, after, kind);
    }
    _composing = composing;
    _selection.value = _clamp(after);
    notifyListeners();
  }

  /// [start] to [end] replaced by [replacement] as part of the last step
  /// of Undo's: what follows from it (a space after something the step
  /// left last on its line), undone with it. The selection stays where it
  /// was, moved along, unless [selection] says.
  void amend(
    int start,
    int end,
    String replacement, {
    TextSelection? selection,
  }) {
    start = start.clamp(0, length);
    end = end.clamp(start, length);
    final removed = _lines.substring(start, end);
    if (removed == replacement) return;
    final after = selection ?? _moved(this.selection, start, end, replacement);
    if (_source case final source?) {
      _editing = true;
      try {
        source.edit(
          start,
          end,
          replacement,
          before: this.selection,
          after: after,
          join: true,
        );
      } finally {
        _editing = false;
      }
    } else {
      _apply(start, end, replacement);
      if (_group case final group?) {
        group.edits.add(_Edit(start, removed, replacement));
        group.after = after;
      } else if (_undo.lastOrNull case final last?) {
        last.edits.add(_Edit(start, removed, replacement));
        last.after = after;
      }
    }
    _selection.value = _clamp(after);
    notifyListeners();
  }

  /// [start] to [end] replaced by [replacement] where Undo does not see
  /// it: another's change of the same text, shown here, or something shown
  /// a moment and taken out again. The steps Undo has may no longer fit
  /// the text: [forgetUndo] where they would not. The selection stays where
  /// it was, moved along, unless [selection] says.
  void replaceUnrecorded(
    int start,
    int end,
    String replacement, {
    TextSelection? selection,
  }) {
    assert(_source == null, 'A source keeps its own Undo');
    start = start.clamp(0, length);
    end = end.clamp(start, length);
    if (_lines.substring(start, end) == replacement && selection == null) {
      return;
    }
    final after = selection ?? _moved(this.selection, start, end, replacement);
    _apply(start, end, replacement);
    _composing = TextRange.empty;
    _selection.value = _clamp(after);
    notifyListeners();
  }

  /// Undo's and Redo's steps forgotten.
  void forgetUndo() {
    _undo.clear();
    _redo.clear();
    _last = null;
  }

  /// [selection] after [start] to [end] was replaced by [replacement]:
  /// before it, where it was; after it, moved along; in it, after it.
  static TextSelection _moved(
    TextSelection selection,
    int start,
    int end,
    String replacement,
  ) {
    if (!selection.isValid) return selection;
    int moved(int offset) {
      if (offset <= start) return offset;
      if (offset >= end) return offset + replacement.length - (end - start);
      return start + replacement.length;
    }

    return selection.copyWith(
      baseOffset: moved(selection.baseOffset),
      extentOffset: moved(selection.extentOffset),
    );
  }

  _Step? _group;

  /// The edits [edits] makes, one step of Undo's.
  void group(void Function() edits) {
    if (_group != null || _grouping) {
      edits();
      return;
    }
    if (_source != null) {
      _grouping = true;
      _groupStarted = false;
      try {
        edits();
      } finally {
        _grouping = false;
        _last = null;
      }
      return;
    }
    final step = _group = _Step(
      [],
      selection,
      selection,
      MdEditKind.other,
      DateTime.now(),
    );
    try {
      edits();
    } finally {
      _group = null;
      if (step.edits.isNotEmpty) {
        _redo.clear();
        _undo.add(step..after = selection);
        if (_undo.length > 500) _undo.removeAt(0);
      }
    }
  }

  // --- A source's ---------------------------------------------------------------

  bool _grouping = false;
  bool _groupStarted = false;

  /// The last edit made in the source, to join typing on to it.
  ({int start, int end, MdEditKind kind, DateTime at})? _last;

  /// Whether an edit in the source is part of the step before: one of a
  /// [group] after its first, typing (or deleting) where the last ended, a
  /// moment apart.
  bool _joins(int start, int end, String replacement, MdEditKind kind) {
    final now = DateTime.now();
    final last = _last;
    _last = (
      start: start,
      end: start + replacement.length,
      kind: kind,
      at: now,
    );
    if (_grouping) {
      final joins = _groupStarted;
      _groupStarted = true;
      return joins;
    }
    return last != null &&
        kind != MdEditKind.other &&
        last.kind == kind &&
        now.difference(last.at) < _joinWithin &&
        !replacement.contains('\n') &&
        start <= last.end &&
        end >= last.start;
  }

  /// The source's text changed: what changed read again. Another's change
  /// moves the selection along.
  void _sourceChanged(List<MdTextEdit> edits) {
    if (edits.isEmpty) return;
    var selection = this.selection;
    for (final edit in edits) {
      _apply(edit.start, edit.end, edit.text);
      if (!_editing && selection.isValid) {
        int moved(int offset) {
          if (offset <= edit.start) return offset;
          if (offset >= edit.end) {
            return offset + edit.text.length - (edit.end - edit.start);
          }
          return edit.start + edit.text.length;
        }

        selection = selection.copyWith(
          baseOffset: moved(selection.baseOffset),
          extentOffset: moved(selection.extentOffset),
        );
      }
    }
    if (_editing) return;
    _last = null;
    _composing = TextRange.empty;
    _selection.value = _clamp(selection);
    notifyListeners();
  }

  void _apply(int start, int end, String replacement) {
    final splice = _lines.replace(start, end, replacement);
    final parsed = _blocks.update(splice);
    if (_inlines.length > 2 * _lines.lineCount + 64) _pruneInlines();
    _textVersion++;
    _lastChange = MdChange(start, end, replacement, splice, parsed);
  }

  void _pruneInlines() {
    final ids = {for (var i = 0; i < _lines.lineCount; i++) _lines.idOf(i)};
    _inlines.removeWhere((id, _) => !ids.contains(id));
  }

  /// The whole text replaced by [text] (another's change of the file): a
  /// step Undo takes back, the selection kept where it can be.
  set text(String text) {
    final old = this.text;
    if (old == text) return;
    // Only what differs replaced: the lines around it stay as they were.
    var start = 0;
    final shorter = old.length < text.length ? old.length : text.length;
    while (start < shorter && old.codeUnitAt(start) == text.codeUnitAt(start)) {
      start++;
    }
    var end = 0;
    while (end < shorter - start &&
        old.codeUnitAt(old.length - 1 - end) ==
            text.codeUnitAt(text.length - 1 - end)) {
      end++;
    }
    replace(
      start,
      old.length - end,
      text.substring(start, text.length - end),
      selection: selection,
    );
  }

  // --- Undo ------------------------------------------------------------------

  final List<_Step> _undo = [];
  final List<_Step> _redo = [];

  static const _joinWithin = Duration(milliseconds: 1000);

  bool get canUndo => _source?.canUndo ?? _undo.isNotEmpty;
  bool get canRedo => _source?.canRedo ?? _redo.isNotEmpty;

  /// The source's [undo] or [redo]: its changes shown as they come, then
  /// the selection it kept.
  bool _sourceStep(MarkdownTextSource source, {required bool redo}) {
    _last = null;
    if (!(redo ? source.redo() : source.undo())) return false;
    _composing = TextRange.empty;
    if (source.restoredSelection case final selection?) {
      this.selection = selection;
    }
    return true;
  }

  void _record(
    int start,
    String removed,
    String inserted,
    TextSelection before,
    TextSelection after,
    MdEditKind kind,
  ) {
    _redo.clear();
    final now = DateTime.now();
    final last = _undo.lastOrNull;
    final edit = last != null && last.edits.length == 1 ? last.edits[0] : null;
    if (last != null &&
        edit != null &&
        kind != MdEditKind.other &&
        last.kind == kind &&
        now.difference(last.at) < _joinWithin) {
      // Typed on where the last typing ended.
      if (kind == MdEditKind.typing &&
          removed.isEmpty &&
          start == edit.start + edit.inserted.length &&
          !inserted.contains('\n')) {
        edit.inserted += inserted;
        last
          ..after = after
          ..at = now;
        return;
      }
      // An input method's composing text replaced as it is composed.
      if (kind == MdEditKind.typing &&
          start >= edit.start &&
          start + removed.length <= edit.start + edit.inserted.length) {
        final from = start - edit.start;
        edit.inserted = edit.inserted.replaceRange(
          from,
          from + removed.length,
          inserted,
        );
        last
          ..after = after
          ..at = now;
        return;
      }
      // Deleted on backwards (or forwards) from where the last deleting
      // was.
      if (kind == MdEditKind.deleting && inserted.isEmpty) {
        if (start + removed.length == edit.start) {
          _undo[_undo.length - 1] = _Step(
            [_Edit(start, removed + edit.removed, edit.inserted)],
            last.before,
            after,
            kind,
            now,
          );
          return;
        }
        if (start == edit.start) {
          edit.removed += removed;
          last
            ..after = after
            ..at = now;
          return;
        }
      }
    }
    _undo.add(
      _Step([_Edit(start, removed, inserted)], before, after, kind, now),
    );
    if (_undo.length > 500) _undo.removeAt(0);
  }

  /// Takes back the last step; false when there was none.
  bool undo() {
    if (_source case final source?) return _sourceStep(source, redo: false);
    if (_undo.isEmpty) return false;
    final step = _undo.removeLast();
    for (final edit in step.edits.reversed) {
      _apply(edit.start, edit.start + edit.inserted.length, edit.removed);
    }
    _redo.add(step);
    _composing = TextRange.empty;
    _selection.value = _clamp(step.before);
    notifyListeners();
    return true;
  }

  /// Does again the last step taken back; false when there was none.
  bool redo() {
    if (_source case final source?) return _sourceStep(source, redo: true);
    if (_redo.isEmpty) return false;
    final step = _redo.removeLast();
    for (final edit in step.edits) {
      _apply(edit.start, edit.start + edit.removed.length, edit.inserted);
    }
    _undo.add(step);
    _composing = TextRange.empty;
    _selection.value = _clamp(step.after);
    notifyListeners();
    return true;
  }

  /// The next edit starts a step of its own.
  void breakUndo() {
    _undo.lastOrNull?.at = DateTime.fromMillisecondsSinceEpoch(0);
    _last = null;
    _source?.breakStep();
  }

  @override
  void dispose() {
    _stopListening?.call();
    _selection.dispose();
    super.dispose();
  }
}
