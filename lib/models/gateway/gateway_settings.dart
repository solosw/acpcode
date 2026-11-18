import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../network/network_proxy_io.dart';
import '../../settings/user_settings.dart';
import '../../usage/usage_ledger.dart';
import '../../workspace/editor_launcher.dart';
import '../codex/codex_accounts_io.dart';
import '../model_providers.dart';
import 'gateway_server.dart';

/// The optional loopback service, kept as one settings.json value.
class GatewayConfig {
  const GatewayConfig({
    this.enabled = false,
    this.port = 8317,
    this.apiKey = 'baocode',
    this.useNetworkProxy = true,
  });

  final bool enabled;
  final int port;
  final String apiKey;
  final bool useNetworkProxy;

  factory GatewayConfig.fromJson(Object? value) {
    final json = value is Map ? value : const {};
    return GatewayConfig(
      enabled: json['enabled'] == true,
      port: json['port'] is int ? json['port'] as int : 8317,
      apiKey: json['apiKey'] is String ? json['apiKey'] as String : 'baocode',
      useNetworkProxy: json['useNetworkProxy'] != false,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'port': port,
    'apiKey': apiKey,
    'useNetworkProxy': useNetworkProxy,
  };

  void validate() {
    if (port < 1 || port > 65535) {
      throw const FormatException('Port must be between 1 and 65535.');
    }
    if (apiKey.isEmpty || apiKey.codeUnits.any((c) => c <= 32 || c >= 127)) {
      throw const FormatException(
        'The API key must contain printable ASCII without spaces.',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GatewayConfig &&
      other.enabled == enabled &&
      other.port == port &&
      other.apiKey == apiKey &&
      other.useNetworkProxy == useNetworkProxy;

  @override
  int get hashCode => Object.hash(enabled, port, apiKey, useNetworkProxy);
}

/// Owns the gateway across settings pages and stops it when BaoCode exits.
class ModelGateway extends ChangeNotifier {
  ModelGateway({
    required this._read,
    required this._write,
    required this._changes,
    required this._providers,
    NetworkProxy? network,
  }) : _network = network ?? NetworkProxy.instance {
    _config = GatewayConfig.fromJson(_read());
  }

  factory ModelGateway.settings(
    UserSettings settings,
    ModelProviders providers,
  ) => ModelGateway(
    read: () => settings[settingKey],
    write: (value) => settings.update(settingKey, value),
    changes: settings,
    providers: providers,
  );

  static const settingKey = 'models.gateway';
  static ModelGateway? current;
  final Object? Function() _read;
  final Future<void> Function(Object? value) _write;
  final Listenable _changes;
  final ModelProviders _providers;
  final NetworkProxy _network;
  late GatewayConfig _config;
  GatewayConfig? _applied;
  GatewayServer? _server;
  Future<void> _tail = Future.value();
  bool _following = false;
  bool _closed = false;
  bool _disposed = false;
  bool _starting = false;
  String? _error;

  GatewayConfig get config => _config;
  bool get running => _server?.port != null;
  bool get starting => _starting;
  String? get error => _error;
  String? get baseUrl => _server?.baseUrl;

  Future<void> start() {
    if (_closed) return Future.value();
    if (!_following) {
      _following = true;
      _changes.addListener(_changed);
    }
    return _schedule();
  }

  void _changed() {
    if (_closed) return;
    final next = GatewayConfig.fromJson(_read());
    if (next == _config) return;
    _config = next;
    _notify();
    unawaited(_schedule());
  }

  Future<void> update(GatewayConfig config) async {
    if (_closed) throw StateError('Gateway is closed');
    config.validate();
    await _write(config.toJson());
    if (_closed) return;
    _config = GatewayConfig.fromJson(_read());
    _notify();
    await _schedule();
  }

  Future<void> _schedule() => _tail = _tail.then((_) => _apply());

  Future<void> _apply() async {
    if (_closed) return;
    final wanted = _config;
    if (wanted == _applied && (!wanted.enabled || running)) return;
    _starting = true;
    _error = null;
    _notify();
    try {
      final previous = _server;
      _server = null;
      _applied = null;
      await previous?.close();
      if (_closed || wanted != _config) return;
      wanted.validate();
      if (wanted.enabled) {
        if (wanted.useNetworkProxy) await _network.resolve();
        if (_closed || wanted != _config) return;
        String route(Uri url) =>
            wanted.useNetworkProxy ? _network.findProxy(url) : 'DIRECT';
        final server = GatewayServer(
          providers: _providers,
          apiKey: wanted.apiKey,
          findProxy: route,
          codex: CodexAccounts(
            providers: () => _providers,
            findProxy: route,
            openBrowser: openExternal,
          ),
          usage: () => UsageLedger.current,
        );
        _server = server;
        await server.start(port: wanted.port);
        if (_closed || wanted != _config) {
          _server = null;
          await server.close();
          return;
        }
      }
      _applied = wanted;
    } on Object catch (error) {
      final failed = _server;
      _server = null;
      await failed?.close();
      // Bind errors should appear in Settings, never fail application startup.
      _error = '$error';
    } finally {
      _starting = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() {
    _closed = true;
    if (_following) {
      _following = false;
      _changes.removeListener(_changed);
    }
    return _tail = _tail.then((_) async {
      final server = _server;
      _server = null;
      await server?.close();
      _starting = false;
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
