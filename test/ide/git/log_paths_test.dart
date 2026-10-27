// The Git log by path, as JetBrains IDEs filter it: the Paths filter offers
// the file in the editor and its folder; Show History (the explorer's, the
// editor's) shows a file's or a folder's commits; Show History for
// Selection those that changed the lines selected (`git log -L`), their
// numbers at HEAD.

import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:baocode/ide/git/git_model.dart';
import 'package:baocode/ide/ide_explorer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';
import 'fake_git.dart';

void main() {
  late FakeGit git;

  setUp(() {
    git = FakeGit(testRoot)
      ..status = '## main\x00 M lib/a.dart\x00'
      ..refs['HEAD'] = 'c2'
      ..log =
          '${gitLogRecord('c2', ['c1'], 'Second', refs: 'HEAD -> refs/heads/main')}\n'
          '${gitLogRecord('c1', [], 'First')}';
    git.show['c2:lib/a.dart'] = 'one\ntwo\nthree\n';
  });

  /// The last `git log`'s arguments after the refs' `--`.
  List<String> pathspec() {
    final log = git.callsTo('log').last;
    return log.sublist(log.lastIndexOf('--') + 1);
  }

  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    await tester.tapAt(
      tester.getCenter(finder),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the Paths filter offers the file in the editor and its '
      'folder; the lanes join up past the commits left out', (tester) async {
    await pumpWorkbench(
      tester,
      const {'lib/a.dart': 'one\ntwo\nthree\n'},
      open: ['lib/a.dart'],
      git: git.repository(),
      size: const Size(1800, 900),
    );
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyG, control: true, shift: true);
    await tester.pumpAndSettle();
    expect(pathspec(), isEmpty);

    await tester.tap(find.text('Paths'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current File: lib/a.dart'));
    await tester.pumpAndSettle();
    expect(pathspec(), ['lib/a.dart']);
    expect(git.callsTo('log').last, contains('--parents'));
    expect(find.text('a.dart'), findsWidgets);

    await tester.tap(find.text('a.dart').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Its Folder: lib'));
    await tester.pumpAndSettle();
    expect(pathspec(), ['lib']);

    // Clear Filters: all of them again.
    await tester.tap(find.byTooltip('Clear Filters'));
    await tester.pumpAndSettle();
    expect(pathspec(), isEmpty);
  });

  testWidgets("the explorer's Show History: the folder's commits in the log", (
    tester,
  ) async {
    await pumpWorkbench(tester, const {
      'lib/a.dart': 'one\ntwo\nthree\n',
    }, git: git.repository());
    await tester.pumpAndSettle();
    await rightClick(
      tester,
      find.descendant(of: find.byType(IdeExplorer), matching: find.text('lib')),
    );
    await tester.tap(find.text('Show History'));
    await tester.pumpAndSettle();
    expect(pathspec(), ['lib']);
    expect(find.text('Second'), findsWidgets);
  });

  testWidgets('Show History for Selection: the lines as they were at HEAD', (
    tester,
  ) async {
    await pumpWorkbench(
      tester,
      const {'lib/a.dart': 'zero\none\ntwo\nthree\n'},
      open: ['lib/a.dart'],
      git: git.repository(),
      nativeEditor: true,
    );
    await tester.pumpAndSettle();
    final surface = tester.widget<EditorSurface>(find.byType(EditorSurface));
    // The added line alone: no history to show.
    surface.controller.select(0, 4);
    await tester.pump();
    await rightClick(tester, find.byType(EditorSurface));
    expect(find.text('Show History for Selection'), findsNothing);
    expect(find.text('Show History'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // "two" and "three": lines 3 and 4 now, 2 and 3 at HEAD.
    surface.controller.select(10, 19);
    await tester.pump();
    await rightClick(tester, find.byType(EditorSurface));
    await tester.tap(find.text('Show History for Selection'));
    await tester.pumpAndSettle();
    final log = git.callsTo('log').last;
    expect(log, containsAll(['--no-patch', '-L2,3:lib/a.dart']));
    // From HEAD alone: -L digs from one commit.
    expect(log, isNot(contains('--branches')));
    expect(pathspec(), isEmpty);
    expect(find.text('a.dart: lines 2–3'), findsOneWidget);
  });

  test('-L records past the patches an older Git prints', () async {
    git.log =
        '\x1d${gitLogRecord('c2', ['c1'], 'Second')}\n'
        'diff --git a/lib/a.dart b/lib/a.dart\n@@ -1 +1 @@\n'
        '\x1d${gitLogRecord('c1', [], 'First')}\n'
        'diff --git a/lib/a.dart b/lib/a.dart\n';
    final commits = await git
        .repository()
        .service
        .log(
          filter: IdeGitLogFilter(
            lines: (path: '$testRoot/lib/a.dart', start: 1, end: 2),
          ),
        );
    expect(commits.map((commit) => commit.subject), ['Second', 'First']);
  });
}
