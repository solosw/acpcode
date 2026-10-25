import 'package:flutter/foundation.dart';

import 'md_lines.dart';

/// What a line of the markdown is, as CommonMark (with GitHub's tables
/// and tasks, and `$$` math) reads it, line for line: each line is shown
/// as a line, as written.
enum MdLineKind {
  blank,
  paragraph,
  heading,

  /// The `===` or `---` under a heading's line.
  setextUnderline,
  item,
  rule,
  fenceOpen,
  fence,
  fenceClose,
  indentedCode,
  tableHead,
  tableDelimiter,
  tableRow,
  mathOpen,
  math,
  mathClose,

  /// `$$…$$` on one line.
  mathLine,
  html,
  frontMatter,

  /// `[^1]: …`.
  footnote,

  /// `[label]: url`.
  definition,
}

/// A line's kind, and where its marks and its text are (columns of the
/// line, its `\r` left out).
@immutable
class MdLineInfo {
  const MdLineInfo(
    this.kind, {
    this.quoteDepth = 0,
    this.quoteEnd = 0,
    this.level = 0,
    this.markerStart = 0,
    this.markerEnd = 0,
    this.ordered = false,
    this.task = 0,
    this.taskStart = 0,
    required this.contentStart,
    required this.contentEnd,
    this.language,
    this.setext = false,
  });

  final MdLineKind kind;

  /// How many `>` it is quoted in, and where they (and a space after
  /// them) end.
  final int quoteDepth;
  final int quoteEnd;

  /// A heading's (1 to 6); an item's or a list's line's nesting (from 0).
  final int level;

  /// An item's marker (`-`, `1.`…).
  final int markerStart;
  final int markerEnd;
  final bool ordered;

  /// An item's task box: 0 for none, 1 open, 2 done; where its `[` is.
  final int task;
  final int taskStart;

  /// Where the text its marks are around starts and ends.
  final int contentStart;
  final int contentEnd;

  /// A code fence's.
  final String? language;

  /// A heading made by the line under it.
  final bool setext;

  bool get isFence =>
      kind == MdLineKind.fenceOpen ||
      kind == MdLineKind.fence ||
      kind == MdLineKind.fenceClose;

  bool get isTable =>
      kind == MdLineKind.tableHead ||
      kind == MdLineKind.tableDelimiter ||
      kind == MdLineKind.tableRow;

  bool get isMath =>
      kind == MdLineKind.mathOpen ||
      kind == MdLineKind.math ||
      kind == MdLineKind.mathClose;

  /// A line of a block the lines of which go together (shown as one where
  /// the caret is not): a fence, a table, math, HTML, front matter.
  bool get isMultiline =>
      isFence ||
      isTable ||
      isMath ||
      kind == MdLineKind.html ||
      kind == MdLineKind.frontMatter;

  /// Its text is markdown, marks and all (not code, nor a table's source).
  bool get hasInline =>
      kind == MdLineKind.paragraph ||
      kind == MdLineKind.heading ||
      kind == MdLineKind.item ||
      kind == MdLineKind.footnote;

  @override
  bool operator ==(Object other) =>
      other is MdLineInfo &&
      other.kind == kind &&
      other.quoteDepth == quoteDepth &&
      other.quoteEnd == quoteEnd &&
      other.level == level &&
      other.markerStart == markerStart &&
      other.markerEnd == markerEnd &&
      other.ordered == ordered &&
      other.task == task &&
      other.taskStart == taskStart &&
      other.contentStart == contentStart &&
      other.contentEnd == contentEnd &&
      other.language == language &&
      other.setext == setext;

  @override
  int get hashCode => Object.hash(
    kind,
    quoteDepth,
    quoteEnd,
    level,
    markerStart,
    markerEnd,
    ordered,
    task,
    taskStart,
    contentStart,
    contentEnd,
    language,
    setext,
  );

  @override
  String toString() => 'MdLineInfo($kind, $contentStart-$contentEnd)';
}

/// What a line leaves open for the next: a fence, math, HTML, a table, a
/// list's items.
@immutable
class _State {
  const _State({
    this.fenceChar = 0,
    this.fenceLength = 0,
    this.fenceIndent = 0,
    this.language,
    this.math = false,
    this.html = 0,
    this.table = false,
    this.tableHead = false,
    this.indentedCode = false,
    this.lists = const [],
    this.paragraph = false,
  });

  final int fenceChar;
  final int fenceLength;
  final int fenceIndent;
  final String? language;
  final bool math;

