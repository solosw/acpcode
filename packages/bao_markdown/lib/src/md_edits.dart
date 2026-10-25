import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

import 'md_blocks.dart';
import 'md_controller.dart';
import 'md_inline.dart';

/// The edits keys make: Enter going on a list, Backspace taking an
/// item's bullet away, Tab nesting an item…, all of them in the markdown.
extension MarkdownEditing on MarkdownController {
  /// Where [line]'s text starts as it shows: after the marks never shown
  /// (a quote's `>`, an item's bullet and task box, the spaces before a
  /// paragraph's text, a fence's indent).
  int textStartOf(int line) {
    final info = infoOf(line);
    return switch (info.kind) {
      MdLineKind.paragraph ||
      MdLineKind.item ||
      MdLineKind.footnote ||
      MdLineKind.fence ||
      MdLineKind.fenceOpen ||
      MdLineKind.fenceClose ||
      MdLineKind.indentedCode => info.contentStart,
      MdLineKind.heading when info.setext => info.contentStart,
      MdLineKind.heading ||
      MdLineKind.blank ||
      MdLineKind.rule ||
      MdLineKind.setextUnderline => info.quoteEnd,
      _ => 0,
    };
  }

  /// Enter: a line after the caret's, going on with its list or quote
  /// ([plain]: a line, nothing more).
  void insertNewline({bool plain = false}) {
    plain = plain || this.plain;
    final selection = this.selection;
    if (!selection.isValid) return;
    final start = selection.start;
    final end = selection.end;
    final newline = lines.newline;
    final line = lineAt(start);
    final info = infoOf(line);
    final text = lines.content(line);
    final from = lineStart(line);
    final sameLine = end <= lineEnd(line);
    void insert(String inserted, {int? at}) => replace(
      at ?? start,
      at ?? end,
      inserted,
      selection: TextSelection.collapsed(
        offset: (at ?? start) + inserted.length,
      ),
    );

    if (!plain && sameLine) {
      switch (info.kind) {
        // An opened fence closed at once, the caret in it.
        case MdLineKind.fenceOpen when end == lineEnd(line):
          final (_, last) = blockOf(line);
          if (infoOf(last).kind != MdLineKind.fenceClose) {
            final indent = text.substring(0, info.contentStart);
            final fence = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(text)![1]!;
            replace(
              start,
              end,
              '$newline$indent$newline$indent$fence',
              selection: TextSelection.collapsed(
                offset: start + newline.length + indent.length,
              ),
            );
            return;
          }
        // An empty last line of a fence: out of it, under it.
        case MdLineKind.fence
            when text.trim().isEmpty &&
                selection.isCollapsed &&
                line + 1 < lines.lineCount &&
                infoOf(line + 1).kind == MdLineKind.fenceClose:
          final at = lineEnd(line - 1);
          final close = lines.content(line + 1);
          final inserted = '$newline$close$newline';
          replace(
            at,
            lineEnd(line + 1),
            inserted,
            selection: TextSelection.collapsed(offset: at + inserted.length),
          );
          return;
        // Code goes on as far in as its line is.
        case MdLineKind.fence || MdLineKind.indentedCode:
          final indent = RegExp(r'^\s*').stringMatch(text)!;
          insert(
            '$newline${indent.substring(0, math.min(indent.length, start - from))}',
          );
          return;
        case MdLineKind.item:
          if (text.substring(info.contentStart).trim().isEmpty) {
            // An empty item: a level out, or out of the list.
            if (info.level > 0 && outdent()) return;
            replace(
              from + info.quoteEnd,
              from + text.length,
              '',
              selection: TextSelection.collapsed(offset: from + info.quoteEnd),
            );
            return;
          }
          final at = math.max(start, from + info.contentStart);
          final inserted = '$newline${_nextItem(text, info)}';
          group(() {
            replace(
              at,
              end,
              inserted,
              selection: TextSelection.collapsed(offset: at + inserted.length),
            );
            if (info.ordered) _renumber(line + 1);
          });
          return;
        case MdLineKind.paragraph || MdLineKind.blank when info.quoteDepth > 0:
          if (text.substring(info.quoteEnd).trim().isEmpty) {
            // An empty quoted line ends the quote.
            replace(
              from,
              from + text.length,
              '',
              selection: TextSelection.collapsed(offset: from),
            );
            return;
          }
          var marks = text.substring(0, info.quoteEnd);
          if (!marks.endsWith(' ')) marks = '$marks ';
          insert('$newline$marks');
          return;
        // Before a heading's text: a line over it, the caret kept in it.
        case MdLineKind.heading
            when !info.setext &&
                selection.isCollapsed &&
                start - from <= info.contentStart &&
                info.contentEnd > info.contentStart:
          replace(
            from,
            from,
            newline,
            selection: TextSelection.collapsed(offset: start + newline.length),
          );
          return;
        // An item's text's line goes on under it.
        case MdLineKind.paragraph when info.level > 0:
          insert('$newline${text.substring(0, info.contentStart)}');
          return;
        default:
      }
    }
    insert(newline);
  }

