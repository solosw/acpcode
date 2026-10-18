import 'dart:ui' show FlutterView, ViewFocusEvent;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../platform/event_log.dart';

/// Writes to the event log ([appEvent]) what the engine tells the app and
/// what it draws: the app coming to the front and going, views (windows)
/// added, removed, emptied or focused, memory running low; and, at each
/// frame, a view of the engine's left undrawn (none of the widgets' views
/// is its) or drawn again — the window that shows nothing, with no error.
class AppEventWatch with WidgetsBindingObserver {
  AppEventWatch._();

  static AppEventWatch? _current;

  /// Starts watching, once.
  static void start() {
    if (_current != null) return;
    final watch = _current = AppEventWatch._();
    final binding = WidgetsBinding.instance;
    binding.addObserver(watch);
    binding.addPersistentFrameCallback((_) => watch._frame());
    watch._views = _metricsOf(binding.platformDispatcher.views);
    appEvent(
      'app',
      'started, ${binding.lifecycleState?.name ?? 'no lifecycle yet'}; '
          '${appViewStates()}',
    );
  }

  /// Each view's size and pixel ratio, as last told.
  Map<int, String> _views = {};

  /// The views drawn at the last frame.
  Set<int> _drawn = {};

  static Map<int, String> _metricsOf(Iterable<FlutterView> views) => {
    for (final view in views) view.viewId: _metrics(view),
  };

  static String _metrics(FlutterView view) {
    final size = view.physicalSize;
    return '${size.width.round()}x${size.height.round()}'
        '@${view.devicePixelRatio}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appEvent('app', 'lifecycle ${state.name}');
    if (state == AppLifecycleState.resumed) {
      appEvent('views', 'resumed: ${appViewStates()}');
    }
  }

  @override
  void didChangeMetrics() {
    final now = _metricsOf(WidgetsBinding.instance.platformDispatcher.views);
    for (final MapEntry(key: id, value: metrics) in now.entries) {
      final before = _views[id];
      if (before == null) {
        appEvent('views', 'view $id added, $metrics');
      } else if (_changedNotably(before, metrics)) {
        // A window resized is not told: its size going to nothing or
        // coming back, and its pixel ratio, are.
        appEvent('views', 'view $id $before -> $metrics');
      }
    }
    for (final id in _views.keys) {
      if (!now.containsKey(id)) appEvent('views', 'view $id removed');
    }
    _views = now;
  }

  static bool _changedNotably(String before, String after) {
    bool empty(String metrics) =>
        metrics.startsWith('0x') || metrics.contains('x0@');
    String ratio(String metrics) => metrics.substring(metrics.indexOf('@'));
    return empty(before) != empty(after) || ratio(before) != ratio(after);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    appEvent('views', 'view ${event.viewId} ${event.state.name}');
  }

  @override
  void didHaveMemoryPressure() => appEvent('app', 'memory pressure');

  void _frame() {
    final binding = WidgetsBinding.instance;
    final drawn = {
      for (final view in binding.renderViews) view.flutterView.viewId,
    };
    final before = _drawn;
    _drawn = drawn;
    if (setEquals(before, drawn)) return;
    final engine = {
      for (final view in binding.platformDispatcher.views) view.viewId,
    };
    final undrawn = engine.difference(drawn);
    appEvent(
      'views',
      'drawn ${_ids(drawn)} (were ${_ids(before)})'
          '${undrawn.isEmpty ? '' : ', the engine\'s ${_ids(undrawn)} not'}',
    );
  }

  static String _ids(Set<int> ids) => '[${(ids.toList()..sort()).join(', ')}]';
}

/// Each of the engine's views as it is drawn now: its size, whether the
/// widgets draw it at all, and what its last frame painted (its layers'
/// pictures: none is a blank window); then whether frames are drawn.
String appViewStates() {
  final binding = WidgetsBinding.instance;
  final renderViews = {
    for (final view in binding.renderViews) view.flutterView.viewId: view,
  };
  final parts = <String>[];
  for (final view in binding.platformDispatcher.views) {
    final metrics = AppEventWatch._metrics(view);
    final render = renderViews.remove(view.viewId);
    if (render == null) {
      parts.add('view ${view.viewId} $metrics not drawn');
      continue;
    }
    parts.add(
      'view ${view.viewId} $metrics '
      'laid out ${_size(render.size)}'
      '${render.child == null ? ', no child' : ''}, '
      // Its layer, read as the framework reads it (debugLayer is none in
      // a release build, where this is wanted).
      // ignore: invalid_use_of_protected_member
      '${_pictures(render.layer)} pictures',
    );
  }
  for (final id in renderViews.keys) {
    parts.add('render view $id without the engine\'s');
  }
  final scheduler = SchedulerBinding.instance;
  parts.add(
    'frames ${scheduler.framesEnabled ? 'on' : 'off'}, '
    '${scheduler.schedulerPhase.name}',
  );
  return parts.join('; ');
}

String _size(Size size) =>
    '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';

/// The picture layers under [layer], up to a count that tells enough.
int _pictures(Layer? layer) {
  const most = 1000;
  var count = 0;
  void visit(Layer? layer) {
    while (layer != null && count < most) {
      if (layer is PictureLayer) count++;
      if (layer is ContainerLayer) visit(layer.firstChild);
      layer = layer.nextSibling;
    }
  }

  visit(layer);
  return count;
}
