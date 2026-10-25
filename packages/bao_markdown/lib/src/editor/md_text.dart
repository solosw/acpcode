import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../md_controller.dart';
import 'md_display.dart' show MdGroundSpan;
import 'md_offsets.dart';
import 'md_style.dart';

/// What the lines' boxes paint over their text by, and where they are:
/// the selection, the caret (blinking), what an input method composes.
/// A box listens to it while shown, painting again only when what it
/// paints of these changes.
class MdPaintState extends ChangeNotifier {
  MdPaintState(this.controller, this.style);

  MarkdownController controller;
  MarkdownEditorStyle style;

  /// The editor has the keyboard: the caret shows.
  bool get focused => _focused;
  bool _focused = false;
  set focused(bool value) {
    if (value == _focused) return;
    _focused = value;
    notifyListeners();
  }

  /// The caret is in its blink's on half.
  bool get caretOn => _caretOn;
  bool _caretOn = true;
  set caretOn(bool value) {
    if (value == _caretOn) return;
    _caretOn = value;
    notifyListeners();
  }

  /// The boxes shown, by their lines' ids.
  final Map<int, RenderMdLine> boxes = {};

  /// Told of a change the lines' boxes paint by (the controller's).
  void changed() => notifyListeners();

  /// Where line [id] starts and ends now (its `\n` not in it), and where
  /// [lastId] (a block's last line) does; null once gone.
  (int, int)? rangeOf(int id, [int? lastId]) {
    final lines = controller.lines;
    final index = lines.indexOfId(id);
    if (index < 0) return null;
    var last = index;
    if (lastId != null) {
      final found = lines.indexOfId(lastId);
      if (found >= index) last = found;
    }
    return (lines.lineStart(index), lines.lineEnd(last));
  }
}

/// A line's box: its text (a [RichText] its child, or a widget shown for
/// a block), the selection painted under it and the caret over it.
class MdLineBox extends SingleChildRenderObjectWidget {
  const MdLineBox({
    super.key,
    required this.state,
    required this.lineId,
    required this.offsets,
    required this.fontSize,
    this.lastLineId,
    this.isText = true,
    required super.child,
  });

  final MdPaintState state;
  final int lineId;

  /// A block's last line (its box shows all of it).
  final int? lastLineId;
  final MdOffsets offsets;
  final double fontSize;

  /// Its child is the line's [RichText].
  final bool isText;

  @override
  RenderMdLine createRenderObject(BuildContext context) => RenderMdLine(
    state: state,
    lineId: lineId,
    lastLineId: lastLineId,
    offsets: offsets,
    fontSize: fontSize,
    isText: isText,
  );

  @override
  void updateRenderObject(BuildContext context, RenderMdLine renderObject) {
    renderObject
      ..state = state
      ..lineId = lineId
      ..lastLineId = lastLineId
      ..offsets = offsets
      ..fontSize = fontSize
      ..isText = isText;
  }
}

/// What a line's box last painted of the selection, caret and composing.
typedef _Painted = (int, int, bool, int, int, int);

class RenderMdLine extends RenderProxyBox {
  RenderMdLine({
    required MdPaintState state,
    required int lineId,
    int? lastLineId,
    required this.offsets,
    required this.fontSize,
    required this.isText,
  }) {
    _state = state;
    _lineId = lineId;
    _lastLineId = lastLineId;
  }

  MdPaintState get state => _state;
  late MdPaintState _state;
  set state(MdPaintState value) {
    if (identical(value, _state)) return;
    if (attached) _unlisten();
    _state = value;
    if (attached) _listen();
    markNeedsPaint();
  }

  int get lineId => _lineId;
  late int _lineId;
  set lineId(int value) {
    if (value == _lineId) return;
    if (attached) _unlisten();
    _lineId = value;
    if (attached) _listen();
    markNeedsPaint();
  }

  int? get lastLineId => _lastLineId;
  int? _lastLineId;
  set lastLineId(int? value) {
    if (value == _lastLineId) return;
    _lastLineId = value;
    markNeedsPaint();
  }

  MdOffsets offsets;
  double fontSize;
  bool isText;

  RenderParagraph? get paragraph {
    final child = this.child;
    return isText && child is RenderParagraph ? child : null;
  }

  _Painted? _painted;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  void _listen() {
    _state.addListener(_changed);
    _state.boxes[_lineId] = this;
  }

  void _unlisten() {
    _state.removeListener(_changed);
    if (identical(_state.boxes[_lineId], this)) _state.boxes.remove(_lineId);
  }

  void _changed() {
    if (_paintedNow() != _painted) markNeedsPaint();
  }

