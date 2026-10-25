/// A text as its lines (split at `\n`; a `\r` before one stays its line's),
/// each with an id it keeps while edited, given up when the line goes: what
/// is shown of a line is built again only when the line changes.
class MdLines {
  MdLines(String text) {
    _lines = text.split('\n');
    _ids = [for (var i = 0; i < _lines.length; i++) _nextId++];
    _starts = List.filled(_lines.length, 0, growable: true);
    _restart(0);
    _text = text;
  }

  static int _nextId = 1;

  late List<String> _lines;
  late List<int> _ids;
  late List<int> _starts;
  String? _text;

  /// The whole text, as it was given and edited: nothing in it changed but
  /// what the edits changed.
  String get text => _text ??= _lines.join('\n');

  int get length => _starts.last + _lines.last.length;

  int get lineCount => _lines.length;

  String line(int index) => _lines[index];

  /// The id the line at [index] keeps while it is there.
  int idOf(int index) => _ids[index];

  /// Where the line with [id] is now; -1 when it is gone.
  int indexOfId(int id) {
    final index = _index ??= {for (var i = 0; i < _ids.length; i++) _ids[i]: i};
    return index[id] ?? -1;
  }

  Map<int, int>? _index;

  int lineStart(int index) => _starts[index];

  /// Where the line's text ends: before its `\n`, and before its `\r`.
  int lineEnd(int index) {
    final line = _lines[index];
    final end = _starts[index] + line.length;
    return line.endsWith('\r') ? end - 1 : end;
  }

  /// The line's text, without a `\r` that ends it.
  String content(int index) {
    final line = _lines[index];
    return line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
  }

  /// The line [offset] is in (at a line's end, that line's).
  int lineAt(int offset) {
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (_starts[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  /// What a new line is ended with: as the text's first line is (`\r\n`
  /// in a text written so), else `\n`.
  String get newline =>
      _lines.length > 1 && _lines.first.endsWith('\r') ? '\r\n' : '\n';

  String substring(int start, [int? end]) {
    end ??= length;
    if (start >= end) return '';
    final first = lineAt(start);
    final last = lineAt(end);
    if (first == last) {
      final from = _starts[first];
      return _lines[first].substring(start - from, end - from);
    }
    final buffer = StringBuffer(
      _lines[first].substring(start - _starts[first]),
    );
    for (var i = first + 1; i <= last; i++) {
      buffer.write('\n');
      buffer.write(
        i == last ? _lines[i].substring(0, end - _starts[i]) : _lines[i],
      );
    }
    return buffer.toString();
  }

  /// [start] to [end] replaced by [replacement]: which lines it changed.
  MdSplice replace(int start, int end, String replacement) {
    assert(0 <= start && start <= end && end <= length);
    final first = lineAt(start);
    final last = lineAt(end);
    final before = _lines[first].substring(0, start - _starts[first]);
    final after = _lines[last].substring(end - _starts[last]);
    final lines = '$before$replacement$after'.split('\n');
    final ids = [_ids[first], for (var i = 1; i < lines.length; i++) _nextId++];
    _lines.replaceRange(first, last + 1, lines);
    _ids.replaceRange(first, last + 1, ids);
    final added = lines.length - (last - first + 1);
    if (added > 0) {
      _starts.insertAll(first, List.filled(added, 0));
    } else if (added < 0) {
      _starts.removeRange(first, first - added);
    }
    _restart(first);
    _text = null;
    // An edit in a line keeps the lines' ids where they were.
    if (first != last || lines.length != 1) _index = null;
    return MdSplice(first, last - first + 1, lines.length);
  }

  void _restart(int from) {
    var at = from == 0 ? 0 : _starts[from - 1] + _lines[from - 1].length + 1;
    for (var i = from; i < _lines.length; i++) {
      _starts[i] = at;
      at += _lines[i].length + 1;
    }
  }
}

/// The lines an edit changed: [removed] lines from [first] gave way to
/// [inserted] ones.
class MdSplice {
  const MdSplice(this.first, this.removed, this.inserted);

  final int first;
  final int removed;
  final int inserted;

  @override
  String toString() => 'MdSplice($first, -$removed, +$inserted)';
}
