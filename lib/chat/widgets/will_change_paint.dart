import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints [child] into a picture marked as about to change, which the
/// engine then does not keep as a texture (its raster cache).
///
/// For what a scroll view (a repaint boundary) holds in a reply: a code
/// block's lines, a table. They stay the same from frame to frame while the
/// reply streams in around them, and the engine kept each, on screen or not,
/// as a texture of several MB: 136MB of the GPU's for a long reply's.
class WillChangePaint extends SingleChildRenderObjectWidget {
  const WillChangePaint({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWillChangePaint();
}

class _RenderWillChangePaint extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    // The hint is the current picture's; a child's layer ends it and
    // starts another, the rest of the child's.
    context.setWillChangeHint();
    super.paint(context, offset);
    context.setWillChangeHint();
  }
}
