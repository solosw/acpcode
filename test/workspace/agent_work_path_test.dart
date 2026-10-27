// Where a conversation's agent works: the file it last edited, or the
// folder its last command moved into; told only when that moves.

import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/ide/git/git_model.dart';
import 'package:baocode/workspace/agent_work_path.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A conversation as a list of items.
class _Feed extends ChangeNotifier implements ChatFeed {
  final List<ChatItem> items = [];

  void add(ChatItem item) {
    items.add(item);
    notifyListeners();
  }

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) => items[index];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ToolCallItem _edit(String path) =>
    ToolCallItem(kind: ToolKind.edit, target: path, path: path);

TerminalItem _run(String command) => TerminalItem(command: command, output: '');

void main() {
  test('cd at the start of a command, to an absolute folder', () {
    expect(agentCdTarget('cd /work/wt && flutter test'), '/work/wt');
    expect(agentCdTarget('  cd "/work/my wt"; ls'), '/work/my wt');
    expect(agentCdTarget("cd '/work/wt'"), '/work/wt');
    expect(agentCdTarget(r'cd C:\src\wt && dir'), r'C:\src\wt');
    // Not where it starts, or not absolute: unknown.
    expect(agentCdTarget('ls && cd /work/wt'), isNull);
    expect(agentCdTarget('cd lib && ls'), isNull);
    expect(agentCdTarget('git status'), isNull);
  });

  test('the newest edit or cd, read files and relative paths aside', () {
    final feed = _Feed();
    addTearDown(feed.dispose);
    expect(agentWorkPathOf(feed), isNull);
    feed
      ..add(_edit('/work/monad/lib/a.dart'))
      ..add(_run('cd /work/monad-gitlog && git status'))
      ..add(
        const ToolCallItem(
          kind: ToolKind.read,
          target: 'b.dart',
          path: '/elsewhere/b.dart',
        ),
      )
      ..add(_edit('relative/c.dart'))
      ..add(const AssistantTextItem('Done.'));
    expect(agentWorkPathOf(feed), '/work/monad-gitlog');
    feed.add(_edit('/work/monad-gitlog/lib/d.dart'));
    expect(agentWorkPathOf(feed), '/work/monad-gitlog/lib/d.dart');
  });

  test('tells its listeners when the agent moves, not on each item', () {
    final feed = _Feed();
    final path = AgentWorkPath(feed);
    addTearDown(() {
      path.dispose();
      feed.dispose();
    });
    var told = 0;
    path.addListener(() => told++);
    feed.add(_edit('/work/a/x.dart'));
    expect(path.path, '/work/a/x.dart');
    expect(told, 1);
    feed
      ..add(const AssistantTextItem('Next.'))
      ..add(_edit('/work/a/x.dart'));
    expect(told, 1);
    feed.add(_edit('/work/b/y.dart'));
    expect(path.path, '/work/b/y.dart');
    expect(told, 2);
  });

  test('the worktree shown: the one picked, else the agent\'s, never the '
      "repository's own", () {
    const worktrees = [
      IdeGitWorktree(path: '/work/monad', branch: 'main', main: true),
      IdeGitWorktree(path: '/work/monad-wt', branch: 'feature'),
      IdeGitWorktree(path: '/work/monad-fix', branch: 'fix'),
    ];
    String? shown({String? chosen, String? agent}) => agentShownWorktree(
      root: '/work/monad',
      worktrees: worktrees,
      paths: p.posix,
      chosen: chosen,
      agentPath: agent,
    );
    expect(shown(), isNull);
    expect(shown(agent: '/work/monad/lib/a.dart'), isNull);
    expect(shown(agent: '/work/monad-wt/lib/a.dart'), '/work/monad-wt');
    // Outside every worktree: the repository's own.
    expect(shown(agent: '/tmp/x'), isNull);
    // Picked: over the agent's, the repository's own too.
    expect(
      shown(chosen: '/work/monad-fix', agent: '/work/monad-wt/a'),
      '/work/monad-fix',
    );
    expect(shown(chosen: '/work/monad', agent: '/work/monad-wt/a'), isNull);
  });
}
