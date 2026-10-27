// A conflicted file's three versions as JetBrains IDEs' merge dialog takes
// them: the common ancestor's (stage 1), ours (2) and theirs (3), compared
// line by line with the ancestor's; where only one side changed the
// ancestor's lines, a change, applied to the result at once; where both
// did, alike, the change once; differently, a conflict, the ancestor's
// lines in the result until a side's are applied (or both, one after the
// other) or the lines there are edited.

import 'dart:math' as math;

import 'package:bao_editor/monaco/flutter/lines_diff.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/default_lines_diff_computer/default_lines_diff_computer.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/range_mapping.dart';

/// The current side (`--ours`, the left) or the incoming (`--theirs`, the
/// right).
enum IdeGitMergeSide { ours, theirs }

/// Which sides changed a chunk's lines: one, both alike, or both
/// differently.
enum IdeGitMergeKind { ours, theirs, both, conflict }

/// Lines [start] to [end] (from 0, [end] past the last).
typedef IdeGitMergeLines = ({int start, int end});

/// Where the ancestor's lines were changed, by one side or both, and what
/// is in the result there.
class IdeGitMergeChunk {
  IdeGitMergeChunk({
    required this.kind,
    required this.base,
    required this.ours,
    required this.theirs,
  });

  final IdeGitMergeKind kind;
  final IdeGitMergeLines base;
  final IdeGitMergeLines ours;
  final IdeGitMergeLines theirs;

  /// Its lines in the result: the ancestor's at first, then what is
  /// applied or typed there.
  int resultStart = 0;
  int resultEnd = 0;

  final Set<IdeGitMergeSide> applied = {};
  final Set<IdeGitMergeSide> ignored = {};

  /// Its lines in the result typed over.
  bool edited = false;

  /// Its lines in the result a model's merge of the sides.
  bool merged = false;

  bool get isConflict => kind == IdeGitMergeKind.conflict;

  IdeGitMergeLines lines(IdeGitMergeSide side) => switch (side) {
    IdeGitMergeSide.ours => ours,
    IdeGitMergeSide.theirs => theirs,
  };

  /// Whether [side] changed the ancestor's lines here.
  bool changes(IdeGitMergeSide side) => switch (kind) {
    IdeGitMergeKind.ours => side == IdeGitMergeSide.ours,
    IdeGitMergeKind.theirs => side == IdeGitMergeSide.theirs,
    IdeGitMergeKind.both || IdeGitMergeKind.conflict => true,
  };

  /// Whether [side]'s lines can still go to the result: in place of the
  /// ancestor's, or after the other side's.
  bool canApply(IdeGitMergeSide side) =>
      changes(side) && !applied.contains(side) && !ignored.contains(side);

  /// Nothing more asked of it: a side's lines applied, the lines typed
  /// over, or every side that changed it ignored.
  bool get resolved =>
      edited ||
      applied.isNotEmpty ||
      IdeGitMergeSide.values.every((side) => !changes(side) || !canApply(side));
}

/// A conflicted file's merge: its chunks, kept in step with the result.
class IdeGitMerge {
  IdeGitMerge._(this.base, this.ours, this.theirs, this.chunks, this.eol);

  /// The ancestor's, ours and theirs' lines compared; a text missing (the
  /// file added on both sides, or deleted on one) is empty.
  static Future<IdeGitMerge> compare({
    required String base,
    required String ours,
    required String theirs,
  }) async {
    final eol = ours.contains('\r\n') || theirs.contains('\r\n')
        ? '\r\n'
        : '\n';
    final baseLines = _split(base);
    final ourLines = _split(ours);
    final theirLines = _split(theirs);
    final (toOurs, toTheirs) = await (
      _diff(baseLines, ourLines),
      _diff(baseLines, theirLines),
    ).wait;
    return IdeGitMerge._(
      baseLines,
      ourLines,
      theirLines,
      _chunks(baseLines, ourLines, theirLines, toOurs, toTheirs),
      eol,
    );
  }

  final List<String> base;
  final List<String> ours;
  final List<String> theirs;
  final List<IdeGitMergeChunk> chunks;

  /// Ours' line breaks, else theirs'.
  final String eol;

  List<String> sideLines(IdeGitMergeSide side) => switch (side) {
    IdeGitMergeSide.ours => ours,
    IdeGitMergeSide.theirs => theirs,
  };

  /// The result at first: the ancestor's lines, each change but the
  /// conflicts applied; its chunks' result lines set.
  String initialResult() {
    final lines = <String>[];
    var at = 0;
    for (final chunk in chunks) {
      lines.addAll(base.sublist(at, chunk.base.start));
      chunk.resultStart = lines.length;
      switch (chunk.kind) {
        case IdeGitMergeKind.conflict:
          lines.addAll(base.sublist(chunk.base.start, chunk.base.end));
        case IdeGitMergeKind.ours || IdeGitMergeKind.both:
          lines.addAll(ours.sublist(chunk.ours.start, chunk.ours.end));
          chunk.applied.addAll(IdeGitMergeSide.values.where(chunk.changes));
        case IdeGitMergeKind.theirs:
          lines.addAll(theirs.sublist(chunk.theirs.start, chunk.theirs.end));
          chunk.applied.add(IdeGitMergeSide.theirs);
      }
      chunk.resultEnd = lines.length;
      at = chunk.base.end;
    }
    lines.addAll(base.sublist(at));
    return lines.join(eol);
  }

