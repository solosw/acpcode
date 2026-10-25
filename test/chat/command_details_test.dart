// A /command's whole description and its file (#220): on a tag of it (the
// menu shows it in its row only, for it not to change height).

import 'package:baocode/chat/composer/command_details.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/composer/composer_mock_data.dart';
import 'package:baocode/chat/composer/suggestion_menu.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _long =
    'Reviews the pending changes for bugs, then for what could be simpler, '
    'and says what it found, worst first, with where each one is.';

const _commands = [
  Suggestion(kind: SuggestionKind.command, label: 'review', detail: _long),
  Suggestion(kind: SuggestionKind.command, label: 'clear', detail: 'Clear'),
];

/// The commands' files: review's alone, the other built in.
Future<String?> _fileOf(String name) async =>
    name == 'review' ? '/home/me/.claude/skills/review/SKILL.md' : null;

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  List<String> opened,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      localizationsDelegates: const [AppLocalizations.delegate],
      home: Scaffold(
        body: CommandDetails(
          describe: (name) =>
              _commands.where((c) => c.label == name).firstOrNull?.detail,
          fileOf: _fileOf,
          open: opened.add,
          child: Center(child: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _menu(int highlighted) => SuggestionMenu(
  title: 'Commands',
  matches: [for (final c in _commands) SuggestionMatch(c, const [])],
  highlighted: highlighted,
  onHighlight: (_) {},
  onSelect: (_) {},
);

void main() {
  testWidgets('the menu keeps its height as another command is highlighted: '
      'a description only in its row', (tester) async {
    await _pump(tester, _menu(0), []);
    final height = tester.getSize(find.byType(SuggestionMenu)).height;
    expect(find.text(_long), findsOneWidget);
    expect(find.text('Open details'), findsNothing);
    await _pump(tester, _menu(1), []);
    expect(tester.getSize(find.byType(SuggestionMenu)).height, height);
  });

  testWidgets("a command's tag shows it whole on hover, and a click opens "
      'its file', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      ComposerTokenChip(
        data: ComposerTokenEmbed.fromSuggestion(_commands.first).data,
        textStyle: const TextStyle(fontSize: 13),
      ),
      opened,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('/review')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text(_long), findsOneWidget);
    expect(find.text('Open details'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('/review')));
    expect(opened, ['/home/me/.claude/skills/review/SKILL.md']);
  });
}