  /// 0 none; 1 until a blank line; 2 until `-->`; 3 until its closing tag
  /// (`</script>`, `</pre>`, `</style>`, `</textarea>`).
  final int html;
  final bool table;
  final bool tableHead;
  final bool indentedCode;

  /// The columns the open list items' text starts at.
  final List<int> lists;

  /// The line was a paragraph's.
  final bool paragraph;

  static const empty = _State();

  @override
  bool operator ==(Object other) =>
      other is _State &&
      other.fenceChar == fenceChar &&
      other.fenceLength == fenceLength &&
      other.fenceIndent == fenceIndent &&
      other.language == language &&
      other.math == math &&
      other.html == html &&
      other.table == table &&
      other.tableHead == tableHead &&
      other.indentedCode == indentedCode &&
      listEquals(other.lists, lists) &&
      other.paragraph == paragraph;

  @override
  int get hashCode => Object.hash(
    fenceChar,
    fenceLength,
    fenceIndent,
    language,
    math,
    html,
    table,
    tableHead,
    indentedCode,
    Object.hashAll(lists),
    paragraph,
  );
}

/// The lines' kinds, kept as the lines are edited: an edit parses again
/// from the line before it on, only until the lines after it read as they
/// did.
class MdBlocks {
  MdBlocks(this._lines, {this.plain = false}) {
    _parseAll();
  }

  final MdLines _lines;

  /// Not markdown: every line a paragraph of text as it is (its atoms
  /// aside, see [MdAtoms]).
  final bool plain;
  final List<MdLineInfo> _infos = [];
  final List<_State> _after = [];

  /// The link definitions (`[label]: url`), by their labels in lower case.
  Map<String, String> get definitions => _definitions;
  Map<String, String> _definitions = const {};

  /// Changes when [definitions] do.
  int get definitionsVersion => _definitionsVersion;
  int _definitionsVersion = 0;

  /// The front matter's last line; -1 for none.
  int _frontMatterEnd = -1;

  MdLineInfo info(int line) => _infos[line];

  int get length => _infos.length;

  /// The lines parsed again after [splice]: from the first to the last
  /// whose kind (or what they leave open) may have changed.
  (int, int) update(MdSplice splice) {
    final removedEnd = splice.first + splice.removed;
    final insertedEnd = splice.first + splice.inserted;
    // Kept, the old lines' after the edit, to tell where they read the same.
    final oldInfos = _infos.sublist(removedEnd);
    final oldAfter = _after.sublist(removedEnd);
    _infos.removeRange(splice.first, _infos.length);
    _after.removeRange(splice.first, _after.length);
    final frontMatterEnd = _findFrontMatterEnd();
    // Front matter is read to its end at once: an edit near it, all again.
    if (frontMatterEnd != _frontMatterEnd ||
        (frontMatterEnd >= 0 && splice.first <= frontMatterEnd + 1)) {
      _frontMatterEnd = frontMatterEnd;
      _infos.clear();
      _after.clear();
      _parseAll();
      return (0, _infos.length - 1);
    }
    // The line before may be a heading by the line under it, or a table's
    // head by its delimiter row.
    var from = splice.first;
    if (from > 0) {
      from--;
      _infos.removeLast();
      _after.removeLast();
    }
    var state = from == 0 ? _State.empty : _after[from - 1];
    final count = _lines.lineCount;
    for (var i = from; i < count; i++) {
      final (info, next) = _parse(i, state);
      _infos.add(info);
      _after.add(next);
      state = next;
      // Past the edit (and so is the line after it, which this one may
      // look at), read as it was, leaving open what it did: the rest is
      // as it was too.
      final old = i - insertedEnd;
      if (old >= 0 &&
          old < oldInfos.length &&
          oldInfos[old] == info &&
          oldAfter[old] == next) {
        _infos.addAll(oldInfos.sublist(old + 1));
        _after.addAll(oldAfter.sublist(old + 1));
        _checkDefinitions();
        return (from, i);
      }
    }
    _checkDefinitions();
    return (from, count - 1);
  }

  void _parseAll() {
    _frontMatterEnd = _findFrontMatterEnd();
    var state = _State.empty;
    for (var i = 0; i < _lines.lineCount; i++) {
      final (info, next) = _parse(i, state);
      _infos.add(info);
      _after.add(next);
      state = next;
    }
    _checkDefinitions();
  }

