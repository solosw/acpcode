// A headless MCP stdio client of the app's conversation-scoped HTTP bridge.
// It runs on the SSH host; the loopback URL is forwarded to the app over RPC.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

abstract final class ServerMcp {
  static const command = 'mcp-stdio';
  static const urlVariable = 'BAOCODE_MCP_URL';
  static const tokenVariable = 'BAOCODE_MCP_TOKEN';

  /// The installed server, or the absolute script when running from source.
  /// Independent of ServerClaude's override: the two helpers run different jobs.
  static List<String> Function() selfCommand = () => [
    Platform.resolvedExecutable,
    if (Platform.script.path.endsWith('.dart')) Platform.script.toFilePath(),
  ];

  /// MCP alone on stdout. Credentials come only from the process environment,
  /// never command arguments, disk, redirects, proxies, or diagnostic messages.
  static Future<int> runStdio({
    Map<String, String>? environment,
    Stream<List<int>>? input,
    IOSink? output,
    IOSink? diagnostics,
    Duration drainTimeout = const Duration(seconds: 2),
  }) async {
    var code = 3;
    try {
      final env = environment ?? Platform.environment;
      final url = Uri.tryParse(env[urlVariable] ?? '');
      final token = env[tokenVariable] ?? '';
      if (url == null ||
          url.scheme != 'http' ||
          url.host != '127.0.0.1' ||
          !url.hasPort ||
          url.port < 1 ||
          url.port > 65535 ||
          url.authority != '127.0.0.1:${url.port}' ||
          url.path != '/mcp' ||
          url.hasQuery ||
          url.hasFragment ||
          token.isEmpty ||
          token.contains(RegExp(r'[\x00-\x20\x7f]'))) {
        throw const FormatException('Invalid MCP connection');
      }
      code = await _StdioRelay(
        url,
        token,
        input ?? stdin,
        output ?? stdout.nonBlocking,
        drainTimeout,
      ).run();
    } on Object {
      // Even HTTP exceptions may contain the URL or headers. Never print them.
    }
    if (code != 0) {
      final errors = diagnostics ?? stderr.nonBlocking;
      try {
        errors.writeln('BaoCode MCP: the tools connection ended.');
        await errors.flush().timeout(const Duration(seconds: 2));
      } on Object {
        // The parent may already have closed its pipes.
      }
    }
    return code;
  }
}

class _StdioRelay {
  _StdioRelay(this.url, this.token, this.input, this.output, this.drainTimeout);

  final Uri url;
  final String token;
  final Stream<List<int>> input;
  final IOSink output;
  final Duration drainTimeout;
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = ((_) => 'DIRECT');
  final _done = Completer<int>();
  StreamSubscription<String>? _messages;
  StreamSubscription<String>? _events;
  Future<void> _writes = Future.value();
  Timer? _drain;
  var _pending = 0;
  final _pendingRequests = <Object>{};
  var _inputEnded = false;
  var _writeFailed = false;
  String? _version;

