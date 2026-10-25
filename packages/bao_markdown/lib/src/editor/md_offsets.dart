import 'package:flutter/foundation.dart';

/// How a piece of a line's markdown shows.
enum MdPieceKind {
  /// As it is written, a character shown for each.
  text,

  /// Not shown: marks before a run's text (the caret stops before them).
  opener,

  /// Not shown: marks after a run's text, or a line's marks before its
  /// text (the caret goes past them).
  closer,

  /// Shown as one thing (a picture's tag, a formula), the caret before or
  /// after it.
  atomic,

  /// Shown, not written: what the line needs to be laid out right.
  extra,
}

/// A piece of a line: its columns, and where it is in what shows.
@immutable
class MdPiece {
  const MdPiece(
    this.kind,
    this.sourceStart,
    this.sourceEnd,
    this.shownStart,
    this.shownEnd,
  );

  final MdPieceKind kind;
  final int sourceStart;
  final int sourceEnd;
  final int shownStart;
  final int shownEnd;

  @override
  bool operator ==(Object other) =>
      other is MdPiece &&
      other.kind == kind &&
      other.sourceStart == sourceStart &&
      other.sourceEnd == sourceEnd &&
      other.shownStart == shownStart &&
      other.shownEnd == shownEnd;

  @override
  int get hashCode =>
      Object.hash(kind, sourceStart, sourceEnd, shownStart, shownEnd);
}

/// Where a line's columns are in what it shows, and back: the pieces it
/// shows as, in order, all of it.
@immutable
class MdOffsets {
  const MdOffsets(this.pieces, this.sourceLength, this.shownLength);

  /// A line shown as it is written.
  MdOffsets.plain(int length)
    : pieces = [MdPiece(MdPieceKind.text, 0, length, 0, length)],
      sourceLength = length,
      shownLength = length;

  final List<MdPiece> pieces;
  final int sourceLength;
  final int shownLength;

  /// Where column [column] shows.
  int toShown(int column) {
    for (final piece in pieces) {
      if (column < piece.sourceStart) return piece.shownStart;
      if (column < piece.sourceEnd ||
          (column == piece.sourceStart && piece.kind == MdPieceKind.extra)) {
        return switch (piece.kind) {
          MdPieceKind.text => piece.shownStart + column - piece.sourceStart,
          MdPieceKind.atomic =>
            column == piece.sourceStart ? piece.shownStart : piece.shownEnd,
          _ => piece.shownStart,
        };
      }
    }
    // The end: before what only shows after it.
    var end = shownLength;
    for (final piece in pieces.reversed) {
      if (piece.kind != MdPieceKind.extra) break;
      end = piece.shownStart;
    }
    return end;
  }

  /// The column [shown] is at: before marks that start a run's text,
  /// after those that end one.
  int toSource(int shown) {
    var column = 0;
    for (final piece in pieces) {
      final length = piece.shownEnd - piece.shownStart;
      if (shown < piece.shownStart) return column;
      if (shown == piece.shownStart) {
        switch (piece.kind) {
          case MdPieceKind.closer:
            column = piece.sourceEnd;
            continue;
          case MdPieceKind.opener:
          case MdPieceKind.text:
          case MdPieceKind.atomic:
          case MdPieceKind.extra:
            if (length > 0 || piece.kind == MdPieceKind.opener) {
              return piece.sourceStart;
            }
            column = piece.sourceEnd;
            continue;
        }
      }
      if (shown < piece.shownEnd) {
        return switch (piece.kind) {
          MdPieceKind.text => piece.sourceStart + shown - piece.shownStart,
          _ => piece.sourceEnd,
        };
      }
      column = piece.sourceEnd;
    }
    return column;
  }

  /// The columns [start] to [end] show as.
  (int, int) rangeToShown(int start, int end) => (toShown(start), toShown(end));

  /// The column range of the piece that is one thing at [column] (an
  /// atomic one), if it is in one.
  (int, int)? atomicAt(int column) {
    for (final piece in pieces) {
      if (piece.kind == MdPieceKind.atomic &&
          piece.sourceStart < column &&
          column < piece.sourceEnd) {
        return (piece.sourceStart, piece.sourceEnd);
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is MdOffsets &&
      other.sourceLength == sourceLength &&
      other.shownLength == shownLength &&
      listEquals(other.pieces, pieces);

  @override
  int get hashCode =>
      Object.hash(sourceLength, shownLength, Object.hashAll(pieces));
}
