// An open file's lines changed since its last commit, marked by its line
// numbers as JetBrains IDEs mark them: a bar by lines added or modified, a
// wedge where lines were deleted. A mark pressed shows the change under
// its lines, to roll back, copy, step from or see in a diff; Alt+F5 goes
// from change to change, Alt+F3 shows them.

import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/range_mapping.dart';
import 'package:baocode/ide/git/git_line_changes.dart';
import 'package:baocode/ide/ide_line_change_popup.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';
import 'fake_git.dart';

const _head = 'one\ntwo\nthree\nfour\nfive\nsix\n';
const _disk = 'one\nTWO\nthree\nfour\nNEW\nfive\n';

void main() {
  late FakeGit git;
  late IdeWorkspace workspace;

  setUp(() {
    git = FakeGit(testRoot)
      ..status = '## main\x00 M lib/a.dart\x00'
      ..refs['HEAD'] = 'c1';
    git.show['c1:lib/a.dart'] = _head;
  });

  Future<void> open(WidgetTester tester) async {
    workspace = await pumpWorkbench(
      tester,
      const {'lib/a.dart': _disk},
      open: ['lib/a.dart'],
      git: git.repository(),
      nativeEditor: true,
    );
    await tester.pumpAndSettle();
  }

  EditorSurface surface(WidgetTester tester) =>
      tester.widget<EditorSurface>(find.byType(EditorSurface));

  List<EditorDecoration> marks(WidgetTester tester) => [
    for (final decoration in surface(tester).decorations)
      if (decoration.changeBar != null) decoration,
  ];

  Future<void> press(WidgetTester tester, int line) async {
    surface(tester).onChangeBarTap!(line, Offset.zero);
    await tester.pumpAndSettle();
  }

  String text() => workspace.active!.model.text;

  testWidgets('a bar by lines modified and added, a wedge where lines were '
      'deleted', (tester) async {
    await open(tester);
    final snapshot = workspace.active!.model.snapshot;
    String linesOf(EditorDecoration mark) =>
        '${snapshot.positionAtOffset(mark.start).lineNumber}-'
        '${snapshot.positionAtOffset(mark.end).lineNumber}';
    final shown = marks(tester);
    expect(shown.map(linesOf), ['2-2', '5-5', '6-6']);
    expect(
      [for (final mark in shown) mark.changeBar!.deleted],
      [false, false, true],
    );
    expect(shown[0].changeBar!.color, isNot(shown[1].changeBar!.color));
    expect(shown.every((mark) => mark.overviewRulerColor != null), isTrue);

    // Committed: none.
    git.show['c2:lib/a.dart'] = _disk;
    git.refs['HEAD'] = 'c2';
    git.status = '## main\x00';
    await workspace.git!.refresh(force: true);
    await tester.pumpAndSettle();
    expect(marks(tester), isEmpty);
  });

  testWidgets("a mark pressed shows what the lines were; Rollback puts them "
      'back', (tester) async {
    await open(tester);
    await press(tester, 2);
    expect(find.byType(IdeLineChangePopup), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget);

    // Down to the next, and round from the last to the first.
    await tester.tap(find.byTooltip('Next Change'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Previous Change'));
    await tester.pumpAndSettle();
    expect(find.text('3 of 3'), findsOneWidget);
    expect(find.text('six'), findsOneWidget);

    await tester.tap(find.byTooltip('Rollback'));
    await tester.pumpAndSettle();
    expect(text(), 'one\nTWO\nthree\nfour\nNEW\nfive\nsix\n');
    expect(find.byType(IdeLineChangePopup), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(marks(tester), hasLength(2));
  });

  testWidgets('Copy takes what the lines were; Escape and a press elsewhere '
      'hide it', (tester) async {
    await open(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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
    await press(tester, 2);
    await tester.tap(find.byTooltip('Copy Original Lines'));
    await tester.pumpAndSettle();
    expect(copied, ['two']);

    await tester.tap(find.byType(EditorSurface));
    await tester.pumpAndSettle();
    expect(find.byType(IdeLineChangePopup), findsNothing);

    await press(tester, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(IdeLineChangePopup), findsNothing);
    // An added line's: nothing to copy.
    await press(tester, 5);
    expect(find.byTooltip('Copy Original Lines'), findsNothing);
  });

  testWidgets('Alt+F5 goes to the next change from the caret; Alt+F3 shows '
      'it', (tester) async {
    await open(tester);
    await tester.tap(find.byType(EditorSurface));
    await tester.pumpAndSettle();
    final controller = surface(tester).controller;
    controller.select(0, 0);
    await tester.pump();
    final snapshot = workspace.active!.model.snapshot;
    int line() => snapshot
        .positionAtOffset(controller.value.selection.extentOffset)
        .lineNumber;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(line(), 2);
    expect(find.byType(IdeLineChangePopup), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(line(), 5);
    expect(find.byType(IdeLineChangePopup), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget);
  });

  test("a change's mark: by its lines; lines deleted, by the one before, "
      'or the first', () {
    LineRangeMapping change(int o1, int o2, int m1, int m2) =>
        LineRangeMapping(LineRange(o1, o2), LineRange(m1, m2));
    expect(ideLineChangeLines(change(2, 3, 2, 4)), (first: 2, last: 3));
    expect(ideLineChangeKind(change(2, 3, 2, 4)), IdeLineChangeKind.modified);
    expect(ideLineChangeKind(change(2, 2, 2, 4)), IdeLineChangeKind.added);
    expect(ideLineChangeLines(change(4, 6, 4, 4)), (first: 3, last: 3));
    expect(ideLineChangeKind(change(4, 6, 4, 4)), IdeLineChangeKind.deleted);
    expect(ideLineChangeLines(change(1, 2, 1, 1)), (first: 1, last: 1));
  });
}
