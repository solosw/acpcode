import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('text selected by a drag, the composer not focused before, is '
      'deleted by Backspace', (tester) async {
    final session = ChatSession(historyCount: 0);
    addTearDown(session.dispose);
    final elsewhere = FocusNode();
    addTearDown(elsewhere.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Column(
            children: [
              // Where the keyboard is meanwhile: the chat's history, say.
              Focus(focusNode: elsewhere, child: const SizedBox(height: 20)),
              Expanded(
                child: ChatComposer(session: session, draft: session.draft),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final editor = tester.widget<MarkdownEditor>(find.byType(MarkdownEditor));
    final controller = editor.controller;
    controller.replace(
      0,
      0,
      'hello world',
      selection: const TextSelection.collapsed(offset: 11),
    );
    await tester.pump();
    elsewhere.requestFocus();
    await tester.pumpAndSettle();
    expect(editor.focusNode!.hasFocus, isFalse);

    final start =
        tester.getTopLeft(find.byType(MarkdownEditor)) + const Offset(1, 8);
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    for (var x = 10.0; x <= 300; x += 10) {
      await mouse.moveTo(start + Offset(x, 0));
      await tester.pump();
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expect(controller.selection.isCollapsed, isFalse);
    expect(editor.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(controller.text, isNot(contains('hello')));
  });
}