  /// Gathers the definitions again.
  void _checkDefinitions() {
    final definitions = <String, String>{};
    for (var i = 0; i < _infos.length; i++) {
      if (_infos[i].kind != MdLineKind.definition) continue;
      final match = _definition.firstMatch(_lines.content(i));
      if (match == null) continue;
      definitions.putIfAbsent(match[1]!.toLowerCase(), () => match[2]!);
    }
    if (!mapEquals(definitions, _definitions)) {
      _definitions = definitions;
      _definitionsVersion++;
    }
  }

  int _findFrontMatterEnd() {
    if (plain || _lines.lineCount < 2 || _lines.content(0) != '---') return -1;
    for (var i = 1; i < _lines.lineCount; i++) {
      final line = _lines.content(i);
      if (line == '---' || line == '...') return i;
    }
    return -1;
  }

  (MdLineInfo, _State) _parse(int index, _State state) {
    final text = _lines.content(index);
    final length = text.length;
    MdLineInfo whole(MdLineKind kind, {String? language, int level = 0}) =>
        MdLineInfo(
          kind,
          contentStart: 0,
          contentEnd: length,
          language: language,
          level: level,
        );
    if (plain) return (whole(MdLineKind.paragraph), _State.empty);
    final lists = state.lists;

    if (index <= _frontMatterEnd) {
      return (whole(MdLineKind.frontMatter), _State.empty);
    }

    // Inside a fence: its lines, until one closes it; as far in as it is
    // (in a list's item), the fence's indent theirs.
    if (state.fenceChar != 0) {
      MdLineInfo fenceLine(MdLineKind kind) => MdLineInfo(
        kind,
        level: _levelAt(lists, state.fenceIndent),
        contentStart: leadingSpaces(text).clamp(0, state.fenceIndent),
        contentEnd: length,
        language: state.language,
      );
      final close = _fenceClose.firstMatch(text);
      if (close != null &&
          close[2]!.codeUnitAt(0) == state.fenceChar &&
          close[2]!.length >= state.fenceLength) {
        return (fenceLine(MdLineKind.fenceClose), _State(lists: lists));
      }
      return (fenceLine(MdLineKind.fence), state);
    }
    if (state.math) {
      if (text.trimRight().endsWith(r'$$')) {
        return (whole(MdLineKind.mathClose), _State(lists: lists));
      }
      return (whole(MdLineKind.math), state);
    }
    if (state.html != 0) {
      final ended = switch (state.html) {
        1 => text.trim().isEmpty,
        2 => text.contains('-->'),
        _ => _rawClose.hasMatch(text),
      };
      if (ended && state.html == 1) {
        return (
          MdLineInfo(MdLineKind.blank, contentStart: 0, contentEnd: length),
          _State(lists: lists),
        );
      }
      return (whole(MdLineKind.html), ended ? _State(lists: lists) : state);
    }

    // Quotes, then what is quoted.
    var quoteDepth = 0;
    var quoteEnd = 0;
    while (true) {
      final quote = _quote.firstMatch(text.substring(quoteEnd));
      if (quote == null) break;
      quoteDepth++;
      quoteEnd += quote[0]!.length;
    }
    final rest = text.substring(quoteEnd);
    final indent = _indentOf(rest);
    final trimmed = rest.trim();

    MdLineInfo line(
      MdLineKind kind, {
      int contentStart = -1,
      int contentEnd = -1,
      int level = 0,
      bool setext = false,
    }) => MdLineInfo(
      kind,
      quoteDepth: quoteDepth,
      quoteEnd: quoteEnd,
      level: level,
      contentStart: contentStart < 0 ? quoteEnd : contentStart,
      contentEnd: contentEnd < 0 ? length : contentEnd,
      setext: setext,
    );

    if (trimmed.isEmpty) {
      // A blank line ends a table, indented code, a paragraph; not a list.
      return (
        line(MdLineKind.blank, contentStart: length),
        _State(lists: quoteDepth > 0 ? const [] : lists),
      );
    }

    // A table's rows go on until a blank line.
    if (state.tableHead &&
        quoteDepth == 0 &&
        rest.contains('|') &&
        _delimiterRow.hasMatch(rest)) {
      return (
        whole(MdLineKind.tableDelimiter),
        _State(table: true, lists: lists),
      );
    }
    if (state.table && quoteDepth == 0 && !_blockStart.hasMatch(rest)) {
      return (whole(MdLineKind.tableRow), state);
    }

    // Indented code: four spaces, not in a list, not after a paragraph.
    if (quoteDepth == 0 &&
        indent >= 4 &&
        lists.isEmpty &&
        (state.indentedCode || !state.paragraph)) {
      return (whole(MdLineKind.indentedCode), const _State(indentedCode: true));
    }

    if (_heading.firstMatch(rest) case final heading?) {
      final level = heading[1]!.length;
      var start = quoteEnd + heading[0]!.length;
      var end = length;
      // Closing `#`s are marks too.
      if (_closingHashes.firstMatch(text.substring(start)) case final close?) {
        end = start + close.start;
        if (end < start) end = start;
      }
      if (start > end) start = end;
      return (
        line(
          MdLineKind.heading,
          contentStart: start,
          contentEnd: end,
          level: level,
        ),
        _State(lists: quoteDepth > 0 ? lists : const []),
      );
    }

    if (quoteDepth == 0) {
      if (_fenceOpen.firstMatch(text) case final fence?) {
        final marker = fence[2]!;
        final info = fence[3]!.trim();
        if (marker[0] != '`' || !info.contains('`')) {
          final language = info.split(RegExp(r'\s')).first;
          final indent = fence[1]!.length;
          return (
            MdLineInfo(
              MdLineKind.fenceOpen,
              level: _levelAt(lists, indent),
              contentStart: indent,
              contentEnd: length,
              language: language,
            ),
            _State(
              fenceChar: marker.codeUnitAt(0),
              fenceLength: marker.length,
              fenceIndent: indent,
              language: language,
              lists: lists,
            ),
          );
        }
      }
      if (trimmed.startsWith(r'$$')) {
        if (trimmed.length >= 4 && trimmed.endsWith(r'$$')) {
          return (whole(MdLineKind.mathLine), _State(lists: lists));
        }
        return (whole(MdLineKind.mathOpen), _State(math: true, lists: lists));
      }
      final html = _htmlStart(rest, state.paragraph);
      if (html != 0) {
        final ended = switch (html) {
          2 => rest.contains('-->'),
          3 => _rawClose.hasMatch(rest),
          _ => false,
        };
        return (
          whole(MdLineKind.html),
          ended ? _State(lists: lists) : _State(html: html, lists: lists),
        );
      }
    }

    // `---` under a paragraph's line makes it a heading (see [_setext]).
    if (index > 0 &&
        _infos[index - 1].setext &&
        _setextUnderline.hasMatch(rest)) {
      return (
        line(MdLineKind.setextUnderline, contentStart: quoteEnd),
        _State(lists: lists),
      );
    }
    if (_rule.hasMatch(rest)) {
      return (line(MdLineKind.rule), _State(lists: lists));
    }

    if (_item.firstMatch(rest) case final item?) {
      final itemIndent = item[1]!.replaceAll('\t', '    ').length;
      final stack = [...lists];
      while (stack.isNotEmpty && stack.last > itemIndent) {
        stack.removeLast();
      }
      final level = stack.length;
      final markerStart = quoteEnd + item[1]!.length;
      final markerEnd = markerStart + item[2]!.length;
      var contentStart = markerEnd + item[3]!.length;
      var task = 0;
      var taskStart = 0;
      if (_task.firstMatch(text.substring(contentStart)) case final box?) {
        task = box[1] == ' ' ? 1 : 2;
        taskStart = contentStart;
        contentStart += box[0]!.length;
      }
      stack.add(itemIndent + item[2]!.length + item[3]!.length);
      return (
        MdLineInfo(
          MdLineKind.item,
          quoteDepth: quoteDepth,
          quoteEnd: quoteEnd,
          level: level,
          markerStart: markerStart,
          markerEnd: markerEnd,
          ordered: item[2]!.contains(RegExp(r'\d')),
          task: task,
          taskStart: taskStart,
          contentStart: contentStart,
          contentEnd: length,
        ),
        _State(lists: stack, paragraph: true),
      );
    }

    if (!state.paragraph && quoteDepth == 0) {
      if (_footnote.hasMatch(rest)) {
        return (
          line(
            MdLineKind.footnote,
            contentStart: quoteEnd + leadingSpaces(rest),
          ),
          _State(lists: lists),
        );
      }
      if (_definition.hasMatch(rest)) {
        return (whole(MdLineKind.definition), _State(lists: lists));
      }
    }

    // A table: a row, then its delimiter row.
    if (quoteDepth == 0 &&
        rest.contains('|') &&
        index + 1 < _lines.lineCount &&
        _lines.content(index + 1).contains('|') &&
        _delimiterRow.hasMatch(_lines.content(index + 1))) {
      return (whole(MdLineKind.tableHead), _State(tableHead: true));
    }

    // A paragraph's line: in the list items it is indented under.
    final stack = [...lists];
    while (stack.isNotEmpty && stack.last > indent) {
      stack.removeLast();
    }
    // Not indented under one (a lazy line) ends no list but goes on
    // the item's text.
    final level = stack.isEmpty ? 0 : stack.length;
    final kept = stack.isEmpty && lists.isNotEmpty && state.paragraph
        ? lists
        : stack;
    final start = quoteEnd + leadingSpaces(rest);
    final setext =
        index + 1 < _lines.lineCount &&
        _setextUnderline.hasMatch(_lines.content(index + 1)) &&
        !_isQuotedOrItem(_lines.content(index + 1));
    if (setext) {
      final next = _lines.content(index + 1);
      return (
        line(
          MdLineKind.heading,
          contentStart: start,
          level: next.trim().startsWith('=') ? 1 : 2,
          setext: true,
        ),
        _State(lists: kept, paragraph: true),
      );
    }
    return (
      line(MdLineKind.paragraph, contentStart: start, level: level),
      _State(lists: kept, paragraph: true),
    );
  }

