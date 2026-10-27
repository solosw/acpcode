// A conflicted file's chunks, as JetBrains IDEs' merge dialog finds them:
// one side's changes applied at once, a change both made alike once, a
// conflict the ancestor's until a side is applied; typing in the result
// keeps them in step.

import 'package:baocode/ide/git/git_merge_model.dart';
import 'package:flutter_test/flutter_test.dart';

String lines(List<String> lines) => '${lines.join('\n')}\n';

void main() {
  test('one side, both alike, a conflict', () async {
    final merge = await IdeGitMerge.compare(
      base: lines(['a', 'b', 'c', 'd', 'e', 'f', 'g']),
      ours: lines(['A', 'b', 'c', 'D', 'e', 'f', 'g', 'h']),
      theirs: lines(['a', 'b', 'C', 'd', 'E2', 'f', 'g', 'h']),
    );
    expect(
      [for (final chunk in merge.chunks) chunk.kind],
      [IdeGitMergeKind.ours, IdeGitMergeKind.conflict, IdeGitMergeKind.both],
    );
    expect(merge.chunks[1].base, (start: 2, end: 5));
    expect(merge.chunks[1].ours, (start: 2, end: 5));
    expect(merge.chunks[1].theirs, (start: 2, end: 5));
    expect(
      merge.initialResult(),
      lines(['A', 'b', 'c', 'd', 'e', 'f', 'g', 'h']),
    );
    expect(merge.conflicts, 1);
    expect(merge.unresolved, 1);
    expect(merge.chunks[0].resolved, isTrue);
  });

  test('a side applied in place of the ancestor, the other after it; '
      'the chunks after follow', () async {
    final merge = await IdeGitMerge.compare(
      base: lines(['a', 'x', 'b']),
      ours: lines(['a', 'o1', 'o2', 'b', 'c']),
      theirs: lines(['a', 't', 'b']),
    );
    expect(merge.initialResult(), lines(['a', 'x', 'b', 'c']));
    final conflict = merge.chunks.first;
    final last = merge.chunks.last;
    expect(conflict.isConflict, isTrue);
    expect((last.resultStart, last.resultEnd), (3, 4));

    final ours = merge.apply(conflict, IdeGitMergeSide.ours);
    expect((ours.start, ours.end), (1, 2));
    expect(ours.lines, ['o1', 'o2']);
    expect((conflict.resultStart, conflict.resultEnd), (1, 3));
    expect((last.resultStart, last.resultEnd), (4, 5));
    expect(merge.unresolved, 0);
    expect(conflict.canApply(IdeGitMergeSide.theirs), isTrue);

    final theirs = merge.apply(conflict, IdeGitMergeSide.theirs);
    expect((theirs.start, theirs.end), (3, 3));
    expect(theirs.lines, ['t']);
    expect((conflict.resultStart, conflict.resultEnd), (1, 4));
    expect((last.resultStart, last.resultEnd), (5, 6));
  });

  test('typed in a chunk, it is edited; typed before it, it moves', () async {
    final merge = await IdeGitMerge.compare(
      base: lines(['a', 'x', 'b']),
      ours: lines(['a', 'o', 'b']),
      theirs: lines(['a', 't', 'b']),
    );
    merge.initialResult();
    final conflict = merge.chunks.single;
    // A line added over it.
    merge.edited(0, 0, 1);
    expect((conflict.resultStart, conflict.resultEnd), (2, 3));
    expect(conflict.resolved, isFalse);
    // Its line typed in, split in two.
    merge.edited(2, 3, 4);
    expect((conflict.resultStart, conflict.resultEnd), (2, 4));
    expect(conflict.edited, isTrue);
    expect(merge.unresolved, 0);
  });

  test('ignored, both sides of a conflict resolve it', () async {
    final merge = await IdeGitMerge.compare(
      base: 'x\n',
      ours: 'o\n',
      theirs: 't\n',
    );
    merge.initialResult();
    final conflict = merge.chunks.single;
    merge.ignore(conflict, IdeGitMergeSide.ours);
    expect(conflict.resolved, isFalse);
    merge.ignore(conflict, IdeGitMergeSide.theirs);
    expect(conflict.resolved, isTrue);
  });

  test('added on both sides: no ancestor, one conflict', () async {
    final merge = await IdeGitMerge.compare(
      base: '',
      ours: 'a\r\nb\r\n',
      theirs: 'a\r\nc\r\n',
    );
    expect(merge.eol, '\r\n');
    expect(merge.chunks.single.isConflict, isTrue);
    expect(merge.initialResult(), '');
  });
}
