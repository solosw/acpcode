import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'md_blocks.dart';
import 'md_controller.dart';
import 'md_inline.dart';

/// What a line is, as a bar's buttons set it.
enum MdLineFormat {
  paragraph,
  heading1,
  heading2,
  heading3,
  bullet,
  numbered,
  task,
  quote,
  code,
}

/// The marks a bar's buttons put around the selection, or take away.
extension MarkdownFormatting on MarkdownController {
  // --- Runs --------------------------------------------------------------------

  /// The parts of the selection in each line's text: (line, from, to),
  /// columns of the line.
  List<(int, int, int)> _segments(TextSelection selection) {
    final segments = <(int, int, int)>[];
    final first = lineAt(selection.start);
    var last = lineAt(selection.end);
    if (last > first && selection.end == lineStart(last)) last--;
    for (var line = first; line <= last; line++) {
      final info = infoOf(line);
      if (!info.hasInline) continue;
      final from = lineStart(line);
      final start = math.max(selection.start - from, info.contentStart);
      final end = math.min(selection.end - from, info.contentEnd);
      if (start > end) continue;
      segments.add((line, start, end));
    }
    return segments;
  }

  /// The runs (and those in them) of [kind] in [line] that [from] to [to]
  /// is in.
  List<MdInline> _runsAround(
    int line,
    int from,
    int to,
    bool Function(MdInline run) test,
  ) {
    final found = <MdInline>[];
    void visit(List<MdInline> runs) {
      for (final run in runs) {
        if (run.innerStart <= from && to <= run.innerEnd && test(run)) {
          found.add(run);
        }
        if (run.start <= from && to <= run.end) visit(run.children);
      }
    }

    visit(inlinesOf(line));
    return found;
  }

  static bool Function(MdInline) _test(MdInlineKind kind, {String? tag}) =>
      (run) => switch (kind) {
        MdInlineKind.strong =>
          run.kind == MdInlineKind.strong ||
              run.kind == MdInlineKind.strongEmphasis ||
              (run.kind == MdInlineKind.styleTag &&
                  (run.tag == 'b' || run.tag == 'strong')),
        MdInlineKind.emphasis =>
          run.kind == MdInlineKind.emphasis ||
              run.kind == MdInlineKind.strongEmphasis ||
              (run.kind == MdInlineKind.styleTag &&
                  (run.tag == 'i' || run.tag == 'em')),
        MdInlineKind.strike =>
          run.kind == MdInlineKind.strike ||
              (run.kind == MdInlineKind.styleTag &&
                  (run.tag == 's' || run.tag == 'del' || run.tag == 'strike')),
        MdInlineKind.styleTag =>
          run.kind == MdInlineKind.styleTag && (tag == null || run.tag == tag),
        MdInlineKind.link =>
          run.kind == MdInlineKind.link ||
              run.kind == MdInlineKind.autolink ||
              run.kind == MdInlineKind.url,
        _ => run.kind == kind,
      };

  /// Whether all the selection (where it is text) is [kind]'s (a style
  /// tag's: [tag]'s).
  bool isInline(MdInlineKind kind, {String? tag}) {
    final selection = this.selection;
    if (!selection.isValid) return false;
    final segments = _segments(selection);
    if (segments.isEmpty) return false;
    final test = _test(kind, tag: tag);
    return segments.every(
      (segment) =>
          _runsAround(segment.$1, segment.$2, segment.$3, test).isNotEmpty,
    );
  }

  static (String, String) _marks(MdInlineKind kind) => switch (kind) {
    MdInlineKind.strong => ('**', '**'),
    MdInlineKind.emphasis => ('*', '*'),
    MdInlineKind.strike => ('~~', '~~'),
    MdInlineKind.code => ('`', '`'),
    _ => throw ArgumentError.value(kind, 'kind'),
  };

  /// The selection made [kind] (bold, italic, struck, code), or not where
  /// it all is.
  void toggleInline(MdInlineKind kind) {
    final (open, close) = _marks(kind);
    _toggle(_test(kind), open, close);
  }

