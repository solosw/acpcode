import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'proxy_settings.dart';

/// Temporary authenticated HTTP/CONNECT relay. TLS stays end-to-end and
/// upstream proxy credentials never leave this machine for the remote host.
class InstallProxyRelay {
  InstallProxyRelay._(this._server, this.route, this.token) {
    _server.listen(
      (socket) => unawaited(_serve(socket)),
      onError: (Object _) {},
    );
  }

  static Future<InstallProxyRelay> open(ProxyRoute route) async {
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    return InstallProxyRelay._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      route,
      token,
    );
  }

  final ServerSocket _server;
  final ProxyRoute route;
  final String token;
  final Set<Socket> _sockets = {};
  bool _closed = false;
  int get port => _server.port;
  String get authorization =>
      'Basic ${base64Encode(utf8.encode('baocode:$token'))}';

  Future<void> _serve(Socket incoming) async {
    if (_closed) {
      incoming.destroy();
      return;
    }
    _sockets.add(incoming);
    final input = StreamIterator<Uint8List>(incoming);
    Socket? upstream;
    StreamIterator<Uint8List>? output;
    try {
      final head = await _header(input);
      final lines = latin1.decode(head.header).split('\r\n');
      final request = lines.first.split(' ');
      if (request.length != 3) throw const FormatException('Invalid request');
      final supplied = lines
          .skip(1)
          .where(
            (line) => line.toLowerCase().startsWith('proxy-authorization:'),
          );
      if (supplied.length != 1 ||
          supplied.single.substring(supplied.single.indexOf(':') + 1).trim() !=
              authorization) {
        incoming.write(
          'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="BaoCode install"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
        );
        await incoming.flush();
        return;
      }
      final connect = request[0] == 'CONNECT';
      final uri = Uri.parse(connect ? 'https://${request[1]}' : request[1]);
      if (uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (connect ? uri.scheme != 'https' : uri.scheme != 'http') ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw const FormatException('Invalid proxy destination');
      }
      final proxy = route.serverFor(uri);
      upstream = await Socket.connect(
        proxy?.host ?? uri.host,
        proxy?.port ?? uri.port,
        timeout: const Duration(seconds: 20),
      );
      if (_closed) return;
      _sockets.add(upstream);
      output = StreamIterator<Uint8List>(upstream);
      final credentials = proxy?.username == null
          ? null
          : base64Encode(
              utf8.encode('${proxy!.username}:${proxy.password ?? ''}'),
            );
      final auth = credentials == null
          ? ''
          : 'Proxy-Authorization: Basic $credentials\r\n';
      if (connect) {
        if (proxy != null) {
          upstream.write(
            'CONNECT ${request[1]} HTTP/1.1\r\nHost: ${request[1]}\r\n$auth\r\n',
          );
          await upstream.flush();
          final response = await _header(output);
          if (!RegExp(r'^HTTP/1[.][01] 200(?: |\r)')
              .hasMatch(latin1.decode(response.header))) {
            throw const HttpException('Upstream proxy refused CONNECT');
          }
          incoming.write('HTTP/1.1 200 Connection Established\r\n\r\n');
          incoming.add(response.extra);
        } else {
          incoming.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        }
      } else {
        final target = proxy == null
            ? '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}'
            : uri.toString();
        final headers = lines
            .skip(1)
            .where(
              (line) =>
                  line.isNotEmpty &&
                  !line.toLowerCase().startsWith('proxy-authorization:') &&
                  !line.toLowerCase().startsWith('proxy-connection:') &&
                  !line.toLowerCase().startsWith('connection:'),
            );
        upstream.write(
          '${request[0]} $target HTTP/1.1\r\n${headers.join('\r\n')}\r\nConnection: close\r\n$auth\r\n',
        );
      }
      upstream.add(head.extra);
      await upstream.flush();
      await incoming.flush();
      await Future.any([_pipe(input, upstream), _pipe(output, incoming)]);
    } on Object {
      try {
        incoming.write(
          'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
        );
        await incoming.flush();
      } on Object {
        /* The peer may already be gone. */
      }
    } finally {
      incoming.destroy();
      upstream?.destroy();
      _sockets.remove(incoming);
      _sockets.remove(upstream);
      await input.cancel();
      await output?.cancel();
    }
  }

  static Future<void> _pipe(
    StreamIterator<Uint8List> input,
    Socket output,
  ) async {
    while (await input.moveNext()) {
      output.add(input.current);
      await output.flush();
    }
  }

  static Future<({List<int> header, List<int> extra})> _header(
    StreamIterator<Uint8List> input,
  ) async {
    final bytes = <int>[];
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (await input.moveNext().timeout(
      deadline.difference(DateTime.now()),
    )) {
      final start = max(0, bytes.length - 3);
      bytes.addAll(input.current);
      for (var i = start; i + 3 < bytes.length; i++) {
        if (bytes[i] == 13 &&
            bytes[i + 1] == 10 &&
            bytes[i + 2] == 13 &&
            bytes[i + 3] == 10) {
          if (i > 65536) throw const FormatException('Headers too large');
          return (header: bytes.sublist(0, i + 2), extra: bytes.sublist(i + 4));
        }
      }
      if (bytes.length > 65536) {
        throw const FormatException('Headers too large');
      }
    }
    throw const FormatException('Incomplete headers');
  }

  Future<void> close() async {
    _closed = true;
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
  }
}
