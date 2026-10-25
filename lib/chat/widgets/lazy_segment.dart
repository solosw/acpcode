import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../chat_find.dart' show ChatFind, ChatFindRow;

/// The registrar of a list's item for its text, knowing whether the item
/// holds an end of the list's selection.
abstract interface class SelectionEndHolder {
  bool get holdsSelectionEnd;
}

/// A long text's segment (see [markdownSegments]), let go of while far out
/// of the list's view: a box as tall in its place, its text selected and
/// copied whole.
///
/// The list builds what it shows, but a long reply is one of its items: a
/// 240,000-character one held the engine's paragraphs of all of it, some
/// 150MB. Only in a list's item that knows its selection's ends
/// ([SelectionEndHolder]), where it does not go while it holds one of them
/// (whose edge would fall in a box), nor while it [keep]s (the segment still
/// written), nor while the row holds the find's match at hand (counted from
/// every segment's marks).
class LazySegment extends StatefulWidget {
  const LazySegment({
    super.key,
    required this.text,
    required this.keep,
    required this.child,
  });

  /// The segment's markdown.
  final String text;
  final bool keep;
  final Widget child;

  /// How far from the view the segment shows again, and is let go of: a
  /// screen or two, for it to be there before it comes into view.
  static const showWithin = 1200.0;
  static const hideBeyond = 2400.0;

  @override
  State<LazySegment> createState() => _LazySegmentState();
}

class _LazySegmentState extends State<LazySegment> {
  bool _hidden = false;
  bool _keep = true;
  SelectionRegistrar? _registrar;

  /// The segment as last laid out: its height at that width.
  ({String text, double width, double height})? _measured;

  ScrollPosition? _position;
  bool _checking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_checkSoon);
      _position = position?..addListener(_checkSoon);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_checkSoon);
    super.dispose();
  }

  void _laidOut(double width, double height) =>
      _measured = (text: widget.text, width: width, height: height);

  void _checkSoon() {
    if (_checking) return;
    _checking = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checking = false;
      if (mounted) _check();
    });
  }

  void _check() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is! RenderBox) return;
    final view = viewport as RenderBox;
    final top = box.localToGlobal(Offset.zero, ancestor: view).dy;
    final bottom = top + box.size.height;
    final extent = view.size.height;
    final distance = top > extent
        ? top - extent
        : bottom < 0
        ? -bottom
        : 0.0;
    if (_hidden) {
      if (distance < LazySegment.showWithin) setState(() => _hidden = false);
      return;
    }
    final measured = _measured;
    final registrar = _registrar;
    if (distance > LazySegment.hideBeyond &&
        !_keep &&
        measured != null &&
        measured.text == widget.text &&
        measured.width == box.constraints.maxWidth &&
        registrar is SelectionEndHolder &&
        !(registrar as SelectionEndHolder).holdsSelectionEnd) {
      setState(() => _hidden = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final registrar = _registrar = SelectionContainer.maybeOf(context);
    _keep =
        widget.keep ||
        registrar is! SelectionEndHolder ||
        ChatFindRow.holdsCurrent(context);
    final height = _measured?.height;
    if (_keep || height == null || _measured?.text != widget.text) {
      _hidden = false;
    }
    _checkSoon();
    return _SegmentSlot(
      placeholder: _hidden ? height : null,
      text: widget.text,
      registrar: _hidden ? registrar : null,
      onLaidOut: _laidOut,
      child: _hidden ? null : widget.child,
    );
  }
}

class _SegmentSlot extends SingleChildRenderObjectWidget {
  const _SegmentSlot({
    required this.placeholder,
    required this.text,
    required this.registrar,
    required this.onLaidOut,
    super.child,
  });

  final double? placeholder;
  final String text;
  final SelectionRegistrar? registrar;
  final void Function(double width, double height) onLaidOut;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSegmentSlot(onLaidOut)
        ..placeholder = placeholder
        ..text = text
        ..registrar = registrar;

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSegmentSlot renderObject,
  ) {
    renderObject
      ..onLaidOut = onLaidOut
      ..placeholder = placeholder
      ..text = text
      ..registrar = registrar;
  }
}

/// The segment laid out, or, as a [placeholder], a box that tall with its
/// text to select whole.
class _RenderSegmentSlot extends RenderProxyBox {
  _RenderSegmentSlot(this.onLaidOut);

  void Function(double width, double height) onLaidOut;

  double? get placeholder => _placeholder;
  double? _placeholder;
  set placeholder(double? value) {
    if (value == _placeholder) return;
    _placeholder = value;
    markNeedsLayout();
    _syncSelectable();
  }

  String text = '';

  SelectionRegistrar? _registrar;
  set registrar(SelectionRegistrar? value) {
    if (value == _registrar) return;
    _registrar = value;
    _syncSelectable();
  }