  /// What starts the item after [info]'s (`2.` after `1.`, a task's box
  /// empty).
  String _nextItem(String text, MdLineInfo info) {
    var marker = text.substring(info.markerStart, info.markerEnd);
    if (info.ordered) {
      final number = int.parse(marker.substring(0, marker.length - 1));
      marker = '${number + 1}${marker[marker.length - 1]}';
    }
    var spacing = text.substring(
      info.markerEnd,
      info.task > 0 ? info.taskStart : info.contentStart,
    );
    if (spacing.isEmpty) spacing = ' ';
    return '${text.substring(0, info.markerStart)}$marker$spacing'
        '${info.task > 0 ? '[ ] ' : ''}';
  }

  /// The ordered items from [line] on, of its list's level, numbered on
  /// from the one before them.
  void _renumber(int line) {
    if (line <= 0 || line >= lines.lineCount) return;
    final first = infoOf(line);
    if (first.kind != MdLineKind.item || !first.ordered) return;
    final level = first.level;
    var number = -1;
    for (var i = line - 1; i >= 0; i--) {
      final info = infoOf(i);
      if (info.kind == MdLineKind.item && info.level == level) {
        if (!info.ordered) return;
        final text = lines.content(i);
        number = int.parse(
          text.substring(info.markerStart, info.markerEnd - 1),
        );
        break;
      }
    }
    if (number < 0) return;
    final kept = selection;
    for (var i = line; i < lines.lineCount; i++) {
      final info = infoOf(i);
      if (info.kind == MdLineKind.item && info.level < level) break;
      if (info.kind != MdLineKind.item &&
          !(info.kind == MdLineKind.paragraph && info.level > level)) {
        if (info.kind == MdLineKind.blank) continue;
        break;
      }
      if (info.kind != MdLineKind.item || info.level != level) continue;
      if (!info.ordered) break;
      number++;
      final text = lines.content(i);
      final written = text.substring(info.markerStart, info.markerEnd - 1);
      if (written == '$number') continue;
      final at = lineStart(i) + info.markerStart;
      replace(
        at,
        at + written.length,
        '$number',
        selection: _shifted(kept, at, written.length, '$number'.length),
      );
    }
  }

  static TextSelection _shifted(
    TextSelection selection,
    int at,
    int removed,
    int inserted,
  ) {
    int shift(int offset) => offset <= at
        ? offset
        : offset >= at + removed
        ? offset - removed + inserted
        : at + inserted;
    return selection.copyWith(
      baseOffset: shift(selection.baseOffset),
      extentOffset: shift(selection.extentOffset),
    );
  }

  /// Backspace: the selection deleted, or what is before the caret (an
  /// item's bullet at its text's start, a picture all of it, at a line's
  /// start the line joined to the one before).
  void deleteBackward({bool Function(MdInline run, String line)? isAtomic}) {
    final selection = this.selection;
    if (!selection.isValid) return;
    if (!selection.isCollapsed) {
      replace(selection.start, selection.end, '', kind: MdEditKind.deleting);
      return;
    }
    final at = selection.extentOffset;
    final line = lineAt(at);
    final from = lineStart(line);
    final column = at - from;
    final info = infoOf(line);
    final textStart = textStartOf(line);
    if (column <= textStart) {
      if (column == info.contentStart && _deleteMarks(line)) return;
      if (line == 0) return;
      // Joined to the line before, what is never shown before its text
      // gone with the line's end.
      final end = lineEnd(line - 1);
      replace(
        end,
        from + textStart,
        '',
        selection: TextSelection.collapsed(offset: end),
        kind: MdEditKind.deleting,
      );
      return;
    }
    final text = lines.content(line);
    for (final run in inlinesOf(line)) {
      if (run.end == column && (isAtomic?.call(run, text) ?? run.atomic)) {
        replace(from + run.start, at, '', kind: MdEditKind.deleting);
        return;
      }
    }
    final range = CharacterRange.at(text, column)..moveBack();
    final previous = column - range.current.length;
    replace(
      from + math.max(previous, textStart),
      at,
      '',
      kind: MdEditKind.deleting,
    );
  }

  /// Delete: the selection deleted, or what is after the caret (a
  /// picture all of it; at a line's end the next line joined to it).
  void deleteForward({bool Function(MdInline run, String line)? isAtomic}) {
    final selection = this.selection;
    if (!selection.isValid) return;
    if (!selection.isCollapsed) {
      replace(selection.start, selection.end, '', kind: MdEditKind.deleting);
      return;
    }
    final at = selection.extentOffset;
    final line = lineAt(at);
    final from = lineStart(line);
    final column = at - from;
    final text = lines.content(line);
    if (column >= text.length) {
      if (line + 1 >= lines.lineCount) return;
      replace(
        at,
        lineStart(line + 1) + textStartOf(line + 1),
        '',
        selection: TextSelection.collapsed(offset: at),
        kind: MdEditKind.deleting,
      );
      return;
    }
    for (final run in inlinesOf(line)) {
      if (run.start == column && (isAtomic?.call(run, text) ?? run.atomic)) {
        replace(
          at,
          from + run.end,
          '',
          selection: TextSelection.collapsed(offset: at),
          kind: MdEditKind.deleting,
        );
        return;
      }
    }
    final range = CharacterRange.at(text, column)..moveNext();
    replace(
      at,
      at + range.current.length,
      '',
      selection: TextSelection.collapsed(offset: at),
      kind: MdEditKind.deleting,
    );
  }

