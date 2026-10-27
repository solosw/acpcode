// A commit's menu in the Git log, as JetBrains IDEs' has it: cherry-pick,
// revert, reset (four ways), edit its message in place, drop it, push up
// to it, tag it, compare it with the working tree, go to its parent or
// child; each the Git command it runs.

import 'package:baocode/ide/git/git_service.dart';
import 'package:baocode/ide/ide_code_diff.dart';
import 'package:baocode/ide/ide_input.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';
import 'fake_git.dart';

void main() {
  late FakeGit git;

  setUp(() {
    // main: c1 then c2 (not pushed); topic: c1 then c3.
    git = FakeGit(testRoot)
      ..status = '## main...origin/main [ahead 1]\x00'
      ..log =
          '${gitLogRecord('c3', ['c1'], 'Topic work', refs: 'refs/heads/topic', time: 1767225900)}\n'
          '${gitLogRecord('c2', ['c1'], 'Second', refs: 'HEAD -> refs/heads/main')}\n'
          '${gitLogRecord('c1', [], 'First', refs: 'refs/remotes/origin/main', time: 1767225000)}';
    git.refs['HEAD'] = 'c2';
  });

  Future<void> pump(WidgetTester tester) async {
    await pumpWorkbench(tester, const {
      'lib/a.dart': 'a',
    }, git: git.repository());
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyG, control: true, shift: true);
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String subject, String item) async {
    await tester.tapAt(
      tester.getCenter(find.text(subject).first),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  /// Edit Commit Message's box.
  final editor = find.byWidgetPredicate(
    (widget) => widget is IdeInputBox && widget.minLines == 3,
  );

  /// The commands run but the reads.
  List<List<String>> writes() => [
    for (final call in git.calls)
      if (!const {
        'status',
        'log',
        'for-each-ref',
        'rev-parse',
        'show',
        'remote',
        'worktree',
        'config',
        'branch',
        'merge-base',
        'rev-list',
        '--version',
      }.contains(call.first))
        call,
  ];

  testWidgets("another branch's commit is cherry-picked; one of this "
      "branch's is not offered it", (tester) async {
    await pump(tester);
    await menu(tester, 'Topic work', 'Cherry-Pick');
    expect(git.callsTo('cherry-pick'), [
      ['cherry-pick', 'c3'],
    ]);
    await tester.tapAt(
      tester.getCenter(find.text('First').first),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Cherry-Pick'), findsNothing);
  });

  testWidgets('Revert Commit, and Reset to Here: Hard once confirmed', (
    tester,
  ) async {
    await pump(tester);
    await menu(tester, 'Second', 'Revert Commit');
    expect(git.callsTo('revert'), [
      ['revert', '--no-edit', 'c2'],
    ]);

    await menu(tester, 'First', 'Reset Current Branch to Here');
    await tester.tap(find.text('Mixed: keep the changes, not staged'));
    await tester.pumpAndSettle();
    await menu(tester, 'First', 'Reset Current Branch to Here');
    await tester.tap(find.text('Hard: discard the changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reset “main” to c1'), findsOneWidget);
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(git.callsTo('reset'), [
      ['reset', '--mixed', 'c1'],
      ['reset', '--hard', 'c1'],
    ]);
  });

  testWidgets("HEAD's message edited in place: amended, message only", (
    tester,
  ) async {
    await pump(tester);
    await menu(tester, 'Second', 'Edit Commit Message…');
    final box = find.descendant(of: editor, matching: find.byType(TextField));
    expect(tester.widget<TextField>(box).controller!.text, 'Second');
    await tester.enterText(box, 'Second, better\n\nWhy.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(git.callsTo('commit'), [
      [
        'commit',
        '--amend',
        '--only',
        '--allow-empty',
        '-m',
        'Second, better\n\nWhy.',
      ],
    ]);
    expect(editor, findsNothing);
  });

  testWidgets("an older commit's message: an amend! commit squashed into it, "
      'no editor; Escape leaves it', (tester) async {
    git.answers['commit-tree'] = const IdeGitOutput(0, 'c9\n');
    await pump(tester);
    await menu(tester, 'First', 'Edit Commit Message…');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(editor, findsNothing);

    await menu(tester, 'First', 'Edit Commit Message…');
    final box = find.descendant(of: editor, matching: find.byType(TextField));
    await tester.enterText(box, 'First, reworded');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(writes(), [
      [
        'commit-tree',
        '',
        '-p',
        'HEAD',
        '-m',
        'amend! c1',
        '-m',
        'First, reworded',
      ],
      ['update-ref', '-m', 'reword', 'HEAD', 'c9'],
      [
        '-c',
        'sequence.editor=:',
        '-c',
        'core.editor=:',
        'rebase',
        '-i',
        '--autosquash',
        '--autostash',
        '--root',
      ],
    ]);
  });

  testWidgets('Drop Commit once confirmed; Push All up to Here', (
    tester,
  ) async {
    await pump(tester);
    await menu(tester, 'Second', 'Drop Commit');
    expect(find.textContaining('Take c2 “Second” out'), findsOneWidget);
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();
    expect(git.callsTo('rebase'), [
      ['rebase', '--autostash', '--onto', 'c1', 'c2'],
    ]);

    await menu(tester, 'Second', 'Push All up to Here');
    expect(git.callsTo('push'), [
      ['push', 'origin', 'c2:refs/heads/main'],
    ]);
    // Pushed already: not offered.
    await tester.tapAt(
      tester.getCenter(find.text('First').first),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Push All up to Here'), findsNothing);
  });

  testWidgets('New Tag, annotated with a message', (tester) async {
    await pump(tester);
    await menu(tester, 'First', 'New Tag…');
    final inputs = find.byType(TextField);
    await tester.enterText(inputs.at(inputs.evaluate().length - 2), 'v1.0');
    await tester.enterText(inputs.last, 'The first');
    await tester.tap(find.text('Create Tag'));
    await tester.pumpAndSettle();
    expect(git.callsTo('tag'), [
      ['tag', '-a', '-m', 'The first', 'v1.0', 'c1'],
    ]);
  });

  testWidgets('Compare with Local shows the files that differ; Go to Parent '
      'Commit selects it', (tester) async {
    git.diff = 'M\x00lib/a.dart\x00';
    git.show['c2:lib/a.dart'] = 'b';
    await pump(tester);
    await menu(tester, 'Second', 'Compare with Local');
    expect(git.callsTo('diff').last, [
      'diff',
      '--name-status',
      '-z',
      '-M',
      'c2',
      '--',
    ]);
    expect(find.byType(IdeCodeDiff), findsOneWidget);
    await tester.tap(find.byTooltip(RegExp('^Back to Log')));
    await tester.pumpAndSettle();

    await menu(tester, 'Second', 'Go to Parent Commit');
    expect(find.text('commit: c1'), findsOneWidget);
    await menu(tester, 'First', 'Go to Child Commit');
    expect(find.text('commit: c3'), findsOneWidget);
  });

  testWidgets('Ctrl-click and Shift-click select more; together they are '
      'squashed, reverted or compared', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Second').first);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('First').first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('2 commits selected'), findsOneWidget);

    await menu(tester, 'First', 'Squash 2 Commits into One');
    final rebase = git.calls.where((call) => call.contains('rebase')).single;
    expect(rebase.sublist(0, 2), [
      '-c',
      "sequence.editor=sed -i.bak -e 's/^pick \\(c2[0-9a-f]*\\) /squash \\1 /'",
    ]);
    expect(rebase.last, '--root');

    await menu(tester, 'First', 'Revert 2 Commits');
    expect(git.callsTo('revert').last, ['revert', '--no-edit', 'c2', 'c1']);
    await menu(tester, 'First', 'Compare Commits');
    expect(git.callsTo('diff').last, [
      'diff',
      '--name-status',
      '-z',
      '-M',
      'c1',
      'c2',
      '--',
    ]);

    // Shift: all from the one clicked last.
    await tester.tap(find.text('Topic work').first);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('First').first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('3 commits selected'), findsOneWidget);
    // A plain click: that one alone.
    await tester.tap(find.text('Second').first);
    await tester.pumpAndSettle();
    expect(find.text('commit: c2'), findsOneWidget);
  });
}
