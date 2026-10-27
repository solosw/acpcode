import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/git/ide_git_commit_panel.dart';
import 'package:baocode/ide/ide_list.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:bao_editor/monaco/flutter/keybinding_entry.dart';
import 'package:baocode/keybindings/keybinding_service.dart';

import '../git/fake_git.dart';
import 'fake_files.dart';

/// The local changes' keys: the commit input's as VS Code's
/// (scm.contribution.ts), the tree's `list.*` with Space checking as in
/// JetBrains IDEs, against a fake Git.
void main() {
  late FakeGit git;

  setUp(() {
    KeybindingService.instance = KeybindingService();
    git = FakeGit(testRoot);
    git.status =
        '## main...origin/main [ahead 1]\x00'
        'M  lib/staged.dart\x00'
        ' M lib/a.dart\x00'
        '?? notes.md\x00';
  });
  tearDown(() => KeybindingService.instance = KeybindingService());

  IdeWorkbenchState workbench(WidgetTester tester) =>
      tester.state<IdeWorkbenchState>(find.byType(IdeWorkbench));

  Future<IdeWorkspace> pumpScm(WidgetTester tester) async {
    final workspace = await pumpWorkbench(tester, const {
      'lib/a.dart': 'a',
      'lib/staged.dart': 's',
      'notes.md': 'n',
    }, git: git.repository());
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyG, control: true, shift: true);
    await tester.pumpAndSettle();
    return workspace;
  }

  Finder rowOf(String name) => find.ancestor(
    of: find.byWidgetPredicate(
      (widget) => widget is IdeResourceLabel && widget.name == name,
    ),
    matching: find.byType(IdeListRow),
  );

  /// The commit message's input, under the Git log's local changes.
  final message = find
      .descendant(
        of: find.byType(IdeGitCommitPanel),
        matching: find.byType(TextField),
      )
      .first;

  TextField input(WidgetTester tester) => tester.widget<TextField>(message);

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
  }) async {
    await chord(tester, key, control: control);
    await tester.pumpAndSettle();
  }

  testWidgets('the commit input: Escape clears the validation, then the '
      'message; Ctrl+Enter commits, as does the user\'s keybinding', (
    tester,
  ) async {
    await pumpScm(tester);
    final state = workbench(tester);
    expect(input(tester).decoration!.hintText, 'Commit Message');
    await tester.tap(message);
    await tester.pump();
    expect(state.keyContext('scmRepository'), isTrue);

    // Without a message it asks for one; Escape takes that away.
    await key(tester, LogicalKeyboardKey.enter, control: true);
    expect(find.text('Enter a commit message.'), findsOneWidget);
    expect(state.keyContext('scmInputHasValidationMessage'), isTrue);
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.text('Enter a commit message.'), findsNothing);
    expect(git.callsTo('commit'), isEmpty);

    // Escape clears the message, but not while some of it is selected.
    await tester.enterText(message, 'Draft');
    await tester.pump();
    final controller = input(tester).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await key(tester, LogicalKeyboardKey.escape);
    expect(controller.text, 'Draft');
    controller.selection = const TextSelection.collapsed(offset: 5);
    await key(tester, LogicalKeyboardKey.escape);
    expect(controller.text, isEmpty);

    await tester.enterText(message, 'Fix a bug');
    await key(tester, LogicalKeyboardKey.enter, control: true);
    // The files checked: the tracked ones.
    expect(git.callsTo('commit').single, [
      'commit',
      '--quiet',
      '-m',
      'Fix a bug',
      '--only',
      '--',
      'lib/a.dart',
      'lib/staged.dart',
    ]);

    // The user's keybinding commits too.
    KeybindingService.instance.userEntries = const [
      KeybindingEntry(
        key: 'ctrl+alt+enter',
        command: 'scm.acceptInput',
        when: 'scmRepository',
      ),
    ];
    await tester.pumpAndSettle();
    await tester.enterText(message, 'Again');
    await tester.pump();
    await chord(tester, LogicalKeyboardKey.enter, control: true, alt: true);
    await tester.pumpAndSettle();
    expect(git.callsTo('commit'), hasLength(2));
  });

  testWidgets('Focus on Changes View; the changes as a tree the arrows '
      'walk; Enter opens a change', (tester) async {
    final workspace = await pumpScm(tester);
    final state = workbench(tester);
    // Nothing selected: the input.
    state.commands
        .firstWhere((command) => command.id == 'workbench.scm.focus')
        .invoke();
    await tester.pumpAndSettle();
    expect(state.keyContext('scmRepository'), isTrue);

    await tester.tap(rowOf('a.dart'));
    await tester.pumpAndSettle();
    expect(state.keyContext('listFocus'), isTrue);
    expect(state.keyContext('scmRepository'), isFalse);
    expect(state.keyContext('treeElementHasParent'), isTrue);
    // Left: its folder, which Left collapses and Right expands.
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(state.keyContext('treeElementCanCollapse'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(rowOf('a.dart'), findsNothing);
    expect(state.keyContext('treeElementCanExpand'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(rowOf('a.dart'), findsOneWidget);

    // Home: Changes; down past lib and a.dart to staged.dart, which Space
    // unchecks and Enter opens.
    await key(tester, LogicalKeyboardKey.home);
    expect(state.keyContext('treeElementHasParent'), isFalse);
    expect(state.keyContext('treeElementHasChild'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(find.text('2 of 3 files checked'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.space);
    expect(find.text('1 of 3 files checked'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(workspace.active?.path, inRoot('lib/staged.dart'));
    expect(state.keyContext('listFocus'), isFalse);

    // Again: the list, where it was.
    state.commands
        .firstWhere((command) => command.id == 'workbench.scm.focus')
        .invoke();
    await tester.pumpAndSettle();
    expect(state.keyContext('listFocus'), isTrue);
    expect(state.keyContext('treeElementHasParent'), isTrue);
  });

  testWidgets('the log\'s rows: a click selects, Down and Up walk, Home '
      'the local changes', (tester) async {
    git.status = '## main\x00';
    git.refs['HEAD'] = 'c2';
    git.log =
        '${gitLogRecord('c2', ['c1'], 'Second', refs: 'HEAD -> refs/heads/main')}\n'
        '${gitLogRecord('c1', [], 'First')}';
    git.show['c2'] = 'M\x00lib/staged.dart\x00';
    git.show['c1'] = 'A\x00lib/a.dart\x00';
    await pumpScm(tester);
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.text('commit: c2'), findsOneWidget);
    expect(rowOf('staged.dart'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(find.text('commit: c1'), findsOneWidget);
    expect(rowOf('a.dart'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(find.text('commit: c2'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.home);
    expect(find.byType(IdeGitCommitPanel), findsOneWidget);
    expect(find.text('commit: c2'), findsNothing);
  });

  testWidgets('the Timeline\'s items: Down, Home and End', (tester) async {
    git
      ..status = '## main\x00M  lib/a.dart\x00'
      ..log =
          '${gitLogRecord('c1', ['c2'], 'Fix the parser')}'
          '${gitLogRecord('c2', ['c3'], 'Add a test')}'
          '${gitLogRecord('c3', [], 'Initial commit')}';
    await pumpWorkbench(
      tester,
      const {'lib/a.dart': 'a'},
      git: git.repository(),
      open: ['lib/a.dart'],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    final state = workbench(tester);
    bool selected(String text) => tester
        .widget<IdeListRow>(
          find.ancestor(
            of: find.textContaining(text, findRichText: true),
            matching: find.byType(IdeListRow),
          ),
        )
        .selected;

    await tester.tap(find.textContaining('Add a test', findRichText: true));
    await tester.pumpAndSettle();
    expect(state.keyContext('listFocus'), isTrue);
    expect(selected('Add a test'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(selected('Initial commit'), isTrue);
    expect(selected('Add a test'), isFalse);
    await key(tester, LogicalKeyboardKey.home);
    expect(selected('Staged Changes'), isTrue);
    await key(tester, LogicalKeyboardKey.end);
    expect(selected('Initial commit'), isTrue);
  });
}