  /// The selection underlined (`<u>`), or not where it all is.
  void toggleUnderline() =>
      _toggle(_test(MdInlineKind.styleTag, tag: 'u'), '<u>', '</u>');

  void _toggle(bool Function(MdInline) test, String open, String close) {
    final selection = this.selection;
    if (!selection.isValid) return;
    final segments = _segments(selection);
    if (segments.isEmpty) return;
    final around = [
      for (final (line, from, to) in segments)
        _runsAround(line, from, to, test).lastOrNull,
    ];
    final remove = around.every((run) => run != null);
    final edits = <(int, int, String)>[];
    for (var i = 0; i < segments.length; i++) {
      final (line, from, to) = segments[i];
      final start = lineStart(line);
      if (remove) {
        final run = around[i]!;
        edits.add((start + run.start, start + run.innerStart, ''));
        edits.add((start + run.innerEnd, start + run.end, ''));
        continue;
      }
      // Not around the spaces at the ends: `** a **` is no run.
      final text = lines.content(line);
      var a = from;
      var b = to;
      while (a < b && text[a] == ' ') {
        a++;
      }
      while (b > a && text[b - 1] == ' ') {
        b--;
      }
      if (a == b && segments.length > 1) continue;
      edits.add((start + a, start + a, open));
      edits.add((start + b, start + b, close));
    }
    applyEdits(edits);
  }

  /// [edits] (start, end, text; of the text as it is now, in order, none
  /// in another), one step of Undo's: the selection kept on what it was
  /// on, what is put in at its ends left out of it (a caret put after what
  /// is put in at it first, before what is put in after).
  void applyEdits(List<(int, int, String)> edits) {
    if (edits.isEmpty) return;
    final sorted = [for (final (i, edit) in edits.indexed) (i, edit)]
      ..sort((a, b) {
        final order = a.$2.$1.compareTo(b.$2.$1);
        return order != 0 ? order : a.$1.compareTo(b.$1);
      });
    group(() {
      final kept = selection;
      var start = kept.start;
      var end = kept.end;
      for (final (_, (from, to, text)) in sorted.reversed) {
        start = _map(start, from, to, text.length, after: true);
        end = _map(end, from, to, text.length, after: false);
        if (end < start) end = start;
        final reversed = kept.baseOffset > kept.extentOffset;
        replace(
          from,
          to,
          text,
          selection: TextSelection(
            baseOffset: reversed ? end : start,
            extentOffset: reversed ? start : end,
          ),
        );
      }
    });
  }

  /// [offset] once [start] to [end] gave way to [inserted] characters:
  /// [after] what is put in where it is, or before it.
  static int _map(
    int offset,
    int start,
    int end,
    int inserted, {
    required bool after,
  }) {
    if (offset < start) return offset;
    if (offset > end) return offset - (end - start) + inserted;
    if (start == end) return after ? offset + inserted : offset;
    if (offset == start) return offset;
    if (offset == end) return start + inserted;
    return after ? start + inserted : start;
  }

  // --- Colors ------------------------------------------------------------------

  /// The `<span style>` the selection is all in: its colors.
  ({String? color, String? background}) colorsAt() {
    final selection = this.selection;
    final segments = selection.isValid ? _segments(selection) : const [];
    if (segments.isEmpty) return (color: null, background: null);
    final (line, from, to) = segments.first;
    final span = _runsAround(
      line,
      from,
      to,
      (run) =>
          run.kind == MdInlineKind.styleTag &&
          (run.color != null || run.background != null),
    ).lastOrNull;
    return (color: span?.color, background: span?.background);
  }