  int get conflicts => chunks.where((chunk) => chunk.isConflict).length;

  /// The conflicts not yet resolved.
  int get unresolved =>
      chunks.where((chunk) => chunk.isConflict && !chunk.resolved).length;

  /// [chunk]'s [side] applied: the result lines to replace ([start] to
  /// [end]) and with what; in place of the ancestor's lines, or after what
  /// another side put there. The chunks after it follow.
  ({int start, int end, List<String> lines}) apply(
    IdeGitMergeChunk chunk,
    IdeGitMergeSide side,
  ) {
    final range = chunk.lines(side);
    final lines = sideLines(side).sublist(range.start, range.end);
    final replace = chunk.applied.isEmpty && !chunk.edited;
    final start = replace ? chunk.resultStart : chunk.resultEnd;
    final end = chunk.resultEnd;
    chunk.applied.add(side);
    if (chunk.kind == IdeGitMergeKind.both) {
      chunk.applied.addAll(IdeGitMergeSide.values);
    }
    _replaced(chunk, start, end, lines.length);
    return (start: start, end: end, lines: lines);
  }

  /// [chunk]'s result lines replaced with [lines], a model's merge of the
  /// sides: it is resolved, the lines its.
  ({int start, int end, List<String> lines}) replace(
    IdeGitMergeChunk chunk,
    List<String> lines,
  ) {
    final start = chunk.resultStart;
    final end = chunk.resultEnd;
    chunk
      ..edited = true
      ..merged = true;
    _replaced(chunk, start, end, lines.length);
    return (start: start, end: end, lines: lines);
  }

  /// [chunk]'s [side] left out ("Ignore", JetBrains' ×).
  void ignore(IdeGitMergeChunk chunk, IdeGitMergeSide side) {
    if (chunk.canApply(side)) chunk.ignored.add(side);
  }

  /// [chunk]'s result lines [start] to [end] now [count] lines.
  void _replaced(IdeGitMergeChunk chunk, int start, int end, int count) {
    final delta = count - (end - start);
    chunk.resultEnd += delta;
    for (final other in chunks) {
      if (identical(other, chunk) || other.resultStart < chunk.resultStart) {
        continue;
      }
      other
        ..resultStart += delta
        ..resultEnd += delta;
    }
  }

  /// The result's lines [start] to [oldEnd] typed over, now to [newEnd]:
  /// a chunk they touch is edited and takes them in; those after follow.
  void edited(int start, int oldEnd, int newEnd) {
    final delta = newEnd - oldEnd;
    for (final chunk in chunks) {
      final empty = chunk.resultStart == chunk.resultEnd;
      final inside =
          start < chunk.resultEnd && chunk.resultStart < oldEnd ||
          empty && start <= chunk.resultStart && chunk.resultStart <= oldEnd;
      if (inside) {
        chunk
          ..resultStart = math.min(chunk.resultStart, start)
          ..resultEnd = math.max(chunk.resultEnd, oldEnd) + delta
          ..edited = true;
      } else if (oldEnd <= chunk.resultStart) {
        chunk
          ..resultStart += delta
          ..resultEnd += delta;
      }
    }
  }

  static List<String> _split(String text) =>
      text.replaceAll('\r\n', '\n').split('\n');

  static Future<List<LineRangeMapping>> _diff(
    List<String> base,
    List<String> side,
  ) async {
    const options = LinesDiffComputerOptions(maxComputationTimeMs: 5000);
    final diff = isSmallLinesDiff(base, side)
        ? DefaultLinesDiffComputer().computeDiff(base, side, options)
        : await computeLinesDiffOnIsolate(base, side, options);
    return diff.changes;
  }

