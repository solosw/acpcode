import 'package:flutter/widgets.dart';

import '../md_blocks.dart';
import '../md_controller.dart';
import '../md_inline.dart';
import 'md_editor.dart';
import 'md_style.dart';
import 'md_table.dart';

/// A run of a line shown as one thing (a picture, a formula, a file's…):
/// where it is in the text, as long as its line is as it was when shown.
class MdEmbed {
  MdEmbed({
    required this.controller,
    required this.lineId,
    required this.run,
    required this.line,
    required this.style,
  });

  final MarkdownController controller;
  final int lineId;
  final MdInline run;

  /// Its line's text when it was shown.
  final String line;

  /// The text's around it.
  final TextStyle style;

  /// Its markdown.
  String get source => line.substring(run.start, run.end);

  /// Where it starts in the text; null once its line has changed.
  int? offset() {
    final index = controller.lines.indexOfId(lineId);
    if (index < 0 || controller.lines.content(index) != line) return null;
    return controller.lineStart(index) + run.start;
  }

  /// Its markdown replaced by [markdown] (nothing for it, it gone).
  void replace(String markdown) {
    final start = offset();
    if (start == null) return;
    controller.replace(
      start,
      start + run.end - run.start,
      markdown,
      selection: controller.selection,
    );
  }

  /// It selected.
  void select() {
    final start = offset();
    if (start == null) return;
    controller.selection = TextSelection(
      baseOffset: start,
      extentOffset: start + run.end - run.start,
    );
  }
}

/// A block shown as one thing where the caret is not in it: a table, a
/// formula of its own lines.
class MdBlockEmbed {
  MdBlockEmbed({
    required this.controller,
    required this.lineId,
    required this.kind,
    this.language,
    required this.source,
    required this.style,
    required this.onEdit,
  });

  final MarkdownController controller;

  /// Its first line's.
  final int lineId;

  /// Its first line's kind: a table's head, `$$`, `$$…$$`, a fence's
  /// opening, front matter's `---`.
  final MdLineKind kind;

  /// A code block's, as its fence names it.
  final String? language;

  /// Its lines, as written.
  final String source;

  final TextStyle style;

  /// The caret put in it, its markdown shown to be edited.
  final VoidCallback onEdit;

  bool get isTable => kind == MdLineKind.tableHead;

  /// A code block's code, front matter's: the lines between its fences.
  String get code {
    final lines = source.split(RegExp('\r\n|\r|\n'));
    if (lines.isEmpty) return '';
    final opening = lines.first.trim();
    var end = lines.length;
    if (end > 1) {
      final last = lines.last.trim();
      final closes = switch (kind) {
        MdLineKind.frontMatter => last == '---' || last == '...',
        _ =>
          last.isNotEmpty &&
              (last.startsWith('```') || last.startsWith('~~~')) &&
              last[0] == opening[0] &&
              last.replaceAll(last[0], '').isEmpty,
      };
      if (closes) end--;
    }
    return lines.sublist(1, end).join('\n');
  }

  /// A formula's TeX.
  String get tex {
    var text = source.trim();
    if (text.startsWith(r'$$')) text = text.substring(2);
    if (text.endsWith(r'$$')) text = text.substring(0, text.length - 2);
    return text.trim();
  }

  /// Where it starts in the text; null once it has changed.
  int? offset() {
    final index = controller.lines.indexOfId(lineId);
    if (index < 0) return null;
    final start = controller.lineStart(index);
    final end = start + source.length;
    if (end > controller.length || controller.substring(start, end) != source) {
      return null;
    }
    return start;
  }

  /// Its markdown replaced by [markdown].
  void replace(String markdown) {
    final start = offset();
    if (start == null) return;
    controller.replace(
      start,
      start + source.length,
      markdown,
      selection: controller.selection,
    );
  }
}

/// What a [MarkdownEditor] shows for what markdown has no text for:
/// pictures, formulas, tables, lists' bullets, tasks' boxes, rules. Made
/// to be extended, its methods overridden.
class MarkdownEmbeds {
  const MarkdownEmbeds();

  /// Whether [run] is shown as one thing ([inline]) and never as its
  /// markdown: pictures and formulas.
  bool isAtomic(MdInline run, String line) => run.atomic;

