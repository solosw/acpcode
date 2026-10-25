// How closely a view's scrolling follows the hand that scrolls it: what the
// wheel and the fingers asked for (PerfInput tells it, as it sends them)
// beside where the view was at each frame.
//
// Frames that come in time say nothing of this: a view can draw every frame
// and still trail the fingers, overshoot them (a speed added to what they
// did), or go on long after they stopped. The figures:
//
// - `ratio`: how far the view went, over how far the input asked, from the
//   first input to the last plus a frame (before any fling). 1 is the
//   fingers' own; over 1, sped up.
// - `lagPx`: at each frame while the input comes, how far the view is
//   behind (or past, as a size) what the input asked so far. The same at
//   every frame is input lost (a dead zone as the fingers start), not lag.
// - `lagMs`: at each frame while the input comes, how long ago the input
//   was where the view is: the fingers' lag, in time.
// - `catchUpMs`: from each input to the frame the view has gone 90% of it
//   (a wheel's notch, as it glides).
// - `tailPx`, `tailMs`: how far and how long the view went on after the
//   last input of a gesture (a fling; a wheel's glide).
// - `gestures`: those, for each gesture (inputs less than 150ms apart): the
//   same flick done again should go as far again, not further.
// - `reverseMs`: from an input the other way to the frame the view turns.

import 'package:flutter/scheduler.dart';

import 'perf_probe.dart';

class PerfFollow {
  /// Follows the view whose offset [pixels] gives, while the input goes in
  /// [reversed] (a list whose offset grows upwards) or not.
  PerfFollow(this.pixels, {this.reversed = false, this.atEnd});

  final double Function() pixels;
  final bool reversed;

  /// Whether the view is at an end, where it stops whatever the input:
  /// figures taken there say nothing of following.
  final bool Function()? atEnd;
  var _hitEnd = false;

  /// The one following, which PerfInput tells of its scrolling.
  static PerfFollow? current;

  final Stopwatch _clock = Stopwatch();
  final List<(int, double)> _inputs = [];
  final List<(int, double)> _frames = [];
  late double _from;

  static bool _listening = false;

  void start() {
    if (!_listening) {
      _listening = true;
      SchedulerBinding.instance.addPersistentFrameCallback(
        (_) => current?._frame(),
      );
    }
    _from = pixels();
    _clock.start();
    _frames.add((0, 0));
    current = this;
  }

  /// The view asked to move [delta] the way its offset grows (a wheel's
  /// scroll delta; a trackpad's pan, the other way).
  static void input(double delta) => current?._input(delta);

  void _input(double delta) => _inputs.add((_clock.elapsedMicroseconds, delta));

  double get _moved => (pixels() - _from) * (reversed ? -1 : 1);

  void _frame() {
    _frames.add((_clock.elapsedMicroseconds, _moved));
    if (atEnd?.call() ?? false) _hitEnd = true;
  }

  /// Whether the view came to an end while followed.
  bool get hitEnd => _hitEnd;

