// One in-process Streamable HTTP listener for all local ACP conversations.
// Per-conversation bearer capabilities never go in user/project configuration.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../kernel/claude_code/claude_sdk_tools.dart';

/// An ACP conversation's access to the shared listener, not a child process.
class ToolsHttpConnection {
  ToolsHttpConnection(this.configuration, this.close);

  final Map<String, Object?> configuration;
  final void Function() close;
}

class ToolsHttpServer {
  static final _random = Random.secure();
  static int _nextClient = 0;
  static const _versions = ['2025-11-25', '2025-06-18', '2025-03-26'];
  static const _maxBody = 1024 * 1024;
  final _clients = <String, _Client>{};
  HttpServer? _server;
  Future<void>? _starting;

  Uri? get url => _server == null
      ? null
      : Uri.parse('http://127.0.0.1:${_server!.port}/mcp');

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  ToolsHttpConnection open({required String cwd}) {
    final endpoint = url;
    if (endpoint == null) throw StateError('MCP HTTP listener is not running');
    final key = base64Url.encode(
      List.generate(32, (_) => _random.nextInt(256)),
    );
    final client = _Client(cwd, 'mcp-http-${++_nextClient}');
    _clients[key] = client;
    return ToolsHttpConnection(
      {
        'type': 'http',
        'url': '$endpoint',
        'headers': {'Authorization': 'Bearer $key'},
      },
      () {
        if (_clients.remove(key) != null) client.close();
      },
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      // Native ACP clients need no browser origin. Reject all browser origins,
      // and require the literal loopback authority (also blocks DNS rebinding).
      if (request.headers.value('origin') != null ||
          request.headers.value('host') != url?.authority) {
        return await _status(response, HttpStatus.forbidden);
      }
      if (request.uri.path != '/mcp' || request.uri.hasQuery) {
        return await _status(response, HttpStatus.notFound);
      }
      final authorization = request.headers.value('authorization');
      final client =
          authorization != null && authorization.startsWith('Bearer ')
          ? _clients[authorization.substring(7)]
          : null;
      if (client == null) {
        return await _status(response, HttpStatus.unauthorized);
      }
      final version = request.headers.value('mcp-protocol-version');
      if (version != null && !_versions.contains(version)) {
        return await _status(response, HttpStatus.badRequest);
      }
      final accept = request.headers.value('accept') ?? '';
      if (request.method == 'GET') {
        if (!accept.contains('text/event-stream')) {
          return await _status(response, HttpStatus.notAcceptable);
        }
        return await client.events(response);
      }
      // Stateless transport: no MCP-Session-Id is issued. Conversation lifetime
      // is instead owned by ACP, which revokes its capability on stop/restart.
      if (request.method != 'POST') {
        response.headers.set('allow', 'GET, POST');
        return await _status(response, HttpStatus.methodNotAllowed);
      }
      if (request.headers.contentType?.mimeType != 'application/json') {
        return await _status(response, HttpStatus.unsupportedMediaType);
      }
      if (!accept.contains('application/json') ||
          !accept.contains('text/event-stream')) {
        return await _status(response, HttpStatus.notAcceptable);
      }
      final body = <int>[];
      await for (final bytes in request) {
        if (body.length + bytes.length > _maxBody) {
          return await _status(response, HttpStatus.requestEntityTooLarge);
        }
        body.addAll(bytes);
      }
      final Object? message;
      try {
        message = jsonDecode(utf8.decode(body));
      } on FormatException {
        return await _json(response, _error(null, -32700, 'Parse error'));
      }
      if (message is! Map<String, Object?> ||
          message['jsonrpc'] != '2.0' ||
          message['method'] is! String ||
          (message.containsKey('params') && message['params'] is! Map) ||
          (message.containsKey('id') &&
              message['id'] is! String &&
              message['id'] is! num)) {
        return await _json(response, _error(null, -32600, 'Invalid Request'));
      }
      if (client.closed) {
        return await _status(response, HttpStatus.unauthorized);
      }
      if (!message.containsKey('id')) {
        if (message['method'] == 'notifications/initialized') {
          client.initialized = true;
        }
        await ClaudeSdkTools.handle(message, client.call);
        return await _status(response, HttpStatus.accepted);
      }
      Map<String, Object?> answer;
      try {
        answer = await ClaudeSdkTools.handle(message, client.call);
        if (message['method'] == 'initialize') {
          final requested = (message['params'] as Map?)?['protocolVersion'];
          answer = {
            ...answer,
            'result': {
              ...(answer['result'] as Map).cast<String, Object?>(),
              'protocolVersion': _versions.contains(requested)
                  ? requested
                  : _versions.first,
            },
          };
        }
      } on Object {
        answer = _error(message['id'], -32603, 'Internal error');
      }
      await _json(response, answer);
    } on Object {
      // A disconnected HTTP client must not produce an unhandled async error.
      try {
        await response.close();
      } on Object {
        // The peer has already gone away.
      }
    }
  }

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  static Future<void> _status(HttpResponse response, int status) async {
    response.statusCode = status;
    await response.close();
  }

