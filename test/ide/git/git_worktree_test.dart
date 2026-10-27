// A repository's worktrees as `git worktree list --porcelain` tells them,
// and which of them has a path (where the agent works).

import 'package:baocode/ide/git/git_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _porcelain =
    'worktree /work/monad\n'
    'HEAD ${'a' * 40}\n'
    'branch refs/heads/main\n'
    '\n'
    'worktree /work/monad-gitlog\n'
    'HEAD ${'b' * 40}\n'
    'branch refs/heads/feat/git-log\n'
    '\n'
    'worktree /work/monad/.claude/worktrees/fix\n'
    'HEAD ${'c' * 40}\n'
    'detached\n'
    'locked\n'
    '\n'
    'worktree /gone\n'
    'HEAD ${'d' * 40}\n'
    'branch refs/heads/old\n'
    'prunable gitdir file points to non-existent location\n'
    '\n';

void main() {
  test('reads each worktree: its path, commit and branch, the first the '
      "repository's own", () {
    final worktrees = parseGitWorktrees(_porcelain);
    expect(worktrees.map((w) => w.path), [
      '/work/monad',
      '/work/monad-gitlog',
      '/work/monad/.claude/worktrees/fix',
      '/gone',
    ]);
    expect(worktrees.map((w) => w.main), [true, false, false, false]);
    expect(worktrees[1].branch, 'feat/git-log');
    expect(worktrees[1].head, 'b' * 40);
    // Detached: no branch.
    expect(worktrees[2].branch, isNull);
    expect(worktrees[2].locked, isTrue);
    expect(worktrees[3].prunable, isTrue);
  });

  test('reads Windows line ends, and spells the paths as the host does', () {
    final worktrees = parseGitWorktrees(
      'worktree C:/src/app\r\nHEAD ${'a' * 40}\r\nbranch refs/heads/main\r\n'
      '\r\nworktree C:/src/app-wt\r\nHEAD ${'b' * 40}\r\nbranch refs/heads/x'
      '\r\n',
      normalize: p.windows.normalize,
    );
    expect(worktrees.map((w) => w.path), [r'C:\src\app', r'C:\src\app-wt']);
    expect(worktrees.map((w) => w.branch), ['main', 'x']);
  });

  test("a path's worktree: the innermost that has it", () {
    final worktrees = parseGitWorktrees(_porcelain);
    String? of(String path) => ideWorktreeOf(path, worktrees, p.posix)?.path;
    expect(of('/work/monad/lib/a.dart'), '/work/monad');
    expect(of('/work/monad-gitlog/lib/a.dart'), '/work/monad-gitlog');
    expect(of('/work/monad-gitlog'), '/work/monad-gitlog');
    // Inside the repository's folder, but another worktree.
    expect(
      of('/work/monad/.claude/worktrees/fix/lib/a.dart'),
      '/work/monad/.claude/worktrees/fix',
    );
    expect(of('/elsewhere/a.dart'), isNull);
  });
}