  /// The selection (from, to, past the end), the caret's column and what
  /// is composed in this line, as they would be painted now (-1 where
  /// they are not in it).
  _Painted? _paintedNow() {
    final range = _state.rangeOf(_lineId, _lastLineId);
    if (range == null) return null;
    final (start, end) = range;
    final controller = _state.controller;
    final selection = controller.selection;
    var from = -1;
    var to = -1;
    var pastEnd = false;
    if (selection.isValid &&
        !selection.isCollapsed &&
        selection.start <= end &&
        selection.end >= start &&
        !(selection.end == start && start != end)) {
      from = math.max(selection.start, start) - start;
      to = math.min(selection.end, end) - start;
      pastEnd = selection.end > end;
      if (from == to && !pastEnd) from = to = -1;
    }
    var caret = -1;
    if (_state.focused &&
        _state.caretOn &&
        selection.isValid &&
        selection.isCollapsed &&
        selection.extentOffset >= start &&
        selection.extentOffset <= end) {
      caret = selection.extentOffset - start;
    }
    var composeFrom = -1;
    var composeTo = -1;
    final composing = controller.composing;
    if (controller.isComposing &&
        composing.start < end + 1 &&
        composing.end > start) {
      composeFrom = math.max(composing.start, start) - start;
      composeTo = math.min(composing.end, end) - start;
    }
    return (from, to, pastEnd, caret, composeFrom, composeTo);
  }

  // --- Where things are --------------------------------------------------------

  /// The caret's box at [column], in this box's coordinates.
  Rect caretRect(
    int column, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    final paragraph = this.paragraph;
    final width = _state.style.caretWidth;
    if (paragraph == null) {
      final height = math.min(size.height, fontSize * 1.4);
      return Rect.fromLTWH(0, (size.height - height) / 2, width, height);
    }
    final position = TextPosition(
      offset: offsets.toShown(column).clamp(0, offsets.shownLength),
      affinity: affinity,
    );
    final at = paragraph.getOffsetForCaret(position, Rect.zero);
    var top = at.dy;
    var line = paragraph.getFullHeightForCaret(position);
    // As high as its line, wherever in it: not as the glyph beside it, a
    // space's (the text's font) and a Chinese character's (a fallback's,
    // other metrics) far apart.
    if (_lineBox(paragraph, top + line / 2) case final box?) {
      top = box.top;
      line = box.height;
    }
    final height = math.min(line, fontSize * 1.2);
    final shift = paragraph.localToGlobal(Offset.zero, ancestor: this);
    var x = at.dx;
    // Not past the box's edges, where it would be cut off.
    x = math.max(math.min(x, paragraph.size.width - width / 2), width / 2);
    return Rect.fromLTWH(
      x + shift.dx - width / 2,
      top + shift.dy + (line - height) / 2,
      width,
      height,
    );
  }

