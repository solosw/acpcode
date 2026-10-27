// Annotate with Git Blame, from the editor's context menu: when each line
// was last changed and by whom in a column by the line numbers, newer ones
// stronger, edited lines without; a line's pressed shows its commit in the
// Git log.

import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:baocode/ide/git/git_model.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';
import 'fake_git.dart';

final _ada = 'a' * 40;
final _grace = 'b' * 40;

void main() {
  late FakeGit git;
  late IdeWorkspace workspace;

  setUp(() {
    git = FakeGit(testRoot)
      ..status = '## main\x00 M lib/a.dart\x00'
      ..refs['HEAD'] = _grace
      ..log =
          '${gitLogRecord(_grace, [_ada], 'Third line', author: 'Grace')}\n'
          '${gitLogRecord(_ada, [], 'Initial commit', author: 'Ada')}';
    git.blame['lib/a.dart'] = [
      gitBlameEntry(
        _ada,
        1,
        2,
        path: 'lib/a.dart',
        author: 'Ada',
        summary: 'Initial commit',
        time: 1700000000,
      ),
      gitBlameEntry(
        _grace,
        3,
        1,
        path: 'lib/a.dart',
        author: 'Grace',
        summary: 'Third line',
        time: 1760000000,
      ),
      gitBlameEntry(
        ideGitUncommittedHash,
        4,
        1,
        path: 'lib/a.dart',
        author: 'Not Committed Yet',
        summary: 'Version of lib/a.dart from lib/a.dart',
      ),
    ].join();
  });

  Future<void> open(WidgetTester tester) async {
    workspace = await pumpWorkbench(
      tester,
      const {'lib/a.dart': 'one\ntwo\nthree\nfour\n'},
      open: ['lib/a.dart'],
      git: git.repository(),
      nativeEditor: true,
    );
    await tester.pumpAndSettle();
  }

  EditorSurface surface(WidgetTester tester) =>
      tester.widget<EditorSurface>(find.byType(EditorSurface));

  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tapAt(
      tester.getCenter(find.byType(EditorSurface)),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  testWidgets('who changed each line and when, newer stronger; none for '
      'lines not committed or edited', (tester) async {
    await open(tester);
    expect(surface(tester).lineAnnotations, isNull);
    await menu(tester, 'Annotate with Git Blame');
    final annotations = surface(tester).lineAnnotations!;
    String day(int seconds) {
      final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      String two(int n) => '$n'.padLeft(2, '0');
      return '${date.year}/${two(date.month)}/${two(date.day)}';
    }

    expect(annotations.of(1)!.text, '${day(1700000000)}  Ada');
    expect(annotations.of(2)!.text, '${day(1700000000)}  Ada');
    expect(annotations.of(3)!.text, '${day(1760000000)}  Grace');
    expect(annotations.of(4), isNull);
    expect(
      annotations.of(3)!.background!.a,
      greaterThan(annotations.of(1)!.background!.a),
    );

    // A line added above: the others follow; it has none.
    final controller = surface(tester).controller;
    controller.applyEdits([const EditorOffsetEdit(0, 0, 'zero\n')]);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final edited = surface(tester).lineAnnotations!;
    expect(edited.of(1), isNull);
    expect(edited.of(2)!.text, contains('Ada'));
    expect(edited.of(4)!.text, contains('Grace'));

    await menu(tester, 'Close Annotations');
    expect(surface(tester).lineAnnotations, isNull);
    expect(workspace.active?.title, 'a.dart');
  });

  testWidgets("a line's annotation pressed shows its commit in the log", (
    tester,
  ) async {
    await open(tester);
    await menu(tester, 'Annotate with Git Blame');
    surface(tester).lineAnnotations!.onTap!(3, Offset.zero);
    await tester.pumpAndSettle();
    expect(find.textContaining('commit: bbbbbbb'), findsOneWidget);
  });
}