  /// The selection in a `<span>` of [color] (or [background]); a span
  /// already around it given them, a `null` taking one away.
  void setColor({
    String? color,
    String? background,
    bool setColor = true,
    bool setBackground = false,
  }) {
    final selection = this.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final edits = <(int, int, String)>[];
    for (final (line, from, to) in _segments(selection)) {
      if (from == to) continue;
      final start = lineStart(line);
      final span = _runsAround(
        line,
        from,
        to,
        (run) =>
            run.kind == MdInlineKind.styleTag &&
            (run.tag == 'span' || run.tag == 'font'),
      ).lastOrNull;
      final newColor = setColor ? color : span?.color;
      final newBackground = setBackground ? background : span?.background;
      final style = [
        if (newColor != null) 'color:$newColor',
        if (newBackground != null) 'background-color:$newBackground',
      ].join(';');
      if (span != null) {
        if (style.isEmpty) {
          edits.add((start + span.start, start + span.innerStart, ''));
          edits.add((start + span.innerEnd, start + span.end, ''));
        } else {
          edits.add((
            start + span.start,
            start + span.innerStart,
            '<span style="$style">',
          ));
        }
        continue;
      }
      if (style.isEmpty) continue;
      edits.add((start + from, start + from, '<span style="$style">'));
      edits.add((start + to, start + to, '</span>'));
    }
    applyEdits(edits);
  }

  // --- Links -------------------------------------------------------------------

  /// The link [offset] is in (or at an end of): its line, and it.
  (int, MdInline)? linkAt(int offset) {
    final line = lineAt(offset);
    final column = offset - lineStart(line);
    for (final run in inlinesAt(inlinesOf(line), column).reversed) {
      if (run.kind == MdInlineKind.link ||
          run.kind == MdInlineKind.autolink ||
          run.kind == MdInlineKind.url) {
        return (line, run);
      }
    }
    return null;
  }

  /// The selection linked to [href] (a link it is in, to it instead);
  /// null or empty: the link taken away, its text kept.
  void setLink(String? href) {
    final selection = this.selection;
    if (!selection.isValid) return;
    final found = linkAt(selection.start);
    if (found != null &&
        (selection.isCollapsed ||
            lineAt(selection.end) == found.$1 &&
                selection.end - lineStart(found.$1) <= found.$2.end)) {
      final (line, run) = found;
      final start = lineStart(line);
      final text = lines.content(line).substring(run.innerStart, run.innerEnd);
      final replacement = href == null || href.isEmpty
          ? text
          : run.kind == MdInlineKind.link
          ? '[$text](${_destination(href)}${run.title == null ? '' : ' "${run.title}"'})'
          : '[$text](${_destination(href)})';
      replace(
        start + run.start,
        start + run.end,
        replacement,
        selection: TextSelection.collapsed(
          offset: start + run.start + replacement.length,
        ),
      );
      return;
    }
    if (href == null || href.isEmpty) return;
    final text = selectedText.isEmpty ? href : selectedText;
    final link = '[$text](${_destination(href)})';
    replace(
      selection.start,
      selection.end,
      link,
      selection: TextSelection.collapsed(offset: selection.start + link.length),
    );
  }

  static String _destination(String href) =>
      RegExp(r'[\s()<>]').hasMatch(href) ? '<$href>' : href;

  // --- Clearing ----------------------------------------------------------------

  /// The marks of the runs the selection is in or over taken away (bold,
  /// italic, underline, struck, code, colors, links), their text kept.
  void clearInline() {
    final selection = this.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final edits = <(int, int, String)>[];
    for (final (line, from, to) in _segments(selection)) {
      final start = lineStart(line);
      void visit(List<MdInline> runs) {
        for (final run in runs) {
          if (run.end <= from || run.start >= to) continue;
          if (run.atomic ||
              run.kind == MdInlineKind.escape ||
              run.kind == MdInlineKind.rawHtml ||
              run.kind == MdInlineKind.footnoteRef ||
              run.kind == MdInlineKind.url) {
            continue;
          }
          edits.add((start + run.start, start + run.innerStart, ''));
          edits.add((start + run.innerEnd, start + run.end, ''));
          visit(run.children);
        }
      }

      visit(inlinesOf(line));
    }
    applyEdits(edits);
  }

  // --- Lines -------------------------------------------------------------------

