import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/widgets.dart';

/// The composer's text area around its editor [child], and where its caret
/// is in it.
///
/// The editor draws the caret itself: sized to the text (not the 1.5 line
/// height) and centered on the line box, which with even leading in the
/// text style is also the glyphs' center; solid while typing, blinking
/// when idle; scrolled into view as it moves.
class ComposerCaret extends StatefulWidget {
  const ComposerCaret({
    super.key,
    required this.editorKey,
    required this.child,
  });

  final GlobalKey<MarkdownEditorState> editorKey;
  final Widget child;

  @override
  State<ComposerCaret> createState() => ComposerCaretState();
}

class ComposerCaretState extends State<ComposerCaret> {
  /// The caret's box in this widget's coordinates, or null when it is not
  /// drawn (unfocused, a selection, its blink's off half).
  Rect? get caretRect {
    final editor = widget.editorKey.currentState;
    final box = context.findRenderObject();
    if (editor == null ||
        !editor.caretShowing ||
        box is! RenderBox ||
        !box.hasSize) {
      return null;
    }
    final rect = editor.caretRect();
    if (rect == null) return null;
    return box.globalToLocal(rect.topLeft) & rect.size;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
