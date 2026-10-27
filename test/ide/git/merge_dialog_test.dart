// JetBrains IDEs' merge dialog, from a conflict's Merge… (or a double
// click): the sides' changes applied by their arrows, a conflict merged by
// the model; Apply writes the result and marks the file resolved, asked
// first while conflicts are left.

import 'package:baocode/ide/git/commit_message.dart';
import 'package:baocode/ide/git/ide_git_merge_dialog.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';
import 'fake_git.dart';

const _base = 'one\nx\ntwo\nthree\n';
const _ours = 'one\nours\ntwo\nthree\nfour\n';
const _theirs = 'one\ntheirs\ntwo\nthree\n';

void main() {
  late FakeGit git;

  setUp(() {
    git = FakeGit(testRoot)
      ..status = '## main\x00UU lib/a.dart\x00'
      ..operation = 'MERGE_HEAD'
      ..log = gitLogRecord('c1', [], 'First', refs: 'HEAD -> refs/heads/main');
    git.refs['HEAD'] = 'c1';
    git.show[':1:lib/a.dart'] = _base;
    git.show[':2:lib/a.dart'] = _ours;
    git.show[':3:lib/a.dart'] = _theirs;
  });

  Finder inDialog(Finder finder) =>
      find.descendant(of: find.byType(IdeGitMergeDialog), matching: finder);

  Future<IdeWorkspace> open(
    WidgetTester tester, {
    IdeCommitMessageModel? ai,
  }) async {
    final workspace = await pumpWorkbench(
      tester,
      const {
        'lib/a.dart': 'one\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\ntwo\nthree\nfour\n',
      },
      git: git.repository(),
      size: const Size(1800, 900),
      nativeEditor: true,
      commitMessage: ai,
    );
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyG, control: true, shift: true);
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.textContaining('a.dart', findRichText: true).first),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge…'));
    await tester.pumpAndSettle();
    return workspace;
  }

  String written(IdeWorkspace workspace) =>
      (workspace.files as TreeFiles).contents[inRoot('lib/a.dart')]!;

  testWidgets('the change one side made applied; a conflict left, Apply '
      'asks first', (tester) async {
    final workspace = await open(tester);
    expect(find.byType(IdeGitMergeDialog), findsOneWidget);
    expect(inDialog(find.text('1 conflict left')), findsOneWidget);
    expect(
      inDialog(find.text('1 change applied without conflict')),
      findsOneWidget,
    );

    await tester.tap(inDialog(find.text('Apply')).last);
    await tester.pumpAndSettle();
    expect(find.text('1 conflict is not resolved.'), findsOneWidget);
    await tester.tap(find.text('Save and Mark Resolved'));
    await tester.pumpAndSettle();
    expect(find.byType(IdeGitMergeDialog), findsNothing);
    // The ancestor's line where the conflict is; ours' line added.
    expect(written(workspace), 'one\nx\ntwo\nthree\nfour\n');
    expect(git.callsTo('add'), [
      ['add', '-A', '--', 'lib/a.dart'],
    ]);
  });

  testWidgets("a side's arrow, then the other's: both, one after the other", (
    tester,
  ) async {
    final workspace = await open(tester);
    await tester.tap(inDialog(find.byIcon(Codicons.arrowLeft)));
    await tester.pumpAndSettle();
    expect(inDialog(find.text('All conflicts resolved')), findsOneWidget);
    // Ours, now after theirs.
    await tester.tap(inDialog(find.byIcon(Codicons.add)));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.text('Apply')).last);
    await tester.pumpAndSettle();
    expect(written(workspace), 'one\ntheirs\nours\ntwo\nthree\nfour\n');
  });

  testWidgets('a conflict merged by the model', (tester) async {
    IdeCommitMessagePrompt? asked;
    final workspace = await open(
      tester,
      ai: (prompt, {cancel}) async {
        asked = prompt;
        return '<<<MERGED\n  ours and theirs\nMERGED>>>';
      },
    );
    await tester.tap(inDialog(find.text('Merge with AI')));
    await tester.pumpAndSettle();
    expect(asked!.user, contains('Incoming (theirs):\n```\ntheirs\n```'));
    expect(inDialog(find.text('All conflicts resolved')), findsOneWidget);
    await tester.tap(inDialog(find.text('Apply')).last);
    await tester.pumpAndSettle();
    expect(written(workspace), 'one\n  ours and theirs\ntwo\nthree\nfour\n');
  });

  testWidgets('Accept Incoming takes their file whole', (tester) async {
    await open(tester);
    await tester.tap(inDialog(find.text('Accept Incoming')));
    await tester.pumpAndSettle();
    expect(find.byType(IdeGitMergeDialog), findsNothing);
    expect(git.callsTo('checkout'), [
      ['checkout', '--theirs', '--', 'lib/a.dart'],
    ]);
  });
}