  /// Stops following, and gives the figures.
  Map<String, Object> stop() {
    if (identical(current, this)) current = null;
    _frames.add((_clock.elapsedMicroseconds, _moved));
    if (_inputs.isEmpty) return {};
    final frame = _frameUs();
    final gestures = <List<(int, double)>>[];
    for (final input in _inputs) {
      if (gestures.isEmpty || input.$1 - gestures.last.last.$1 > 150000) {
        gestures.add([]);
      }
      gestures.last.add(input);
    }

    final lags = <double>[];
    final lagTimes = <double>[];
    final catchUps = <double>[];
    final reverses = <double>[];
    final perGesture = <Map<String, Object>>[];
    var asked = 0.0, went = 0.0;
    for (final (g, inputs) in gestures.indexed) {
      final start = inputs.first.$1;
      final end = inputs.last.$1;
      final next = g + 1 < gestures.length ? gestures[g + 1].first.$1 : null;
      final before = _at(start - 1);
      // What the input asked so far, at time t.
      double askedAt(int t) {
        var sum = 0.0;
        for (final (at, delta) in inputs) {
          if (at > t) break;
          sum += delta;
        }
        return sum;
      }

      // What the input had asked by each of its times, from 0 before it.
      final reached = <(int, double)>[(start, 0)];
      var asking = 0.0;
      for (final (at, delta) in inputs) {
        asking += delta;
        reached.add((at, asking));
      }
      for (final (t, moved) in _frames) {
        if (t < start || t > end + frame) continue;
        final view = moved - before;
        lags.add((askedAt(t) - view).abs());
        // How long ago the input was where the view is: the latest stretch
        // between two inputs (by then) the view's place is on.
        if (t < start + frame) continue;
        for (var k = reached.length - 1; k > 0; k--) {
          final (t1, i1) = reached[k];
          if (t1 > t) continue;
          final (t0, i0) = reached[k - 1];
          final low = i0 < i1 ? i0 : i1, high = i0 < i1 ? i1 : i0;
          if (view < low - 0.01 || view > high + 0.01) continue;
          final s = high - low < 0.01 ? 1.0 : (view - i0) / (i1 - i0);
          lagTimes.add((t - (t0 + (t1 - t0) * s)) / 1000);
          break;
        }
      }
      var sum = 0.0;
      for (final (i, (at, delta)) in inputs.indexed) {
        final from = sum;
        sum += delta;
        if (delta.abs() < 0.5) continue;
        for (final (t, moved) in _frames) {
          if (t < at) continue;
          if (next != null && t >= next) break;
          if (((moved - before) - from) / delta >= 0.9) {
            catchUps.add((t - at) / 1000);
            break;
          }
        }
        // The other way from the input before: when the view turns.
        if (i > 0 && inputs[i - 1].$2.sign != delta.sign) {
          var last = _at(at);
          for (final (t, moved) in _frames) {
            if (t <= at) continue;
            if ((moved - last) * delta.sign > 0.5) {
              reverses.add((t - at) / 1000);
              break;
            }
            last = moved;
          }
        }
      }
      final lifted = _at(end + frame) - before;
      final stop = next ?? _frames.last.$1;
      var tailMs = 0.0;
      var last = _at(end + frame);
      for (final (t, moved) in _frames) {
        if (t <= end + frame || t >= stop) continue;
        if ((moved - last).abs() > 0.5) tailMs = (t - end) / 1000;
        last = moved;
      }
      final tail = _at(stop) - before - lifted;
      asked += sum;
      went += lifted;
      perGesture.add({
        'askedPx': sum.round(),
        'ratio': round(sum.abs() < 1 ? 1 : lifted / sum),
        'tailPx': tail.round(),
        'tailMs': tailMs.round(),
      });
    }
    return {
      'hitEnd': _hitEnd ? 1 : 0,
      'ratio': round(asked.abs() < 1 ? 1 : went / asked),
      'lagPx': _stats(lags),
      'lagMs': _stats(lagTimes),
      'catchUpMs': _stats(catchUps),
      if (reverses.isNotEmpty) 'reverseMs': _stats(reverses),
      'tailPx': _stats([
        for (final g in perGesture) (g['tailPx']! as int).abs().toDouble(),
      ]),
      'tailMs': _stats([
        for (final g in perGesture) (g['tailMs']! as int).toDouble(),
      ]),
      'gestures': perGesture,
    };
  }

  /// Where the view was at [t]: at the last frame by then.
  double _at(int t) {
    var moved = 0.0;
    for (final (at, m) in _frames) {
      if (at > t) break;
      moved = m;
    }
    return moved;
  }

  /// A frame's length, from the frames seen.
  int _frameUs() {
    final gaps = [
      for (var i = 1; i < _frames.length; i++)
        _frames[i].$1 - _frames[i - 1].$1,
    ]..sort();
    return gaps.isEmpty ? 16667 : gaps[gaps.length ~/ 4].clamp(4000, 34000);
  }

  static double round(double value) => (value * 100).roundToDouble() / 100;

  static Map<String, double> _stats(List<double> values) {
    if (values.isEmpty) return const {};
    values.sort();
    double at(double q) =>
        round(values[(values.length * q).floor().clamp(0, values.length - 1)]);
    return {'p50': at(.5), 'p90': at(.9), 'max': round(values.last)};
  }
}

/// [body], its view's following measured, into [r]'s `follow`.
Future<void> followed(
  PerfRecording r,
  PerfFollow follow,
  Future<void> Function() body,
) async {
  follow.start();
  try {
    await body();
  } finally {
    r.extra['follow'] = follow.stop();
  }
}
