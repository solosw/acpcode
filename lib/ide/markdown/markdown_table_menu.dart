import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart' show ScrollbarTheme;
import 'package:flutter/widgets.dart';

import '../../theme/codicons.dart';

import '../../l10n/l10n.dart';
import '../ide_menu.dart';

/// A markdown table's menu (see [MarkdownEmbeds.tableMenu]), as the app's
/// menus are: its [sections] apart, those [checked] marked; the action
/// picked, or null.
Future<MdTableAction?> showMarkdownTableMenu(
  BuildContext context,
  Rect anchor,
  List<List<MdTableAction>> sections, {
  Set<MdTableAction> checked = const {},
}) async {
  final l10n = context.l10n;
  MdTableAction? picked;
  String label(MdTableAction action) => switch (action) {
    MdTableAction.insertRowAbove => l10n.markdownTableInsertRowAbove,
    MdTableAction.insertRowBelow => l10n.markdownTableInsertRowBelow,
    MdTableAction.duplicateRow => l10n.markdownTableDuplicateRow,
    MdTableAction.moveRowUp => l10n.markdownTableMoveRowUp,
    MdTableAction.moveRowDown => l10n.markdownTableMoveRowDown,
    MdTableAction.clearRow => l10n.markdownTableClearRow,
    MdTableAction.deleteRow => l10n.markdownTableDeleteRow,
    MdTableAction.insertColumnLeft => l10n.markdownTableInsertColumnLeft,
    MdTableAction.insertColumnRight => l10n.markdownTableInsertColumnRight,
    MdTableAction.duplicateColumn => l10n.markdownTableDuplicateColumn,
    MdTableAction.moveColumnLeft => l10n.markdownTableMoveColumnLeft,
    MdTableAction.moveColumnRight => l10n.markdownTableMoveColumnRight,
    MdTableAction.alignLeft => l10n.markdownTableAlignLeft,
    MdTableAction.alignCenter => l10n.markdownTableAlignCenter,
    MdTableAction.alignRight => l10n.markdownTableAlignRight,
    MdTableAction.clearColumn => l10n.markdownTableClearColumn,
    MdTableAction.deleteColumn => l10n.markdownTableDeleteColumn,
    MdTableAction.deleteTable => l10n.markdownTableDeleteTable,
  };
  await showIdeMenu(
    context,
    anchor: anchor,
    iconsInCheckColumn: true,
    entries: [
      for (final (i, section) in sections.indexed) ...[
        if (i > 0) const IdeMenuSeparator(),
        for (final action in section)
          IdeMenuAction(
            label(action),
            icon: _iconOf(action),
            checked: checked.contains(action),
            onSelected: () => picked = action,
          ),
      ],
    ],
  );
  return picked;
}

/// A table's scrollbar (see [MarkdownEmbeds.tableScrollbar]) as the app's
/// are (its theme's thumb), shown while the mouse is over the table.
Widget markdownTableScrollbar(
  BuildContext context,
  ScrollController controller, {
  required bool hovered,
  required EdgeInsets padding,
  required Widget child,
}) {
  final theme = ScrollbarTheme.of(context);
  return RawScrollbar(
    controller: controller,
    thumbVisibility: hovered,
    padding: padding,
    thickness: theme.thickness?.resolve(const {}) ?? 7,
    radius: theme.radius ?? const Radius.circular(4),
    thumbColor: theme.thumbColor?.resolve(const {}),
    minThumbLength: theme.minThumbLength ?? 18,
    child: child,
  );
}

/// [action]'s icon: a codicon where there is one for it, else a table's
/// glyph drawn as they are (a row or a column put in, an alignment).
Widget _iconOf(MdTableAction action) => switch (action) {
  MdTableAction.insertRowAbove => const _TableGlyph(_Glyph.rowAbove),
  MdTableAction.insertRowBelow => const _TableGlyph(_Glyph.rowBelow),
  MdTableAction.insertColumnLeft => const _TableGlyph(_Glyph.columnLeft),
  MdTableAction.insertColumnRight => const _TableGlyph(_Glyph.columnRight),
  MdTableAction.alignLeft => const _TableGlyph(_Glyph.alignLeft),
  MdTableAction.alignCenter => const _TableGlyph(_Glyph.alignCenter),
  MdTableAction.alignRight => const _TableGlyph(_Glyph.alignRight),
  MdTableAction.duplicateRow ||
  MdTableAction.duplicateColumn => const Icon(Codicons.copy),
  MdTableAction.moveRowUp => const Icon(Codicons.arrowUp),
  MdTableAction.moveRowDown => const Icon(Codicons.arrowDown),
  MdTableAction.moveColumnLeft => const Icon(Codicons.arrowLeft),
  MdTableAction.moveColumnRight => const Icon(Codicons.arrowRight),
  MdTableAction.clearRow ||
  MdTableAction.clearColumn => const Icon(Codicons.clearAll),
  MdTableAction.deleteRow ||
  MdTableAction.deleteColumn ||
  MdTableAction.deleteTable => const Icon(Codicons.trash),
};

enum _Glyph {
  rowAbove,
  rowBelow,
  columnLeft,
  columnRight,
  alignLeft,
  alignCenter,
  alignRight,
}

/// A glyph of a table's, drawn in the icon's color, as thin as a
/// codicon's lines.
class _TableGlyph extends StatelessWidget {
  const _TableGlyph(this.glyph);

  final _Glyph glyph;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 16;
    return CustomPaint(
      size: Size.square(size),
      painter: _GlyphPainter(glyph, theme.color ?? const Color(0xFF808080)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 16 grid.
    canvas.scale(size.width / 16);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    void line(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);

    /// A table of two rows and two columns in [rect].
    void table(Rect rect) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
        paint,
      );
      line(rect.left, rect.center.dy, rect.right, rect.center.dy);
      line(rect.center.dx, rect.top, rect.center.dx, rect.bottom);
    }

    void plus(Offset at) {
      line(at.dx - 2.5, at.dy, at.dx + 2.5, at.dy);
      line(at.dx, at.dy - 2.5, at.dx, at.dy + 2.5);
    }

    switch (glyph) {
      case _Glyph.rowAbove:
        table(const Rect.fromLTRB(2.5, 7.5, 13.5, 14));
        plus(const Offset(8, 3.5));
      case _Glyph.rowBelow:
        table(const Rect.fromLTRB(2.5, 2, 13.5, 8.5));
        plus(const Offset(8, 12.5));
      case _Glyph.columnLeft:
        table(const Rect.fromLTRB(7.5, 2.5, 14, 13.5));
        plus(const Offset(3.5, 8));
      case _Glyph.columnRight:
        table(const Rect.fromLTRB(2, 2.5, 8.5, 13.5));
        plus(const Offset(12.5, 8));
      case _Glyph.alignLeft || _Glyph.alignCenter || _Glyph.alignRight:
        for (final (y, width) in [(4.0, 11.0), (8.0, 7.0), (12.0, 11.0)]) {
          final (left, right) = switch (glyph) {
            _Glyph.alignLeft => (2.5, 2.5 + width),
            _Glyph.alignRight => (13.5 - width, 13.5),
            _ => (8 - width / 2, 8 + width / 2),
          };
          line(left, y, right, y);
        }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