  /// What an atomic run shows as.
  InlineSpan inline(BuildContext context, MdEmbed embed) {
    final run = embed.run;
    final label = switch (run.kind) {
      MdInlineKind.image =>
        (run.title?.isNotEmpty ?? false)
            ? run.title!
            : embed.line.substring(run.innerStart, run.innerEnd).isNotEmpty
            ? embed.line.substring(run.innerStart, run.innerEnd)
            : run.href ?? '',
      _ => embed.line.substring(run.innerStart, run.innerEnd),
    };
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Text(
        run.kind == MdInlineKind.image ? '[$label]' : label,
        style: embed.style.copyWith(fontFamily: 'monospace'),
      ),
    );
  }

  /// Whether a block of [kind] (its first line's: a table's head, `$$`,
  /// `$$…$$`, front matter) shows as [block] where the caret is not in
  /// it, or as its markdown.
  bool showsBlock(MdLineKind kind) => kind == MdLineKind.tableHead;

  /// Whether a code block in [language] (a diagram's…) shows as [block]
  /// where the caret is not in it, or as its code.
  bool showsCode(String? language) => false;

  /// What a block shows as where the caret is not in it (see
  /// [showsBlock]); null for its markdown, as written.
  Widget? block(
    BuildContext context,
    MdBlockEmbed embed,
    MarkdownEditorStyle style,
  ) {
    if (embed.isTable) {
      return MdTable(source: embed.source, style: style, embed: embed);
    }
    return null;
  }

  /// What to do with a table's rows, columns or itself, picked from a
  /// menu of [sections] of actions at [anchor] (on the screen), those
  /// [checked] marked so; null for nothing.
  Future<MdTableAction?> tableMenu(
    BuildContext context,
    Rect anchor,
    List<List<MdTableAction>> sections, {
    Set<MdTableAction> checked = const {},
  }) {
    final editor = context.findAncestorStateOfType<MarkdownEditorState>();
    if (editor == null) return Future.value();
    return showMdTableMenu(
      context,
      anchor,
      sections,
      editor.widget.style,
      checked: checked,
    );
  }

  /// A table's scrollbar, as it scrolls sideways by [controller]: shown
  /// while [hovered] (the mouse over the table), its track [padding] in
  /// from the view's edges.
  Widget tableScrollbar(
    BuildContext context,
    ScrollController controller, {
    required bool hovered,
    required EdgeInsets padding,
    required MarkdownEditorStyle style,
    required Widget child,
  }) => RawScrollbar(
    controller: controller,
    thumbVisibility: hovered,
    thickness: 6,
    radius: const Radius.circular(3),
    padding: padding,
    thumbColor: style.marks.withValues(alpha: 0.5),
    child: child,
  );

  /// A task's box, [onChanged] to tick it (null where it may not be).
  Widget checkbox(
    BuildContext context,
    bool checked,
    TextStyle style,
    ValueChanged<bool>? onChanged,
  ) {
    final size = (style.fontSize ?? 14) * 0.95;
    final color = style.color ?? const Color(0xFF808080);
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged(!checked),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: checked ? color : null,
          border: Border.all(color: color, width: 1.2),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  /// An item's bullet at [level] (from 0).
  Widget bullet(BuildContext context, int level, TextStyle style) => Text(
    const ['•', '◦', '▪'][level % 3],
    style: style,
    textAlign: TextAlign.center,
  );

  /// An ordered item's number, [marker] as written (`1.`, `2)`).
  Widget number(BuildContext context, String marker, TextStyle style) =>
      Text(marker, style: style, textAlign: TextAlign.right);

  /// A thematic break (`---`) where the caret is not on it.
  Widget rule(BuildContext context, MarkdownEditorStyle style) => Container(
    height: 1,
    color: style.rule,
    margin: const EdgeInsets.symmetric(vertical: 4),
  );

  /// What [run] (an atomic one) is copied as, as text.
  String plainText(MdInline run, String line) => switch (run.kind) {
    MdInlineKind.image => run.href ?? '',
    _ => line.substring(run.start, run.end),
  };
}