  /// The two sides' changes of the ancestor's lines, grouped where they
  /// overlap or touch.
  static List<IdeGitMergeChunk> _chunks(
    List<String> base,
    List<String> ours,
    List<String> theirs,
    List<LineRangeMapping> toOurs,
    List<LineRangeMapping> toTheirs,
  ) {
    final changes =
        [
          for (final change in toOurs) (IdeGitMergeSide.ours, change),
          for (final change in toTheirs) (IdeGitMergeSide.theirs, change),
        ]..sort(
          (a, b) => a.$2.original.startLineNumber.compareTo(
            b.$2.original.startLineNumber,
          ),
        );
    final chunks = <IdeGitMergeChunk>[];
    // Lines each side added less those it took out, before the chunk.
    var oursDelta = 0;
    var theirsDelta = 0;
    var i = 0;
    while (i < changes.length) {
      var start = changes[i].$2.original.startLineNumber - 1;
      var end = changes[i].$2.original.endLineNumberExclusive - 1;
      final group = [changes[i++]];
      while (i < changes.length &&
          changes[i].$2.original.startLineNumber - 1 <= end) {
        end = math.max(end, changes[i].$2.original.endLineNumberExclusive - 1);
        group.add(changes[i++]);
      }
      start = math.min(start, group.first.$2.original.startLineNumber - 1);
      IdeGitMergeLines sideLines(IdeGitMergeSide side, int delta) {
        final own = [
          for (final (s, change) in group)
            if (s == side) change,
        ];
        if (own.isEmpty) return (start: start + delta, end: end + delta);
        return (
          start:
              own.first.modified.startLineNumber -
              1 -
              (own.first.original.startLineNumber - 1 - start),
          end:
              own.last.modified.endLineNumberExclusive -
              1 +
              (end - (own.last.original.endLineNumberExclusive - 1)),
        );
      }

      final ourLines = sideLines(IdeGitMergeSide.ours, oursDelta);
      final theirLines = sideLines(IdeGitMergeSide.theirs, theirsDelta);
      final sides = {for (final (side, _) in group) side};
      final kind = sides.length == 1
          ? sides.single == IdeGitMergeSide.ours
                ? IdeGitMergeKind.ours
                : IdeGitMergeKind.theirs
          : _same(ours, ourLines, theirs, theirLines)
          ? IdeGitMergeKind.both
          : IdeGitMergeKind.conflict;
      chunks.add(
        IdeGitMergeChunk(
          kind: kind,
          base: (start: start, end: end),
          ours: ourLines,
          theirs: theirLines,
        ),
      );
      oursDelta = ourLines.end - end;
      theirsDelta = theirLines.end - end;
    }
    return chunks;
  }

  static bool _same(
    List<String> a,
    IdeGitMergeLines aLines,
    List<String> b,
    IdeGitMergeLines bLines,
  ) {
    if (aLines.end - aLines.start != bLines.end - bLines.start) return false;
    for (var k = 0; k < aLines.end - aLines.start; k++) {
      if (a[aLines.start + k] != b[bLines.start + k]) return false;
    }
    return true;
  }
}

/// What the model resolving a conflict is told.
const _aiSystem =
    'You resolve Git merge conflicts. You are given a conflicted part of a '
    "file: the common ancestor's lines, the current side's (ours) and the "
    "incoming side's (theirs), with the lines around it. Reply with the "
    'merged lines only, between a line "<<<MERGED" and a line "MERGED>>>": '
    "keep what each side meant to do, both sides' changes where they can "
    'live together, and the code valid and consistently indented. Do not '
    'repeat the surrounding lines, explain, or add conflict markers.';

/// The prompt for [chunk] of [merge] in [path]: its three versions and
/// [context] lines of the ancestor around it.
({String system, String user}) ideGitMergePrompt(
  IdeGitMerge merge,
  IdeGitMergeChunk chunk, {
  required String path,
  int context = 20,
}) {
  String block(List<String> lines, IdeGitMergeLines range) =>
      lines.sublist(range.start, range.end).join('\n');
  final base = merge.base;
  final before = (
    start: math.max(0, chunk.base.start - context),
    end: chunk.base.start,
  );
  final after = (
    start: chunk.base.end,
    end: math.min(base.length, chunk.base.end + context),
  );
  final user = StringBuffer()
    ..writeln('File: $path')
    ..writeln()
    ..writeln('Lines before the conflict:')
    ..writeln('```')
    ..writeln(block(base, before))
    ..writeln('```')
    ..writeln("Common ancestor's lines:")
    ..writeln('```')
    ..writeln(block(base, chunk.base))
    ..writeln('```')
    ..writeln('Current (ours):')
    ..writeln('```')
    ..writeln(block(merge.ours, chunk.ours))
    ..writeln('```')
    ..writeln('Incoming (theirs):')
    ..writeln('```')
    ..writeln(block(merge.theirs, chunk.theirs))
    ..writeln('```')
    ..writeln('Lines after the conflict:')
    ..writeln('```')
    ..writeln(block(base, after))
    ..write('```');
  return (system: _aiSystem, user: user.toString());
}

/// The merged lines in a model's [reply] (between `<<<MERGED` and
/// `MERGED>>>`); null where there are none.
List<String>? ideGitMergedLines(String reply) {
  final lines = reply.replaceAll('\r\n', '\n').split('\n');
  final start = lines.indexWhere((line) => line.trim() == '<<<MERGED');
  if (start < 0) return null;
  final end = lines.indexWhere((line) => line.trim() == 'MERGED>>>', start);
  if (end < 0) return null;
  return lines.sublist(start + 1, end);
}