  static Future<void> _json(
    HttpResponse response,
    Map<String, Object?> message,
  ) async {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(message));
    await response.close();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _starting = null;
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
    await server?.close(force: true);
  }
}

class _Client {
  _Client(this.cwd, this.session) {
    _changes = ClaudeSdkTools.changes.listen((_) {
      if (!initialized || closed) return;
      for (final response in [..._events]) {
        unawaited(
          _write(
            response,
            'data: {"jsonrpc":"2.0",'
            '"method":"notifications/tools/list_changed"}\n\n',
          ),
        );
      }
    });
  }

  final String cwd;
  final String session;
  final _cancelled = Completer<void>();
  final _events = <HttpResponse>{};
  final _writes = <HttpResponse, Future<void>>{};
  final _heartbeats = <HttpResponse, Timer>{};
  late final StreamSubscription<void> _changes;
  bool initialized = false;
  bool get closed => _cancelled.isCompleted;
  ClaudeSdkCall get call =>
      ClaudeSdkCall(cwd: cwd, sessionId: session, cancelled: _cancelled.future);

  Future<void> events(HttpResponse response) async {
    response.headers.contentType = ContentType('text', 'event-stream');
    response.headers.set('cache-control', 'no-cache');
    response.bufferOutput = false;
    _events.add(response);
    // Flush headers immediately; comments also keep idle channels alive.
    _heartbeats[response] = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_write(response, ': keepalive\n\n'));
    });
    try {
      await _write(response, ': connected\n\n');
      await response.done;
    } on Object {
      // A reconnect does not cancel calls or revoke this conversation.
    } finally {
      _closeEvent(response);
    }
  }

  Future<void> _write(HttpResponse response, String event) {
    if (!_events.contains(response)) return Future.value();
    // HttpResponse is bound while flush is pending. Notifications, heartbeats
    // and shutdown must all wait for that flush instead of writing over it.
    return _writes[response] = (_writes[response] ?? Future<void>.value()).then(
      (_) async {
        if (!_events.contains(response)) return;
        try {
          response.write(event);
          await response.flush();
        } on Object {
          _closeEvent(response);
        }
      },
    );
  }

  void _closeEvent(HttpResponse response) {
    if (!_events.remove(response)) return;
    _heartbeats.remove(response)?.cancel();
    final pending = _writes.remove(response) ?? Future<void>.value();
    unawaited(
      pending.then((_) async {
        try {
          await response.close();
        } on Object {
          // Both a synchronous close failure and a disconnected peer are quiet.
        }
      }),
    );
  }

  void close() {
    if (closed) return;
    _cancelled.complete();
    unawaited(_changes.cancel());
    for (final response in [..._events]) {
      _closeEvent(response);
    }
  }
}