  List<int> _selectedLines() {
    final selection = this.selection;
    final first = lineAt(selection.start);
    var last = lineAt(selection.end);
    if (last > first && selection.end == lineStart(last)) last--;
    return [for (var i = first; i <= last; i++) i];
  }

  /// What [line] is.
  MdLineFormat lineFormatOf(int line) {
    final info = infoOf(line);
    if (info.isFence || info.kind == MdLineKind.indentedCode) {
      return MdLineFormat.code;
    }
    if (info.kind == MdLineKind.heading) {
      return switch (info.level) {
        1 => MdLineFormat.heading1,
        2 => MdLineFormat.heading2,
        3 => MdLineFormat.heading3,
        _ => MdLineFormat.paragraph,
      };
    }
    if (info.kind == MdLineKind.item) {
      if (info.task > 0) return MdLineFormat.task;
      return info.ordered ? MdLineFormat.numbered : MdLineFormat.bullet;
    }
    if (info.quoteDepth > 0) return MdLineFormat.quote;
    return MdLineFormat.paragraph;
  }

  /// What the selection's lines all are; null where they differ.
  MdLineFormat? get lineFormat {
    if (!selection.isValid) return null;
    MdLineFormat? found;
    for (final line in _selectedLines()) {
      final format = lineFormatOf(line);
      if (found != null && format != found) return null;
      found = format;
    }
    return found;
  }

  /// The selection's lines made [format]; where they all are, paragraphs.
  void setLineFormat(MdLineFormat format) {
    if (!selection.isValid) return;
    final selected = _selectedLines();
    final off = selected.every((line) => lineFormatOf(line) == format);
    if (format == MdLineFormat.code) {
      _setCode(selected, !off);
      return;
    }
    if (format == MdLineFormat.quote) {
      final edits = <(int, int, String)>[];
      for (final line in selected) {
        final info = infoOf(line);
        final start = lineStart(line);
        if (off) {
          edits.add((start, start + info.quoteEnd, ''));
        } else if (info.quoteDepth == 0) {
          edits.add((start, start, '> '));
        }
      }
      applyEdits(edits);
      return;
    }
    final edits = <(int, int, String)>[];
    var number = 0;
    for (final line in selected) {
      final info = infoOf(line);
      if (info.isMultiline || info.kind == MdLineKind.indentedCode) continue;
      if (info.kind == MdLineKind.blank && selected.length > 1) continue;
      final start = lineStart(line);
      final nested = info.kind == MdLineKind.item && info.level > 0;
      final from = nested ? info.markerStart : info.quoteEnd;
      number++;
      final prefix = off
          ? ''
          : switch (format) {
              MdLineFormat.heading1 => '# ',
              MdLineFormat.heading2 => '## ',
              MdLineFormat.heading3 => '### ',
              MdLineFormat.bullet => '- ',
              MdLineFormat.numbered => '$number. ',
              MdLineFormat.task => '- [ ] ',
              _ => '',
            };
      edits.add((start + from, start + info.contentStart, prefix));
      // A heading by the line under it: that line goes.
      if (info.kind == MdLineKind.heading && info.setext) {
        edits.add((start + lines.content(line).length, lineEnd(line + 1), ''));
      }
    }
    applyEdits(edits);
  }

  void _setCode(List<int> selected, bool on) {
    final newline = lines.newline;
    if (on) {
      final first = selected.first;
      final last = selected.last;
      applyEdits([
        (lineStart(first), lineStart(first), '```$newline'),
        (lineEnd(last), lineEnd(last), '$newline```'),
      ]);
      return;
    }
    final (first, last) = blockOf(selected.first);
    final edits = <(int, int, String)>[];
    if (infoOf(first).kind == MdLineKind.fenceOpen) {
      edits.add((lineStart(first), lineStart(first + 1), ''));
    }
    if (infoOf(last).kind == MdLineKind.fenceClose && last > first) {
      edits.add((lineEnd(last - 1), lineEnd(last), ''));
    }
    applyEdits(edits);
  }
}
