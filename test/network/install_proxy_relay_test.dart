import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/network/install_proxy_relay.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:baocode/remote/remote_acp_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/remote_harness.dart';

Future<String> exchange(int port, String request) async {
  final socket = await Socket.connect('127.0.0.1', port);
  try {
    socket.write(request);
    return await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
  } finally {
    socket.destroy();
  }
}

void main() {
  test('remote HTTP follows local bypass route and strips relay authentication', () async {
    final harness = await RemoteHarness.start();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<HttpRequest>();
    origin.listen((request) async {
      received.complete(request);
      request.response.headers.set('Connection', 'close');
      request.response.write('package bytes');
      await request.response.close();
    });
    final network = await RemoteInstallNetwork.open(
      harness.client,
      const ProxyRoute(
        source: ProxySource.manual,
        http: ProxyServer('127.0.0.1', 1),
      ),
    );
    final port = network.forward.remotePort;
    try {
      final response = await exchange(
        port,
        'GET http://127.0.0.1:${origin.port}/package?q=1 HTTP/1.1\r\n'
        'Host: 127.0.0.1:${origin.port}\r\nProxy-Authorization: ${network.relay.authorization}\r\n\r\n',
      );
      expect(response, contains('package bytes'));
      final request = await received.future;
      expect(request.uri.toString(), '/package?q=1');
      expect(request.headers.value('proxy-authorization'), isNull);
      expect(network.environment['HTTPS_PROXY'], contains('127.0.0.1:$port'));
      expect(network.environment['NO_PROXY'], isEmpty);
      expect(network.environment['ALL_PROXY'], isEmpty);
    } finally {
      await network.close();
      await origin.close(force: true);
      await harness.close();
    }
    await expectLater(
      Socket.connect('127.0.0.1', port),
      throwsA(isA<SocketException>()),
    );
  });

  test(
    'HTTP proxy requests use upstream credentials, not the tunnel token',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final observed = Completer<({String uri, String? auth})>();
      proxy.listen((request) async {
        observed.complete((
          uri: request.uri.toString(),
          auth: request.headers.value('proxy-authorization'),
        ));
        request.response.headers.set('Connection', 'close');
        request.response.write('via upstream');
        await request.response.close();
      });
      final relay = await InstallProxyRelay.open(
        ProxyRoute(
          source: ProxySource.manual,
          http: ProxyServer(
            '127.0.0.1',
            proxy.port,
            username: 'user',
            password: 'pass',
          ),
        ),
      );
      try {
        final response = await exchange(
          relay.port,
          'GET http://package.example/archive HTTP/1.1\r\nHost: package.example\r\n'
          'Proxy-Authorization: ${relay.authorization}\r\n\r\n',
        );
        expect(response, contains('via upstream'));
        final request = await observed.future;
        expect(request.uri, contains('package.example/archive'));
        expect(request.auth, 'Basic ${base64Encode(utf8.encode('user:pass'))}');
        expect(request.auth, isNot(relay.authorization));
      } finally {
        await relay.close();
        await proxy.close(force: true);
      }
    },
  );

  test('unauthenticated relay cannot reach upstream', () async {
    final relay = await InstallProxyRelay.open(const ProxyRoute.direct());
    try {
      final response = await exchange(
        relay.port,
        'GET http://no-such-install-host.invalid/ HTTP/1.1\r\nHost: no-such-install-host.invalid\r\n\r\n',
      );
      expect(response, startsWith('HTTP/1.1 407'));
    } finally {
      await relay.close();
    }
  });

  test('CONNECT relays opaque bytes and keeps upstream credentials local', () async {
    final harness = await RemoteHarness.start();
    final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final headers = Completer<String>();
    final sockets = <Socket>[];
    upstream.listen((socket) {
      sockets.add(socket);
      var handshaken = false;
      var pending = '';
      socket.listen((bytes) {
        if (handshaken) {
          socket.add(bytes);
          return;
        }
        pending += utf8.decode(bytes);
        if (!pending.contains('\r\n\r\n')) return;
        headers.complete(pending);
        handshaken = true;
        socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      });
    });
    final network = await RemoteInstallNetwork.open(
      harness.client,
      ProxyRoute(
        source: ProxySource.manual,
        https: ProxyServer(
          '127.0.0.1',
          upstream.port,
          username: 'upstream-user',
          password: 'upstream-secret',
        ),
      ),
    );
    final socket = await Socket.connect(
      '127.0.0.1',
      network.forward.remotePort,
    );
    final chunks = StreamIterator(socket);
    try {
      socket.write(
        'CONNECT package.example:443 HTTP/1.1\r\nHost: package.example:443\r\n'
        'Proxy-Authorization: ${network.relay.authorization}\r\n\r\n',
      );
      expect(
        await chunks.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(
        utf8.decode(chunks.current),
        contains('200 Connection Established'),
      );
      socket.add([0, 1, 2, 255]);
      final echoed = <int>[];
      while (echoed.length < 4 &&
          await chunks.moveNext().timeout(const Duration(seconds: 5))) {
        echoed.addAll(chunks.current);
      }
      expect(echoed, [0, 1, 2, 255]);
      expect(await headers.future, contains('CONNECT package.example:443'));
      expect(
        await headers.future,
        contains(base64Encode(utf8.encode('upstream-user:upstream-secret'))),
      );
      expect(
        network.environment.toString(),
        isNot(contains('upstream-secret')),
      );
      expect(network.environment.toString(), isNot(contains('upstream-user')));
    } finally {
      socket.destroy();
      await chunks.cancel();
      await network.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await upstream.close();
      await harness.close();
    }
  });

  test('upstream failure returns 502 with no direct fallback', () async {
    final relay = await InstallProxyRelay.open(
      const ProxyRoute(
        source: ProxySource.manual,
        https: ProxyServer('127.0.0.1', 1),
      ),
    );
    try {
      final response = await exchange(
        relay.port,
        'CONNECT package.example:443 HTTP/1.1\r\nHost: package.example:443\r\n'
        'Proxy-Authorization: ${relay.authorization}\r\n\r\n',
      );
      expect(response, startsWith('HTTP/1.1 502'));
    } finally {
      await relay.close();
    }
  });
}
