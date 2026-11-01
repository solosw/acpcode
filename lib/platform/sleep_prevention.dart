import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../settings/user_settings.dart';
import 'app_platform.dart';

/// One owner in the main window keeps the local computer awake while the
/// app runs, including when hidden in the tray. Never changes the OS's
/// saved power settings. Prevents both system and display idle sleep.
class SleepPrevention {
  SleepPrevention(
    this.settings, {
    Future<void> Function(bool enabled)? setEnabled,
    this.onError,
  }) : _setEnabled = setEnabled ?? _setNative;

  static const settingKey = 'window.preventSleep';
  static bool get supported => AppPlatform.isDesktop;
  final UserSettings settings;
  final Future<void> Function(bool enabled) _setEnabled;
  final void Function(Object error)? onError;
  bool _started = false;
  bool _disposed = false;
  bool? _requested;
  Future<void> _pending = Future.value();
  Future<void> get settled => _pending;

  Future<void> start() {
    if (_started || _disposed) return _pending;
    _started = true;
    settings.addListener(_changed);
    _changed();
    return _pending;
  }

  void _changed() {
    if (_disposed) return;
    final enabled = settings[settingKey] == true;
    if (_requested == enabled) return;
    _requested = enabled;
    _enqueue(enabled);
  }

  void _enqueue(bool enabled) {
    // Rapid setting changes and shutdown must not let an earlier enable
    // finish after the final disable.
    _pending = _pending.then((_) => _setEnabled(enabled)).catchError((
      Object error,
    ) {
      _requested = null;
      if (!_disposed) {
        if (onError case final report?) {
          report(error);
        } else {
          debugPrint('Could not change sleep prevention: $error');
        }
      }
    });
  }

  Future<void> dispose() {
    if (_disposed) return _pending;
    _disposed = true;
    if (_started) {
      settings.removeListener(_changed);
      _enqueue(false);
    }
    return _pending;
  }

  static Future<void> _setNative(bool enabled) async {
    if (!supported) return;
    try {
      // Always the main engine's channel, never an agent/IDE window's.
      await const MethodChannel('baocode/window')
          .invokeMethod<void>('setPreventSleep', enabled);
    } on MissingPluginException {
      if (enabled) rethrow;
    }
  }
}
