import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// How a [MarkdownEditor] shows the markdown: its text, headings, code,
/// quotes, lists, and what is drawn over them.
@immutable
class MarkdownEditorStyle {
  const MarkdownEditorStyle({
    required this.text,
    this.headings = const [
      TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.4),
      TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.4),
      TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.4),
      TextStyle(fontWeight: FontWeight.w600),
      TextStyle(fontWeight: FontWeight.w600),
      TextStyle(fontWeight: FontWeight.w600),
    ],
    this.headingSpacing = const [(8, 4), (6, 2), (4, 0)],
    this.headingRule,
    this.bold = const TextStyle(fontWeight: FontWeight.w600),
    this.italic = const TextStyle(fontStyle: FontStyle.italic),
    this.code = const TextStyle(fontFamily: 'monospace'),
    this.codeBackground = const Color(0x1F808080),
    this.codeBlock = const TextStyle(fontFamily: 'monospace'),
    this.codeBlockBackground = const Color(0x14808080),
    this.codeBlockBorder = const Color(0x33808080),
    this.codeBlockRadius = 8,
    this.codeBlockPadding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 6,
    ),
    this.link = const TextStyle(
      color: Color(0xFF3B82F6),
      decoration: TextDecoration.underline,
    ),
    this.marks = const Color(0x80808080),
    this.quote = const TextStyle(),
    this.quoteBar = const Color(0x55808080),
    this.quoteBarWidth = 3,
    this.quoteIndent = 12,
    this.listIndent = 14,
    this.bulletWidth = 22,
    this.rule = const Color(0x40808080),
    this.selection = const Color(0x553B82F6),
    this.caret = const Color(0xFF3B82F6),
    this.caretWidth = 1.5,
    this.composing = const Color(0xFF808080),
    this.placeholder = const TextStyle(color: Color(0x80808080)),
    this.colorOf = _cssColor,
    this.table,
  });

  /// The text's: its font, size, line height and color.
  final TextStyle text;

  /// Headings' (1 to 6), over [text].
  final List<TextStyle> headings;

  /// Room above and below headings (1, 2, 3…; none for the rest).
  final List<(double, double)> headingSpacing;

  /// A line under headings of levels 1 and 2, as GitHub draws; none
  /// where null.
  final Color? headingRule;

  final TextStyle bold;
  final TextStyle italic;

  /// `` `code` ``'s, over the text's, on [codeBackground].
  final TextStyle code;
  final Color codeBackground;

  /// A code block's text, over [text], in a box of these.
  final TextStyle codeBlock;
  final Color codeBlockBackground;
  final Color codeBlockBorder;
  final double codeBlockRadius;
  final EdgeInsets codeBlockPadding;

  final TextStyle link;

  /// Marks (`**`, `#`, `[`…) where they are shown, by the caret.
  final Color marks;

  /// A quote's text, over the text's, by a bar.
  final TextStyle quote;
  final Color quoteBar;
  final double quoteBarWidth;
  final double quoteIndent;

  /// A list's items: each level in by [listIndent], the bullet (number,
  /// task's box) in [bulletWidth] before the text.
  final double listIndent;
  final double bulletWidth;

  final Color rule;
  final Color selection;
  final Color caret;
  final double caretWidth;

  /// The line under what an input method is composing.
  final Color composing;

  final TextStyle placeholder;

  /// A color as `<span style="color: …">` has it written: a name, a
  /// `#hex`, `rgb()`; null for one not known.
  final Color? Function(String css) colorOf;

  /// A table's look; one from the code blocks' colors where null.
  final MdTableStyle? table;

  MdTableStyle get tableStyle =>
      table ??
      MdTableStyle(
        border: codeBlockBorder,
        head: codeBlockBackground,
        accent: caret,
        control: codeBlockBackground,
        surface: codeBlockBackground,
      );

  TextStyle heading(int level) =>
      text.merge(headings[(level - 1).clamp(0, headings.length - 1)]);

  (double, double) headingSpace(int level) =>
      level - 1 < headingSpacing.length ? headingSpacing[level - 1] : (0, 0);

  MarkdownEditorStyle copyWith({
    TextStyle? text,
    List<TextStyle>? headings,
    List<(double, double)>? headingSpacing,
    Color? headingRule,
    TextStyle? bold,
    TextStyle? italic,
    TextStyle? code,
    Color? codeBackground,
    TextStyle? codeBlock,
    Color? codeBlockBackground,
    Color? codeBlockBorder,
    double? codeBlockRadius,
    EdgeInsets? codeBlockPadding,
    TextStyle? link,
    Color? marks,
    TextStyle? quote,
    Color? quoteBar,
    double? quoteBarWidth,
    double? quoteIndent,
    double? listIndent,
    double? bulletWidth,
    Color? rule,
    Color? selection,
    Color? caret,
    double? caretWidth,
    Color? composing,
    TextStyle? placeholder,
    Color? Function(String css)? colorOf,
    MdTableStyle? table,
  }) => MarkdownEditorStyle(
    text: text ?? this.text,
    headings: headings ?? this.headings,
    headingSpacing: headingSpacing ?? this.headingSpacing,
    headingRule: headingRule ?? this.headingRule,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    code: code ?? this.code,
    codeBackground: codeBackground ?? this.codeBackground,
    codeBlock: codeBlock ?? this.codeBlock,
    codeBlockBackground: codeBlockBackground ?? this.codeBlockBackground,
    codeBlockBorder: codeBlockBorder ?? this.codeBlockBorder,
    codeBlockRadius: codeBlockRadius ?? this.codeBlockRadius,
    codeBlockPadding: codeBlockPadding ?? this.codeBlockPadding,
    link: link ?? this.link,
    marks: marks ?? this.marks,
    quote: quote ?? this.quote,
    quoteBar: quoteBar ?? this.quoteBar,
    quoteBarWidth: quoteBarWidth ?? this.quoteBarWidth,
    quoteIndent: quoteIndent ?? this.quoteIndent,
    listIndent: listIndent ?? this.listIndent,
    bulletWidth: bulletWidth ?? this.bulletWidth,
    rule: rule ?? this.rule,
    selection: selection ?? this.selection,
    caret: caret ?? this.caret,
    caretWidth: caretWidth ?? this.caretWidth,
    composing: composing ?? this.composing,
    placeholder: placeholder ?? this.placeholder,
    colorOf: colorOf ?? this.colorOf,
    table: table ?? this.table,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownEditorStyle &&
      other.text == text &&
      _listEquals(other.headings, headings) &&
      _listEquals(other.headingSpacing, headingSpacing) &&
      other.headingRule == headingRule &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code &&
      other.codeBackground == codeBackground &&
      other.codeBlock == codeBlock &&
      other.codeBlockBackground == codeBlockBackground &&
      other.codeBlockBorder == codeBlockBorder &&
      other.codeBlockRadius == codeBlockRadius &&
      other.codeBlockPadding == codeBlockPadding &&
      other.link == link &&
      other.marks == marks &&
      other.quote == quote &&
      other.quoteBar == quoteBar &&
      other.quoteBarWidth == quoteBarWidth &&
      other.quoteIndent == quoteIndent &&
      other.listIndent == listIndent &&
      other.bulletWidth == bulletWidth &&
      other.rule == rule &&
      other.selection == selection &&
      other.caret == caret &&
      other.caretWidth == caretWidth &&
      other.composing == composing &&
      other.placeholder == placeholder &&
      other.colorOf == colorOf &&
      other.table == table;

  @override
  int get hashCode => Object.hashAll([
    text,
    ...headings,
    ...headingSpacing,
    headingRule,
    bold,
    italic,
    code,
    codeBackground,
    codeBlock,
    codeBlockBackground,
    codeBlockBorder,
    codeBlockRadius,
    codeBlockPadding,
    link,
    marks,
    quote,
    quoteBar,
    quoteBarWidth,
    quoteIndent,
    listIndent,
    bulletWidth,
    rule,
    selection,
    caret,
    caretWidth,
    composing,
    placeholder,
    colorOf,
    table,
  ]);
}

