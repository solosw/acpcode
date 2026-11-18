import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/models/gateway/gateway_settings.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';

class _Settings extends ChangeNotifier {
  Object? value;
  bool failWrite = false;
  Future<void> write(Object? next) async {
    if (failWrite) throw StateError('Cannot save');
    value = next;
    notifyListeners();
  }
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Gateway state did not settle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  test('defaults are disabled, with a fixed port and baocode key', () {
    final config = GatewayConfig.fromJson(null);
    expect(config.enabled, isFalse);
    expect(config.port, 8317);
    expect(config.apiKey, 'baocode');
    expect(config.useNetworkProxy, isTrue);
    expect(GatewayConfig.fromJson(config.toJson()), config);
    for (final config in [
      const GatewayConfig(port: 0),
      const GatewayConfig(port: 65536),
      const GatewayConfig(apiKey: ''),
      const GatewayConfig(apiKey: 'a b'),
      const GatewayConfig(apiKey: '中文'),
      GatewayConfig(apiKey: 'a${String.fromCharCode(127)}'),
    ]) {
      expect(config.validate, throwsFormatException);
    }
  });

  test(
    'saves, starts, rotates key, stops and restores persisted configuration',
    () async {
      final settings = _Settings();
      final providers = ModelProviders.memory();
      ModelGateway create() => ModelGateway(
        read: () => settings.value,
        write: settings.write,
        changes: settings,
        providers: providers,
      );
      final gateway = create();
      addTearDown(gateway.dispose);
      addTearDown(providers.dispose);
      addTearDown(settings.dispose);
      await gateway.start();
      expect(gateway.running, isFalse);
      final port = await _freePort();
      await gateway.update(
        GatewayConfig(enabled: true, port: port, useNetworkProxy: false),
      );
      expect(gateway.running, isTrue);
      expect(gateway.baseUrl, 'http://127.0.0.1:$port');
      expect(gateway.error, isNull);
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() => client.close(force: true));
      Future<int> list(String key) async {
        final request = await client.getUrl(
          Uri.parse('${gateway.baseUrl!}/v1/models'),
        );
        request.headers.set('Authorization', 'Bearer $key');
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await list('baocode'), 200);
      await gateway.update(
        GatewayConfig(
          enabled: true,
          port: port,
          apiKey: 'changed',
          useNetworkProxy: false,
        ),
      );
      expect(await list('baocode'), 401);
      expect(await list('changed'), 200);
      await expectLater(
        gateway.update(GatewayConfig(enabled: true, port: 0)),
        throwsFormatException,
      );
      expect(await list('changed'), 200);
      settings.failWrite = true;
      await expectLater(
        gateway.update(GatewayConfig(port: port)),
        throwsStateError,
      );
      expect(gateway.running, isTrue);
      settings.failWrite = false;
      await gateway.close();
      final restored = create();
      addTearDown(restored.dispose);
      await restored.start();
      expect(restored.running, isTrue);
      expect(restored.config.apiKey, 'changed');
      await restored.update(GatewayConfig(port: port));
      expect(restored.running, isFalse);
      final rebound = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await rebound.close();
      await restored.close();
    },
  );

  test(
    'bind failures are visible and the same configuration can retry',
    () async {
      final settings = _Settings();
      final providers = ModelProviders.memory();
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final config = GatewayConfig(
        enabled: true,
        port: occupied.port,
        useNetworkProxy: false,
      );
      settings.value = config.toJson();
      final gateway = ModelGateway(
        read: () => settings.value,
        write: settings.write,
        changes: settings,
        providers: providers,
      );
      addTearDown(gateway.dispose);
      addTearDown(providers.dispose);
      addTearDown(settings.dispose);
      await gateway.start();
      expect(gateway.running, isFalse);
      expect(gateway.error, isNotNull);
      expect(gateway.config.enabled, isTrue);
      await occupied.close();
      await gateway.update(config);
      expect(gateway.running, isTrue);
      expect(gateway.error, isNull);
      await gateway.close();
    },
  );

  test(
    'external settings changes win over an in-flight proxy resolution',
    () async {
      final settings = _Settings();
      final providers = ModelProviders.memory();
      final route = Completer<ProxyRoute>();
      final resolving = Completer<void>();
      final network = NetworkProxy(
        system: () {
          if (!resolving.isCompleted) resolving.complete();
          return route.future;
        },
        environment: () async => {},
      );
      final port = await _freePort();
      settings.value = GatewayConfig(enabled: true, port: port).toJson();
      final gateway = ModelGateway(
        read: () => settings.value,
        write: settings.write,
        changes: settings,
        providers: providers,
        network: network,
      );
      addTearDown(gateway.dispose);
      addTearDown(providers.dispose);
      addTearDown(settings.dispose);
      final started = gateway.start();
      await resolving.future;
      await settings.write(GatewayConfig(port: port).toJson());
      route.complete(const ProxyRoute.direct());
      await started;
      await _until(() => !gateway.starting && !gateway.running);
      expect(gateway.config.enabled, isFalse);
      expect(gateway.error, isNull);
      await gateway.close();
    },
  );

  test('gateway follows BaoCode network proxy and can bypass it', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    proxy.listen((request) async {
      seen.add(request.uri.toString());
      expect(request.headers.value('authorization'), isNot('Bearer baocode'));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'id': 'chat', 'choices': []}));
      await request.response.close();
    });
    addTearDown(() => proxy.close(force: true));
    final values = _Settings();
    final network = NetworkProxy(environment: () async => {});
    network.follow(
      values,
      (key) => key == ProxyMode.settingKey
          ? 'manual'
          : key == ProxyMode.urlKey
          ? 'http://127.0.0.1:${proxy.port}'
          : null,
    );
    final providers = ModelProviders.memory(
      providers: [
        const ModelProvider(
          id: 'up',
          name: 'Upstream',
          baseUrl: 'http://upstream.invalid',
          protocol: ProviderProtocol.openaiChat,
          models: [ProviderModel(id: 'model')],
        ),
      ],
    );
    final gateway = ModelGateway(
      read: () => values.value,
      write: values.write,
      changes: values,
      providers: providers,
      network: network,
    );
    addTearDown(gateway.dispose);
    addTearDown(providers.dispose);
    addTearDown(values.dispose);
    final port = await _freePort();
    await gateway.start();
    await gateway.update(GatewayConfig(enabled: true, port: port));
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
    Future<int> send() async {
      final request = await client.postUrl(
        Uri.parse('${gateway.baseUrl!}/v1/chat/completions'),
      );
      request.headers.set('Authorization', 'Bearer baocode');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': '@up/model',
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
        }),
      );
      final answer = await request.close();
      await answer.drain<void>();
      return answer.statusCode;
    }

    expect(await send(), 200);
    expect(seen, ['http://upstream.invalid/v1/chat/completions']);
    await gateway.update(
      GatewayConfig(enabled: true, port: port, useNetworkProxy: false),
    );
    expect(await send(), 502);
    expect(seen, hasLength(1));
    await gateway.close();
    await gateway.close();
    await expectLater(
      gateway.update(GatewayConfig(port: port)),
      throwsStateError,
    );
  });
}
