import 'package:baocode/base/list_selection.dart';
import 'package:baocode/theme/ui_zoom.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ScrollController controller;

  /// 200 lines of 20 under a zoom of [zoom], scrolled 800 down: line 40
  /// at the top.
  Future<void> pumpList(WidgetTester tester, {double zoom = 1.5}) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: UiZoom.zoomed(MediaQuery.of(context), zoom),
          child: UiZoom(scale: zoom, child: child),
        ),
        home: Scaffold(
          body: SelectionArea(
            child: ListSelection(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                itemCount: 200,
                itemBuilder: (context, i) => ListSelectionItem(
                  index: i,
                  child: SizedBox(height: 20, child: Text('line $i')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    controller.jumpTo(800);
    await tester.pumpAndSettle();
  }

  Offset start(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)) + const Offset(1, 8);

  Offset end(WidgetTester tester, String text) =>
      tester.getTopRight(find.text(text)) + const Offset(-1, 8);

  List<String> selected(WidgetTester tester) => [
    for (final paragraph in tester.renderObjectList<RenderParagraph>(
      find.byType(RichText, skipOffstage: false),
    ))
      // ignore: invalid_use_of_visible_for_testing_member
      for (final selection in paragraph.selections)
        if (!selection.isCollapsed)
          selection.textInside(paragraph.text.toPlainText()),
  ];

  for (final zoom in [1.0, 1.5]) {
    testWidgets('zoomed $zoom, scrolled: a drag selects from where it '
        'starts to the pointer, and the list stays', (tester) async {
      await pumpList(tester, zoom: zoom);
      final gesture = await tester.startGesture(
        start(tester, 'line 41'),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      for (final line in ['line 42', 'line 43']) {
        await gesture.moveTo(end(tester, line));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(controller.offset, 800);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, 800);
      expect(selected(tester), ['line 41', 'line 42', 'line 43']);
    });
  }

  testWidgets('scrolled while dragging, the start stays on its text and the '
      'end follows the pointer', (tester) async {
    await pumpList(tester);
    final gesture = await tester.startGesture(
      start(tester, 'line 41'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final at = end(tester, 'line 44');
    await gesture.moveTo(at);
    await tester.pump();
    controller.jumpTo(controller.offset + 40);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    // Two lines on: the pointer is on line 46 now.
    expect(selected(tester), [for (var i = 41; i <= 46; i++) 'line $i']);
  });

  testWidgets('a drag held past the bottom scrolls, and the selection runs '
      'from its start to the lines scrolled in', (tester) async {
    await pumpList(tester);
    final gesture = await tester.startGesture(
      start(tester, 'line 41'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final bottom = tester.getBottomLeft(find.byType(ListView));
    await gesture.moveTo(end(tester, 'line 45'));
    await tester.pump();
    await gesture.moveTo(bottom + const Offset(40, 10));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(800));
    // Whole lines from the start on, the last as far as the pointer.
    final lines = selected(tester);
    final whole = lines.sublist(0, lines.length - 1);
    expect(whole.length, greaterThan(10));
    expect(whole, [for (var i = 41; i < 41 + whole.length; i++) 'line $i']);
    expect('line ${41 + whole.length}', startsWith(lines.last));
  });
}