  Future<int> run() async {
    var code = 3;
    try {
      // Open before accepting requests: list_changed cannot race initialize,
      // and revocation ends an idle relay even while its stdin stays open.
      await _listenEvents();
      if (!_done.isCompleted) {
        _messages = input
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              _read,
              onError: (Object _) => _finish(3),
              onDone: () {
                _inputEnded = true;
                if (_pending > 0) {
                  _drain = Timer(drainTimeout, () => _finish(3));
                }
                _settled();
              },
            );
      }
      code = await _done.future;
    } on Object {
      // Transport and decoding failures are intentionally indistinguishable.
    } finally {
      _drain?.cancel();
      // Closing stateless HTTP alone does not cancel app-side calls. A child
      // may exit while its ACP conversation (and bearer capability) lives on.
      if (_pendingRequests.isNotEmpty) {
        final cancellations = <Future<void>>[];
        for (final id in _pendingRequests.toList()) {
          _pending++;
          cancellations.add(
            _post({
              'jsonrpc': '2.0',
              'method': 'notifications/cancelled',
              'params': {'requestId': id},
            }),
          );
        }
        try {
          await Future.wait(cancellations)
              .timeout(const Duration(milliseconds: 250));
        } on Object {
          // A broken or revoked bridge cannot acknowledge cancellation.
        }
      }
      _http.close(force: true);
      await _messages?.cancel();
      await _events?.cancel();
      try {
        // A closed or unconsumed stdout must not retain a headless child.
        await _writes.timeout(drainTimeout);
      } on Object {
        code = 3;
      }
    }
    return _writeFailed ? 3 : code;
  }

  void _finish(int code) {
    if (!_done.isCompleted) _done.complete(code);
  }

  void _settled() {
    if (_inputEnded && _pending == 0) _finish(0);
  }

  void _headers(HttpClientRequest request, {required bool events}) {
    request.followRedirects = false;
    request.headers.set('authorization', 'Bearer $token');
    request.headers.set(
      'accept',
      events ? 'text/event-stream' : 'application/json, text/event-stream',
    );
    if (_version case final version?) {
      request.headers.set('mcp-protocol-version', version);
    }
  }

  Future<void> _listenEvents() async {
    final request = await _http.getUrl(url);
    _headers(request, events: true);
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != HttpStatus.ok ||
        response.headers.contentType?.mimeType != 'text/event-stream') {
      throw const FormatException('MCP events unavailable');
    }
    final data = <String>[];
    _events = response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.isEmpty) {
              if (data.isEmpty) return;
              try {
                final message = jsonDecode(data.join('\n'));
                if (message is! Map<String, Object?> ||
                    message['jsonrpc'] != '2.0') {
                  throw const FormatException('Invalid MCP event');
                }
                _emit(message);
              } on Object {
                _finish(3);
              }
              data.clear();
            } else if (line.startsWith('data:')) {
              final value = line.substring(5);
              data.add(value.startsWith(' ') ? value.substring(1) : value);
            }
          },
          onError: (Object _) => _finish(3),
          onDone: () => _finish(3),
        );
  }

  void _read(String line) {
    if (line.trim().isEmpty || _done.isCompleted) return;
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      _emit(_error(null, -32700, 'Parse error'));
      return;
    }
    if (message is! Map<String, Object?> ||
        message['jsonrpc'] != '2.0' ||
        message['method'] is! String ||
        (message.containsKey('params') && message['params'] is! Map) ||
        (message.containsKey('id') &&
            message['id'] is! String &&
            message['id'] is! num)) {
      _emit(
        _error(
          message is Map ? message['id'] : null,
          -32600,
          'Invalid Request',
        ),
      );
      return;
    }
    _pending++;
    if (message['id'] case final Object id) _pendingRequests.add(id);
    // Do not serialize POSTs: cancellation and other calls must reach the app
    // while a long-running tools/call is still waiting for its result.
    unawaited(_post(message));
  }

  Future<void> _post(Map<String, Object?> message) async {
    try {
      final request = await _http.postUrl(url);
      _headers(request, events: false);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(message));
      final response = await request.close();
      if (!message.containsKey('id') &&
          response.statusCode == HttpStatus.accepted) {
        await response.drain<void>();
      } else if (message.containsKey('id') &&
          response.statusCode == HttpStatus.ok &&
          response.headers.contentType?.mimeType == 'application/json') {
        final answer = jsonDecode(await utf8.decoder.bind(response).join());
        if (answer is! Map<String, Object?> ||
            answer['jsonrpc'] != '2.0' ||
            answer['id'] != message['id'] ||
            (!answer.containsKey('result') && !answer.containsKey('error'))) {
          throw const FormatException('Invalid MCP response');
        }
        if (message['method'] == 'initialize') {
          final result = answer['result'];
          if (result is Map && result['protocolVersion'] is String) {
            _version = result['protocolVersion'] as String;
          }
        }
        _emit(answer);
      } else {
        throw const FormatException('MCP request failed');
      }
    } on Object {
      _finish(3);
    } finally {
      if (message.containsKey('id')) _pendingRequests.remove(message['id']);
      _pending--;
      _settled();
    }
  }

  void _emit(Map<String, Object?> message) {
    if (_done.isCompleted) return;
    _writes = _writes.then((_) async {
      try {
        output.writeln(jsonEncode(message));
        await output.flush();
      } on Object {
        _writeFailed = true;
        _finish(3);
      }
    });
  }

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}
