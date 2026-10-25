import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<MarkdownController> pumpComposer(WidgetTester tester) async {
    final session = ChatSession(historyCount: 0);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ChatComposer(session: session, draft: session.draft),
        ),
      ),
    );
    await tester.pump();
    final editor = tester.widget<MarkdownEditor>(find.byType(MarkdownEditor));
    editor.focusNode!.requestFocus();
    await tester.pump();
    editor.controller.replace(
      0,
      0,
      'hello',
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await tester.pump();
    return editor.controller;
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    const modifier = LogicalKeyboardKey.metaLeft;
    await tester.sendKeyDownEvent(modifier);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  final shortcuts = <(String, LogicalKeyboardKey, bool)>[
    ('header 1', LogicalKeyboardKey.digit1, false),
    ('header 2', LogicalKeyboardKey.digit2, false),
    ('header 6', LogicalKeyboardKey.digit6, false),
    ('bold', LogicalKeyboardKey.keyB, false),
    ('italic', LogicalKeyboardKey.keyI, false),
    ('underline', LogicalKeyboardKey.keyU, false),
    ('inline code', LogicalKeyboardKey.backquote, false),
    ('strike-through', LogicalKeyboardKey.keyS, true),
    ('quote', LogicalKeyboardKey.keyB, true),
    ('bullet list', LogicalKeyboardKey.keyL, true),
    ('numbered list', LogicalKeyboardKey.keyO, true),
    ('check list', LogicalKeyboardKey.keyC, true),
    ('indent', LogicalKeyboardKey.keyM, false),
  ];

  // A rich text editor's shortcuts for these: nothing here.
  for (final (name, key, shift) in shortcuts) {
    testWidgets(
      'the $name shortcut leaves the text as it is',
      (tester) async {
        final controller = await pumpComposer(tester);
        await press(tester, key, shift: shift);
        expect(controller.text, 'hello');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets('markdown typed is the text, not what it would make', (
    tester,
  ) async {
    final controller = await pumpComposer(tester);
    for (final text in ['# Title', '- [ ] task', '**bold**', '> quote']) {
      controller.replace(0, controller.length, text);
      await tester.pump();
      // Every line a line of text, no runs of markdown in it.
      expect(controller.infoOf(0).kind, MdLineKind.paragraph);
      expect(controller.inlinesOf(0), isEmpty);
      // Nothing of it hidden: shown as it is written.
      final shown = tester
          .widgetList<RichText>(
            find.descendant(
              of: find.byType(MdLineBox),
              matching: find.byType(RichText),
            ),
          )
          .first
          .text
          .toPlainText();
      expect(shown, text);
    }
    // `[] ` typed at a line's start stays as typed, not a task's box.
    controller.replace(0, controller.length, '[]');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '[] ',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    expect(controller.text, '[] ');
  });
}
