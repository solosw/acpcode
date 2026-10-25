import 'package:baocode/chat/widgets/live_selectable_text.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a selection kept while its text wraps anew in a scrolled '
      'box: told to its container after the layout, not during', (
    tester,
  ) async {
    var width = 400.0;
    late StateSetter setWidth;
    final text = List.filled(40, 'streamed words wrap here').join(' ');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: StatefulBuilder(
              builder: (context, setState) {
                setWidth = setState;
                // As in the chat: a capped box that scrolls, in the
                // conversation's list, which scrolls too.
                return ListView(
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        height: 200,
                        child: SingleChildScrollView(
                          child: LiveSelectableText(text),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    final live = find.byType(LiveSelectableText);
    RenderLiveSelectableText render() => tester.renderObject(live);
    final rect = tester.getRect(live);
    final drag = await tester.startGesture(
      rect.topLeft + const Offset(20, 10),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveTo(rect.topLeft + const Offset(200, 60));
    await tester.pump();
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));
    String? selected() => render().selection?.textInside(render().text);
    final before = selected();
    expect(before, hasLength(greaterThan(10)));

    // Narrower: the same characters on other lines, other rects.
    for (final next in [260.0, 330.0, 220.0]) {
      setWidth(() => width = next);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(selected(), before);
    }
  });

  testWidgets('a long text, laid out by blocks of lines, measures and '
      'selects as one paragraph would, as it grows', (tester) async {
    // Lines of 30 to 90 characters: blocks of some 1,000 among 6,000.
    final lines = [
      for (var i = 0; i < 100; i++)
        List.filled(1 + i % 4, 'word$i streamed').join(' '),
    ];
    var text = lines.take(60).join('\n');
    late StateSetter setText;
    // All of it on screen: a drag past the window's edge would scroll.
    tester.view
      ..physicalSize = const Size(800, 4000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const style = TextStyle(fontSize: 14);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: SingleChildScrollView(
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setText = setState;
                      return LiveSelectableText(text, style: style);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final live = find.byType(LiveSelectableText);
    RenderLiveSelectableText render() => tester.renderObject(live);

    Future<void> expectAsOneParagraph() async {
      final whole = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(tester.element(live)).style.merge(style),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 300);
      addTearDown(whole.dispose);
      expect(render().size.height, closeTo(whole.height, 0.5));
      expect(render().size.width, closeTo(whole.width, 0.5));
      // A drag from a line near the top to one far below, across blocks.
      final rect = tester.getRect(live);
      const from = Offset(40, 30);
      final to = Offset(120, whole.height - 40);
      final drag = await tester.startGesture(
        rect.topLeft + from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(rect.topLeft + to);
      await tester.pump();
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        render().selection?.textInside(text),
        TextSelection(
          baseOffset: whole.getPositionForOffset(from).offset,
          extentOffset: whole.getPositionForOffset(to).offset,
        ).textInside(text),
      );
      await tester.tapAt(rect.topLeft + const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 500));
    }

    await expectAsOneParagraph();
    // Grown at its end, past a block, and its last line changed.
    setText(() => text = '${lines.join('\n')} and more');
    await tester.pump();
    await expectAsOneParagraph();
    // Changed in the middle.
    setText(() => text = text.replaceFirst('word30', 'w30'));
    await tester.pump();
    await expectAsOneParagraph();
  });

  testWidgets('a long text in a short box holds the blocks near what it '
      'shows, yet measures, selects and copies all of it', (tester) async {
    // Some 60,000 characters: 60 blocks.
    final text = [
      for (var i = 0; i < 1200; i++) 'line $i of a long thought, streamed',
    ].join('\n');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const style = TextStyle(fontSize: 14);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 200,
                child: SingleChildScrollView(
                  controller: controller,
                  child: LiveSelectableText(text, style: style),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final live = find.byType(LiveSelectableText);
    RenderLiveSelectableText render() => tester.renderObject(live);
    final whole = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(tester.element(live)).style.merge(style),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 400);
    addTearDown(whole.dispose);
    expect(render().size.height, closeTo(whole.height, 0.5));
    expect(render().debugHeldBlocks, lessThan(6));

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(render().debugHeldBlocks, lessThan(6));
    expect(render().size.height, closeTo(whole.height, 0.5));

    // A drag at the end, laid out anew where it was let go of.
    final rect = tester.getRect(find.byType(SingleChildScrollView));
    final scrolled = controller.offset;
    final from = Offset(40, 30 + scrolled);
    final to = Offset(120, 150 + scrolled);
    final drag = await tester.startGesture(
      rect.topLeft + from - Offset(0, scrolled),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveTo(rect.topLeft + to - Offset(0, scrolled));
    await tester.pump();
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      render().selection?.textInside(text),
      TextSelection(
        baseOffset: whole.getPositionForOffset(from).offset,
        extentOffset: whole.getPositionForOffset(to).offset,
      ).textInside(text),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(copied, text);
    await tester.pump();
    expect(render().debugHeldBlocks, lessThan(6));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