/// How a table shows, edited: its lines and its head's ground, what is
/// picked in it ([accent]: the cell typed in, a row or column dragged),
/// and its controls (the bars that add rows and columns, the handles).
@immutable
class MdTableStyle {
  const MdTableStyle({
    required this.border,
    required this.head,
    required this.accent,
    required this.control,
    required this.surface,
    this.shadow = const Color(0x1A000000),
    this.radius = 8,
  });

  final Color border;
  final Color head;
  final Color accent;

  /// A control's ground under the pointer.
  final Color control;

  /// A handle's ground.
  final Color surface;
  final Color shadow;
  final double radius;

  @override
  bool operator ==(Object other) =>
      other is MdTableStyle &&
      other.border == border &&
      other.head == head &&
      other.accent == accent &&
      other.control == control &&
      other.surface == surface &&
      other.shadow == shadow &&
      other.radius == radius;

  @override
  int get hashCode =>
      Object.hash(border, head, accent, control, surface, shadow, radius);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()`, and a few names.
Color? _cssColor(String css) => parseCssColor(css);

/// A color as CSS writes it: `#rgb`, `#rrggbb`, `#rrggbbaa`,
/// `rgb()`/`rgba()`, a few names; null for any other.
Color? parseCssColor(String css) {
  final value = css.trim().toLowerCase();
  if (value.startsWith('#')) {
    var hex = value.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = [for (final c in hex.split('')) '$c$c'].join();
    }
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return null;
    if (hex.length == 6) return Color(0xFF000000 | parsed);
    if (hex.length == 8) {
      return Color(((parsed & 0xFF) << 24) | (parsed >> 8));
    }
    return null;
  }
  final rgb = RegExp(
    r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$',
  ).firstMatch(value);
  if (rgb != null) {
    final alpha = double.tryParse(rgb[4] ?? '1') ?? 1;
    return Color.fromARGB(
      (alpha.clamp(0, 1) * 255).round(),
      int.parse(rgb[1]!).clamp(0, 255),
      int.parse(rgb[2]!).clamp(0, 255),
      int.parse(rgb[3]!).clamp(0, 255),
    );
  }
  return switch (value) {
    'black' => const Color(0xFF000000),
    'white' => const Color(0xFFFFFFFF),
    'red' => const Color(0xFFFF0000),
    'green' => const Color(0xFF008000),
    'blue' => const Color(0xFF0000FF),
    'yellow' => const Color(0xFFFFFF00),
    'orange' => const Color(0xFFFFA500),
    'purple' => const Color(0xFF800080),
    'gray' || 'grey' => const Color(0xFF808080),
    'mark' => const Color(0x66FFEB3B),
    _ => null,
  };
}
