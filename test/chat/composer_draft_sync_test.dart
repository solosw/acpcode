import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_controller.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/theme/app_theme.dart';

ComposerController _controller(WidgetTester tester, int index) =>
    tester.widget<MarkdownEditor>(find.byType(MarkdownEditor).at(index))
            .controller
        as ComposerController;

void main() {
  testWidgets('the same agent\'s composer in two places (two windows): what '
      'is typed in one shows in the other', (tester) async {
    final session = ChatSession(historyCount: 0);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Column(
            children: [
              for (var i = 0; i < 2; i++)
                Expanded(
                  child: ChatComposer(session: session, draft: session.draft),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final first = _controller(tester, 0), second = _controller(tester, 1);
    first.replace(
      0,
      0,
      'hello',
      selection: const TextSelection.collapsed(offset: 5),
    );
    await tester.pump();
    expect(second.text, 'hello');
    // Not the other's edit to undo there.
    expect(second.canUndo, isFalse);

    // The caret where it was in the text, moved along by what is put in
    // before it.
    second.selection = const TextSelection.collapsed(offset: 5);
    first.replace(0, 0, '> ');
    await tester.pump();
    expect(second.text, '> hello');
    expect(second.selection, const TextSelection.collapsed(offset: 7));

    second.replace(
      7,
      7,
      ' world',
      selection: const TextSelection.collapsed(offset: 13),
    );
    await tester.pump();
    expect(first.text, '> hello world');
    expect(session.draft.content, '> hello world');

    // A tag put in shows in the other, the same tag.
    final tag = ComposerTokenEmbed.file('lib/main.dart').atom;
    first.replace(first.length, first.length, ' $tag ');
    await tester.pump();
    expect(second.text, first.text);
    expect(second.embeds.single.embed.plainText, '@lib/main.dart');
    expect(second.shownText, '> hello world ￼ ');

    second.clear();
    await tester.pump();
    expect(first.text, '');
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  });
}