  _WholeSelectable? _selectable;

  void _syncSelectable() {
    final registrar = _registrar;
    if (_placeholder != null && registrar != null && attached) {
      (_selectable ??= _WholeSelectable(this)).registrar = registrar;
    } else if (_selectable case final selectable?) {
      _selectable = null;
      selectable
        ..registrar = null
        ..dispose();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _syncSelectable();
  }

  @override
  void detach() {
    super.detach();
    _syncSelectable();
  }

  @override
  void dispose() {
    _registrar = null;
    _syncSelectable();
    super.dispose();
  }

  bool get _shown => _placeholder == null && child != null;

  @override
  void performLayout() {
    if (!_shown) {
      size = constraints.constrain(
        Size(constraints.maxWidth, _placeholder ?? 0),
      );
      return;
    }
    child!.layout(constraints, parentUsesSize: true);
    size = child!.size;
    onLaidOut(constraints.maxWidth, size.height);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _shown
      ? child!.getDryLayout(constraints)
      : constraints.constrain(Size(constraints.maxWidth, _placeholder ?? 0));

  @override
  double computeMinIntrinsicHeight(double width) =>
      _shown ? super.computeMinIntrinsicHeight(width) : (_placeholder ?? 0);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _shown ? super.computeMaxIntrinsicHeight(width) : (_placeholder ?? 0);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_shown) super.paint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _shown && super.hitTestChildren(result, position: position);
}

/// A segment let go of, as text to select: all of it or none, its ends
/// where an edge goes before or after it.
class _WholeSelectable extends ChangeNotifier
    with Selectable, SelectionRegistrant {
  _WholeSelectable(this._slot);

  final _RenderSegmentSlot _slot;

  /// Where the selection's edges are: 0 its start, 1 its end; null for none.
  int? _start;
  int? _end;

  bool get _selected => _start != null && _end != null && _start != _end;

  String? _plainOf;
  String _plain = '';
  String get _plainText {
    if (_plainOf != _slot.text) {
      _plainOf = _slot.text;
      _plain = ChatFind.markdownText(_slot.text).trim();
    }
    return _plain;
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final before = (_start, _end);
    final SelectionResult result;
    switch (event) {
      case SelectAllSelectionEvent():
        _start = 0;
        _end = 1;
        result = SelectionResult.none;
      case ClearSelectionEvent():
        _start = _end = null;
        result = SelectionResult.none;
      case SelectionEdgeUpdateEvent(:final globalPosition, :final type):
        final transform = Matrix4.tryInvert(getTransformTo(null));
        final local = transform == null
            ? Offset.zero
            : MatrixUtils.transformPoint(transform, globalPosition);
        final height = size.height;
        final int edge;
        if (local.dy < 0) {
          edge = 0;
          result = SelectionResult.previous;
        } else if (local.dy > height) {
          edge = 1;
          result = SelectionResult.next;
        } else {
          edge = local.dy < height / 2 ? 0 : 1;
          result = SelectionResult.end;
        }
        if (type == SelectionEventType.startEdgeUpdate) {
          _start = edge;
        } else {
          _end = edge;
        }
      default:
        result = SelectionResult.end;
    }
    if ((_start, _end) != before) notifyListeners();
    return result;
  }

  @override
  SelectionGeometry get value {
    if (!_selected) {
      return const SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: true,
      );
    }
    final box = Offset.zero & size;
    final forward = _start! < _end!;
    final top = SelectionPoint(
      localPosition: box.topLeft,
      lineHeight: 0,
      handleType: forward
          ? TextSelectionHandleType.left
          : TextSelectionHandleType.right,
    );
    final bottom = SelectionPoint(
      localPosition: box.bottomRight,
      lineHeight: 0,
      handleType: forward
          ? TextSelectionHandleType.right
          : TextSelectionHandleType.left,
    );
    return SelectionGeometry(
      startSelectionPoint: forward ? top : bottom,
      endSelectionPoint: forward ? bottom : top,
      selectionRects: [box],
      status: SelectionStatus.uncollapsed,
      hasContent: true,
    );
  }

  @override
  SelectedContent? getSelectedContent() =>
      _selected ? SelectedContent(plainText: _plainText) : null;

  @override
  SelectedContentRange? getSelection() {
    if (!_selected) return null;
    final length = contentLength;
    return _start! < _end!
        ? SelectedContentRange(startOffset: 0, endOffset: length)
        : SelectedContentRange(startOffset: length, endOffset: 0);
  }

  @override
  int get contentLength => _plainText.length;

  @override
  Size get size => _slot.hasSize ? _slot.size : Size.zero;

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) =>
      _slot.getTransformTo(ancestor);

  @override
  List<Rect> get boundingBoxes => [Offset.zero & size];

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {}
}
