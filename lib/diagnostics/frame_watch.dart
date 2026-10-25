import 'dart:io' show ProcessInfo;
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../platform/event_log.dart';

/// Writes to the event log ([appEvent], under `slow`) a frame that held
/// the UI thread [FrameWatch.slow] or longer, or took as long to draw:
/// what its parts took, and what the app had then (the semantics tree and
/// its size, the render tree's, the conversations shown, memory). And
/// when the semantics tree comes and goes: something reading the window
/// (Windows' input methods, a screen reader) turns it on.
///
/// What a hang report (windows/runner/hang_watchdog.h) does not tell: the
/// state it came in, and the slow frames before it. A line only for a slow
/// frame, and not more than one each [_gap] (but those of a second or
/// more) nor [_most] in a run: a few kilobytes where all is well.
class FrameWatch {
  FrameWatch._(this.slow);

  /// Notes on what the app shows, each by what shows it (a conversation's
  /// view: its size): read only for a slow frame's line. Never what the
  /// user wrote.
  static final Map<Object, String Function()> notes = {};

  static FrameWatch? _current;

  /// Starts watching, once.
  static void start({Duration slow = const Duration(milliseconds: 250)}) {
    if (_current != null) return;
    final watch = _current = FrameWatch._(slow.inMicroseconds);
    final binding = WidgetsBinding.instance;
    // The dispatcher's frame callbacks are the scheduler's once it asks
    // for a frame: wrapped from the first.
    binding.addPersistentFrameCallback(watch._drawn);
    binding.addTimingsCallback(watch._timings);
    binding.addSemanticsEnabledListener(watch._semanticsChanged);
    if (binding.semanticsEnabled) watch._semanticsChanged();
  }

  static const _gap = Duration(seconds: 2);
  static const _most = 400;

  /// In microseconds.
  final int slow;

  final _clock = Stopwatch()..start();
  bool _wrapped = false;

  // This frame's times, in microseconds of [_clock]: its start, its
  // animations done, the build begun, built, laid out, painted and its
  // semantics sent (the scheduler's persistent callbacks run).
  int _begin = -1, _began = 0, _draw = 0, _built = 0;

  int _written = 0;
  int _lastWritten = -1 << 62;

  void _drawn(Duration _) {
    _built = _clock.elapsedMicroseconds;
    if (_wrapped) return;
    final dispatcher = PlatformDispatcher.instance;
    final begin = dispatcher.onBeginFrame;
    final draw = dispatcher.onDrawFrame;
    if (begin == null || draw == null) return;
    _wrapped = true;
    dispatcher
      ..onBeginFrame = (timeStamp) {
        _begin = _clock.elapsedMicroseconds;
        begin(timeStamp);
        _began = _clock.elapsedMicroseconds;
      }
      ..onDrawFrame = () {
        _draw = _clock.elapsedMicroseconds;
        draw();
        _ended();
      };
  }

  void _ended() {
    if (_begin < 0) return;
    final end = _clock.elapsedMicroseconds;
    final took = end - _begin;
    if (took < slow) return;
    String ms(int micros) => '${(micros / 1000).round()}';
    _write(
      took,
      'frame ${ms(took)} ms: animations ${ms(_began - _begin)}, '
      'microtasks ${ms(_draw - _began)}, '
      'build to semantics ${ms(_built - _draw)}, '
      'after ${ms(end - _built)}',
    );
  }

  void _timings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final raster = timing.rasterDuration.inMicroseconds;
      if (raster < slow) continue;
      _write(
        raster,
        'raster ${timing.rasterDuration.inMilliseconds} ms '
        '(build ${timing.buildDuration.inMilliseconds} ms)',
      );
    }
  }

  void _write(int took, String what) {
    final now = _clock.elapsedMicroseconds;
    if (_written >= _most) return;
    if (took < Duration.microsecondsPerSecond &&
        now - _lastWritten < _gap.inMicroseconds) {
      return;
    }
    _written++;
    _lastWritten = now;
    appEvent('slow', '$what; ${_state()}');
  }

  void _semanticsChanged() {
    final on = WidgetsBinding.instance.semanticsEnabled;
    appEvent('semantics', on ? 'on' : 'off');
  }

  /// The trees' sizes, the conversations shown, memory, the app's state.
  String _state() {
    final binding = WidgetsBinding.instance;
    var objects = 0, nodes = 0;
    void visit(RenderObject object) {
      objects++;
      object.visitChildren(visit);
    }

    bool count(SemanticsNode node) {
      nodes++;
      node.visitChildren(count);
      return true;
    }

    for (final view in binding.renderViews) {
      visit(view);
      if (view.owner?.semanticsOwner?.rootSemanticsNode case final root?) {
        count(root);
      }
    }
    final shown = [
      for (final note in notes.values)
        if (note() case final text when text.isNotEmpty) text,
    ];
    return [
      binding.semanticsEnabled ? 'semantics on, $nodes nodes' : 'semantics off',
      '$objects render objects',
      if (shown.isNotEmpty) 'chats ${shown.join(' / ')}',
      '${ProcessInfo.currentRss >> 20} MB',
      binding.lifecycleState?.name ?? 'no lifecycle',
    ].join('; ');
  }
}
