import 'dart:io';

import 'package:path/path.dart' as p;

import '../update/version.dart';

/// What the app went through, one line each, in `logs/events.log`
/// (`DataDirectory.logsDir`), beside [ErrorLog]'s errors.log: its windows
/// and views, coming to the front and going, the color theme, the stash's
/// panel. A release build fails silently at times — a window that draws
/// nothing, with no error — and what led to it is then read here, in the
/// diagnostics a user uploads (Settings → Updates).
///
/// Only what happened, never what the user wrote: no text, no titles.
///
/// A run's first line names the app's version and the system. Past
/// [maxBytes], the file becomes `events.1.log` and a new one starts, so the
/// latest events are always kept.
class EventLog {
  EventLog(
    this.directory, {
    this.maxBytes = 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The app's, once `main` has made it; none under test.
  static EventLog? current;

  /// The folder of the log files.
  final String directory;

  final int maxBytes;

  final DateTime Function() _clock;

  String get path => p.join(directory, 'events.log');

  /// The file before it, moved aside.
  String get previousPath => p.join(directory, 'events.1.log');

  bool _started = false;
  int _size = 0;

  /// Writes [message] under [category] (`window`, `theme`…), timed.
  void record(String category, String message) {
    try {
      _write('${_clock().toIso8601String()} [$category] $message\n');
    } catch (_) {
      // The log is no reason to fail: a disk full, a folder gone.
    }
  }

  void _write(String line) {
    if (!_started) {
      _started = true;
      Directory(directory).createSync(recursive: true);
      final file = File(path);
      _size = file.existsSync() ? file.lengthSync() : 0;
      _rollIfFull(0);
      _append(
        '--- BaoCode $appVersionString · ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion} · pid $pid ---\n',
      );
    }
    _rollIfFull(line.length);
    _append(line);
  }

  void _rollIfFull(int adding) {
    if (_size == 0 || _size + adding <= maxBytes) return;
    final previous = File(previousPath);
    if (previous.existsSync()) previous.deleteSync();
    File(path).renameSync(previousPath);
    _size = 0;
  }

  void _append(String text) {
    File(path).writeAsStringSync(text, mode: FileMode.append, flush: true);
    _size += text.length;
  }
}

/// Writes [message] to [EventLog.current], if there is one.
void appEvent(String category, String message) =>
    EventLog.current?.record(category, message);