  /// How deep in [lists] (their items' text columns) a line [indent]
  /// in is.
  static int _levelAt(List<int> lists, int indent) {
    var level = 0;
    for (final column in lists) {
      if (column <= indent && indent > 0) level++;
    }
    return level;
  }

  static bool _isQuotedOrItem(String line) =>
      _quote.hasMatch(line) || _item.hasMatch(line);

  static int _indentOf(String text) {
    var columns = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x20) {
        columns++;
      } else if (unit == 0x09) {
        columns += 4 - columns % 4;
      } else {
        break;
      }
    }
    return columns;
  }

  /// The leading whitespace's length in characters (not columns).
  static int leadingSpaces(String text) => text.length - text.trimLeft().length;

  /// The kind of HTML block [line] starts (see [_State.html]); 0 for none.
  static int _htmlStart(String line, bool afterParagraph) {
    if (_htmlComment.hasMatch(line)) return 2;
    if (_rawOpen.hasMatch(line)) return 3;
    if (_blockTag.hasMatch(line)) return 1;
    // A lone tag (not a picture's, which is the stash's way of sizing one)
    // starts one only where it does not go on a paragraph.
    if (!afterParagraph && _loneTag.hasMatch(line) && !_imgTag.hasMatch(line)) {
      return 1;
    }
    return 0;
  }

  static final _quote = RegExp(r'^ {0,3}> ?');
  static final _heading = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+|$)');
  static final _closingHashes = RegExp(r'(?:^|[ \t]+)#+[ \t]*$');
  static final _fenceOpen = RegExp(r'^(\s*)(`{3,}|~{3,})(.*)$');
  static final _fenceClose = RegExp(r'^(\s*)(`{3,}|~{3,})\s*$');
  static final _rule = RegExp(
    r'^ {0,3}((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})$',
  );
  static final _setextUnderline = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');
  static final _item = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])([ \t]+|$)');
  static final _task = RegExp(r'^\[([ xX])\](?:[ \t]+|$)');
  static final _footnote = RegExp(r'^ {0,3}\[\^[^\]\s]+\]:');
  static final _definition = RegExp(
    r'^ {0,3}\[((?!\^)[^\]]+)\]:[ \t]*<?([^\s>]+)>?',
  );
  static final _delimiterRow = RegExp(
    r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$',
  );
  static final _blockStart = RegExp(r'^ {0,3}(#{1,6}(\s|$)|>|`{3,}|~{3,})');
  static final _htmlComment = RegExp(r'^ {0,3}<!--');
  static final _rawOpen = RegExp(
    r'^ {0,3}<(script|pre|style|textarea)(\s|>|$)',
    caseSensitive: false,
  );
  static final _rawClose = RegExp(
    r'</(script|pre|style|textarea)>',
    caseSensitive: false,
  );
  static final _blockTag = RegExp(
    r'^ {0,3}</?(address|article|aside|base|basefont|blockquote|body|caption|'
    r'center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|'
    r'figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|'
    r'html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|'
    r'optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|'
    r'th|thead|title|tr|track|ul)(\s|/?>|$)',
    caseSensitive: false,
  );
  static final _loneTag = RegExp(
    r'^ {0,3}(<[A-Za-z][A-Za-z0-9-]*(\s+[^<>]*)?/?>|</[A-Za-z][A-Za-z0-9-]*\s*>)\s*$',
  );
  static final _imgTag = RegExp(r'^\s*<img\s', caseSensitive: false);
}