  /// Backspace at [line]'s text's start: its bullet taken away (a level
  /// out where it is nested), a quote's `>`.
  bool _deleteMarks(int line) {
    final info = infoOf(line);
    final from = lineStart(line);
    final text = lines.content(line);
    if (info.kind == MdLineKind.item) {
      if (info.level > 0) return outdent();
      replace(
        from + info.quoteEnd,
        from + info.contentStart,
        '',
        selection: TextSelection.collapsed(offset: from + info.quoteEnd),
        kind: MdEditKind.other,
      );
      return true;
    }
    if (info.quoteDepth > 0 && info.contentStart <= info.quoteEnd + 3) {
      final marks = text.substring(0, info.quoteEnd);
      final last = marks.lastIndexOf('>');
      final cut = last + 1 < marks.length && marks[last + 1] == ' '
          ? last + 2
          : last + 1;
      replace(
        from + last,
        from + cut,
        '',
        selection: TextSelection.collapsed(
          offset: from + info.contentStart - (cut - last),
        ),
      );
      return true;
    }
    return false;
  }

  /// The items the selection is in, a level in (under the item before
  /// them); false where there are none, or none can be.
  bool indent() => _nest(true);

  /// The items the selection is in, a level out.
  bool outdent() => _nest(false);

  bool _nest(bool inward) {
    final selection = this.selection;
    final first = lineAt(selection.start);
    final last = lineAt(selection.end);
    final edits = <(int, int, String)>[];
    for (var line = first; line <= last; line++) {
      final info = infoOf(line);
      if (info.kind != MdLineKind.item) continue;
      final target = inward ? _siblingColumn(line) : _parentColumn(line);
      if (target == null) continue;
      final from = lineStart(line);
      edits.add((from + info.quoteEnd, from + info.markerStart, ' ' * target));
    }
    if (edits.isEmpty) return false;
    group(() {
      var kept = this.selection;
      for (final (start, end, spaces) in edits.reversed) {
        kept = _shifted(kept, start, end - start, spaces.length);
        replace(start, end, spaces, selection: kept);
      }
    });
    return true;
  }

  /// Where the text of the item before [line]'s, of its level, starts
  /// (from the quote's marks): an item nested under it is as far in.
  int? _siblingColumn(int line) {
    final level = infoOf(line).level;
    for (var i = line - 1; i >= 0; i--) {
      final info = infoOf(i);
      if (info.kind == MdLineKind.item) {
        if (info.level < level) return null;
        if (info.level == level) {
          return (info.task > 0 ? info.taskStart : info.contentStart) -
              info.quoteEnd;
        }
        continue;
      }
      if (info.kind == MdLineKind.paragraph && info.level > 0) continue;
      if (info.isFence && info.level > 0) continue;
      if (info.kind == MdLineKind.blank) continue;
      return null;
    }
    return null;
  }

  /// Where the bullet of the item [line]'s is nested in is.
  int? _parentColumn(int line) {
    final level = infoOf(line).level;
    if (level == 0) return null;
    for (var i = line - 1; i >= 0; i--) {
      final info = infoOf(i);
      if (info.kind == MdLineKind.item && info.level < level) {
        return info.markerStart - info.quoteEnd;
      }
    }
    return 0;
  }

  /// [line]'s task ticked, or not.
  void toggleTask(int line) {
    final info = infoOf(line);
    if (info.kind != MdLineKind.item || info.task == 0) return;
    final at = lineStart(line) + info.taskStart + 1;
    replace(at, at + 1, info.task == 1 ? 'x' : ' ', selection: selection);
  }

  /// After a space typed: `[] ` (or `[ ] `) at a line's start makes it a
  /// task. True where it did.
  bool expandTyped() {
    final selection = this.selection;
    if (plain || !selection.isCollapsed) return false;
    final at = selection.extentOffset;
    final line = lineAt(at);
    final info = infoOf(line);
    if (info.kind != MdLineKind.paragraph) return false;
    final from = lineStart(line);
    final typed = lines.content(line).substring(info.contentStart, at - from);
    if (typed != '[] ' && typed != '[ ] ') return false;
    replace(
      from + info.contentStart,
      at,
      '- [ ] ',
      selection: TextSelection.collapsed(offset: from + info.contentStart + 6),
    );
    return true;
  }
}