  /// The box of the line laid out (wrapped) at [y], as high as its highest
  /// run; null for one with nothing in it.
  static Rect? _lineBox(RenderParagraph paragraph, double y) {
    final start = paragraph.getPositionForOffset(Offset(-1e6, y)).offset;
    final end = paragraph.getPositionForOffset(Offset(1e6, y)).offset;
    if (end <= start) return null;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      boxHeightStyle: ui.BoxHeightStyle.max,
    );
    if (boxes.isEmpty) return null;
    var top = boxes.first.top, bottom = boxes.first.bottom;
    for (final box in boxes.skip(1)) {
      top = math.min(top, box.top);
      bottom = math.max(bottom, box.bottom);
    }
    return Rect.fromLTRB(0, top, 0, bottom);
  }

  /// The column at [local] (this box's coordinates).
  int columnAt(Offset local) {
    final paragraph = this.paragraph;
    if (paragraph == null) return 0;
    final shift = paragraph.localToGlobal(Offset.zero, ancestor: this);
    final position = paragraph.getPositionForOffset(local - shift);
    return offsets.toSource(position.offset);
  }

  /// The word at [column] (from, to).
  (int, int) wordAt(int column) {
    final paragraph = this.paragraph;
    if (paragraph == null) return (0, offsets.sourceLength);
    final shown = offsets.toShown(column);
    final range = paragraph.getWordBoundary(TextPosition(offset: shown));
    return (offsets.toSource(range.start), _sourceEnd(range.end));
  }

  /// The line as it is laid out (wrapped) at [column] (from, to).
  (int, int) visualLineAt(
    int column, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    final paragraph = this.paragraph;
    if (paragraph == null) return (0, offsets.sourceLength);
    final shown = offsets.toShown(column);
    final position = TextPosition(offset: shown, affinity: affinity);
    final top = paragraph.getOffsetForCaret(position, Rect.zero).dy;
    final y = top + paragraph.getFullHeightForCaret(position) / 2;
    final start = paragraph.getPositionForOffset(Offset(-1e6, y)).offset;
    final end = paragraph.getPositionForOffset(Offset(1e6, y)).offset;
    return (offsets.toSource(start), _sourceEnd(end));
  }

  /// [shown]'s column, as an end: before marks that open what is after.
  int _sourceEnd(int shown) {
    if (shown >= offsets.shownLength) {
      // The end's: before what only shows after it.
      return offsets.sourceLength;
    }
    return offsets.toSource(shown);
  }

  /// The boxes [from] to [to] (columns) are laid out in, in this box's.
  List<Rect> rectsFor(int from, int to) {
    final paragraph = this.paragraph;
    if (paragraph == null) return [Offset.zero & size];
    final shift = paragraph.localToGlobal(Offset.zero, ancestor: this);
    final start = offsets.toShown(from);
    final end = offsets.toShown(to);
    if (start == end) {
      return [caretRect(from)];
    }
    return [
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
        boxHeightStyle: ui.BoxHeightStyle.max,
      ))
        box.toRect().shift(shift),
    ];
  }

  // --- Painting ----------------------------------------------------------------

  static const _groundRadius = Radius.circular(3);

  /// The grounds of the [MdGroundSpan]s in [paragraph], under the
  /// selection: as high as their text, round at their ends, one a line.
  void _paintGrounds(Canvas canvas, RenderParagraph paragraph, Offset offset) {
    final grounds = <(int, int, Color)>[];
    var at = 0;
    void walk(InlineSpan span) {
      switch (span) {
        case TextSpan(:final text, :final children):
          final start = at;
          at += text?.length ?? 0;
          if (span is MdGroundSpan && at > start) {
            // Going on in the same color (bold in it, say): one with it.
            if (grounds.isNotEmpty &&
                grounds.last.$2 == start &&
                grounds.last.$3 == span.ground) {
              grounds.last = (grounds.last.$1, at, span.ground);
            } else {
              grounds.add((start, at, span.ground));
            }
          }
          children?.forEach(walk);
        case PlaceholderSpan():
          // Its object replacement character.
          at += 1;
      }
    }

    walk(paragraph.text);
    if (grounds.isEmpty) return;
    final shift = paragraph.localToGlobal(Offset.zero, ancestor: this) + offset;
    for (final (start, end, color) in grounds) {
      // A box a run, those on a line as one.
      final lines = <Rect>[];
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      )) {
        final rect = box.toRect();
        final same = lines.indexWhere(
          (line) => line.top < rect.bottom && rect.top < line.bottom,
        );
        if (same < 0) {
          lines.add(rect);
        } else {
          lines[same] = lines[same].expandToInclude(rect);
        }
      }
      final paint = Paint()..color = color;
      for (final line in lines) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(line.shift(shift), _groundRadius),
          paint,
        );
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (paragraph case final paragraph?) {
      _paintGrounds(context.canvas, paragraph, offset);
    }
    final painted = _painted = _paintedNow();
    if (painted == null) {
      super.paint(context, offset);
      return;
    }
    final (from, to, pastEnd, caret, composeFrom, composeTo) = painted;
    var canvas = context.canvas;
    if (from >= 0 && size.height > 0) {
      final paint = Paint()..color = _state.style.selection;
      if (paragraph == null) {
        canvas.drawRect(offset & size, paint);
      } else {
        if (to > from) {
          for (final rect in rectsFor(from, to)) {
            canvas.drawRect(rect.shift(offset), paint);
          }
        }
        if (pastEnd) {
          // The line's end selected with it: a space's width after it.
          final end = caretRect(to);
          final line = paragraph!.getFullHeightForCaret(
            TextPosition(offset: offsets.toShown(to)),
          );
          final top = end.center.dy - line / 2;
          canvas.drawRect(
            Rect.fromLTWH(
              end.center.dx,
              top,
              fontSize * 0.45,
              line,
            ).shift(offset),
            paint,
          );
        }
      }
    }
    super.paint(context, offset);
    // A child (an embed) may have pushed a layer, ending the canvas above.
    canvas = context.canvas;
    if (composeFrom >= 0 && composeTo > composeFrom && paragraph != null) {
      final paint = Paint()
        ..color = _state.style.composing
        ..strokeWidth = 1;
      for (final rect in rectsFor(composeFrom, composeTo)) {
        final y = rect.bottom - 1.5;
        canvas.drawLine(
          Offset(rect.left, y) + offset,
          Offset(rect.right, y) + offset,
          paint,
        );
      }
    }
    if (caret >= 0 && size.height > 0) {
      final rect = caretRect(
        caret,
        affinity: _state.controller.selection.affinity,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.shift(offset),
          const Radius.circular(0.75),
        ),
        Paint()..color = _state.style.caret,
      );
    }
  }
}
