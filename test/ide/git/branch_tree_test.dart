// The branch tree beside the Git log, as JetBrains IDEs have it: HEAD, the
// local branches, the remote ones by remote and the tags, as trees by the
// branches' prefixes, favorites first; typed, narrowed. A branch pressed
// selects its tip; its menu has the branch popup's actions, each the Git
// command it runs.

import 'package:baocode/ide/git/git_branch_tree.dart';
import 'package:baocode/ide/git/git_model.dart';
import 'package:baocode/ide/git/git_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';
import 'fake_git.dart';

final _main = 'a' * 40;
final _feature = 'b' * 40;
final _old = 'c' * 40;

void main() {
  IdeGitRef ref(String id, IdeGitRefKind kind, {String? remote}) => IdeGitRef(
    id,
    id.replaceFirst(RegExp('^refs/(heads|remotes|tags)/'), ''),
    kind,
    remote: remote,
  );

  final refs = [
    ref('refs/heads/main', IdeGitRefKind.branch),
    ref('refs/heads/feat/b', IdeGitRefKind.branch),
    ref('refs/heads/feat/a', IdeGitRefKind.branch),
    ref('refs/heads/zeta', IdeGitRefKind.branch),
    ref('refs/remotes/origin/HEAD', IdeGitRefKind.remote, remote: 'origin'),
    ref('refs/remotes/origin/main', IdeGitRefKind.remote, remote: 'origin'),
    ref('refs/remotes/origin/feat/a', IdeGitRefKind.remote, remote: 'origin'),
    ref('refs/tags/v1', IdeGitRefKind.tag),
  ];

  String outline(List<IdeGitBranchRow> rows) => [
    for (final row in rows)
      '${'  ' * row.depth}${row.label}'
          '${row.expanded == false ? ' +' : ''}'
          '${row.favorite ? ' *' : ''}',
  ].join('\n');

  test('HEAD, then the local, remote and tag trees; favorites first, the '
      'tags folded', () {
    expect(
      outline(
        ideGitBranchRows(
          refs,
          current: 'main',
          favorites: {'refs/heads/zeta'},
        ),
      ),
      'HEAD\n'
      '  main\n'
      'local\n'
      '  feat\n'
      '    a\n'
      '    b\n'
      '  zeta *\n'
      '  main\n'
      'remote\n'
      '  origin\n'
      '    feat\n'
      '      a\n'
      '    main\n'
      'tags +',
    );
  });

  test('typed: the refs that match, their folders open', () {
    expect(
      outline(
        ideGitBranchRows(
          refs,
          current: 'main',
          folded: {'local/feat', 'remote', 'tags'},
          filter: 'T/A',
        ),
      ),
      'local\n'
      '  feat\n'
      '    a\n'
      'remote\n'
      '  origin\n'
      '    feat\n'
      '      a',
    );
  });

  test('favorites kept as JSON', () {
    final favorites = IdeGitFavoriteBranches()
      ..toggle('/repo', 'refs/heads/b')
      ..toggle('/repo', 'refs/heads/a');
    final json = favorites.toJson();
    expect(json, {
      '/repo': ['refs/heads/a', 'refs/heads/b'],
    });
    expect(IdeGitFavoriteBranches.fromJson(json).of('/repo'), {
      'refs/heads/a',
      'refs/heads/b',
    });
  });

  group('in the log', () {
    late FakeGit git;

    setUp(() {
      git = FakeGit(testRoot)
        ..status = '## main...origin/main\x00'
        ..log =
            '${gitLogRecord(_feature, [_main], 'Feature work', refs: 'refs/heads/feature')}\n'
            '${gitLogRecord(_main, [_old], 'Main work', refs: 'HEAD -> refs/heads/main, refs/remotes/origin/main')}\n'
            '${gitLogRecord(_old, [], 'Old work')}'
        ..forEachRef = [
          gitRefRecord('refs/heads/main', _main, upstream: 'origin/main'),
          gitRefRecord('refs/heads/feature', _feature),
          gitRefRecord('refs/remotes/origin/main', _main),
          gitRefRecord('refs/tags/v0', _old),
        ].join('\n');
      git.refs['HEAD'] = _main;
    });

    Finder inTree(String text) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_BranchPane',
      ),
      matching: find.text(text),
    );

    Future<void> open(WidgetTester tester) async {
      await pumpWorkbench(tester, const {
        'lib/a.dart': 'a',
      }, git: git.repository(), size: const Size(1800, 900));
      await tester.pumpAndSettle();
      await chord(tester, LogicalKeyboardKey.keyG, control: true, shift: true);
      await tester.pumpAndSettle();
    }

    Future<void> menu(WidgetTester tester, String branch, String item) async {
      await tester.tapAt(
        tester.getCenter(inTree(branch).last),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets('a branch pressed selects its tip; pressed twice, the log '
        'shows it alone', (tester) async {
      await open(tester);
      expect(inTree('Local Branches'), findsOneWidget);
      expect(inTree('Remote Branches'), findsOneWidget);
      expect(inTree('feature'), findsOneWidget);

      await tester.tap(inTree('feature'));
      await tester.pumpAndSettle();
      expect(find.text('commit: bbbbbbb'), findsOneWidget);

      await tester.tap(inTree('feature'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(inTree('feature'));
      await tester.pumpAndSettle();
      expect(git.callsTo('log').last, contains('refs/heads/feature'));

      // Hidden, and shown again.
      await tester.tap(find.byTooltip('Hide Branches'));
      await tester.pumpAndSettle();
      expect(inTree('feature'), findsNothing);
      await tester.tap(find.byTooltip('Show Branches'));
      await tester.pumpAndSettle();
      expect(inTree('feature'), findsOneWidget);
    });

    testWidgets("a branch's menu: merge, rebase, rename, delete with "
        'Restore', (tester) async {
      await open(tester);
      await menu(tester, 'feature', 'Merge “feature” into “main”');
      expect(git.callsTo('merge'), [
        ['merge', '--no-edit', 'feature'],
      ]);
      await menu(tester, 'feature', 'Rebase “main” onto “feature”');
      await menu(tester, 'feature', 'Checkout and Rebase onto “main”');
      expect(git.callsTo('rebase'), [
        ['rebase', '--autostash', 'feature'],
        ['rebase', '--autostash', 'main', 'feature'],
      ]);

      await menu(tester, 'feature', 'Rename…');
      await tester.enterText(find.byType(EditableText).last, 'feature-2');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(git.callsTo('branch').last, [
        'branch',
        '-m',
        'feature',
        'feature-2',
      ]);

      // Not merged: deleted once confirmed, then Restore makes it again.
      git.answers['branch'] = const IdeGitOutput(
        1,
        '',
        "error: the branch 'feature' is not fully merged",
      );
      await menu(tester, 'feature', 'Delete');
      expect(find.textContaining('merged into no other branch'), findsOne);
      git.answers.remove('branch');
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(git.callsTo('branch').last, ['branch', '-D', 'feature']);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(git.callsTo('branch').last, ['branch', 'feature', _feature]);
    });

    testWidgets("Update fast-forwards a branch not checked out; a remote "
        "one's pulled into the current one; a favorite comes first", (
      tester,
    ) async {
      git.forEachRef = [
        gitRefRecord('refs/heads/main', _main, upstream: 'origin/main'),
        gitRefRecord('refs/heads/feature', _feature, upstream: 'origin/feat'),
        gitRefRecord('refs/heads/alpha', _old),
        gitRefRecord('refs/remotes/origin/main', _main),
      ].join('\n');
      git.remotes = 'origin\n';
      await open(tester);
      await menu(tester, 'feature', 'Update');
      expect(git.callsTo('fetch').last, ['fetch', 'origin', 'feat:feature']);
      await menu(tester, 'main', 'Pull into “main” Using Rebase');
      expect(git.callsTo('pull').last, [
        'pull',
        '--rebase',
        '--autostash',
        'origin',
        'main',
      ]);

      double top(String branch) => tester.getTopLeft(inTree(branch)).dy;
      expect(top('alpha'), lessThan(top('feature')));
      await menu(tester, 'feature', 'Add to Favorites');
      expect(top('feature'), lessThan(top('alpha')));
    });
  });
}
