import 'dart:async';

import 'package:bao_agent/mcp.dart';

/// A local MCP transport owned by one SSH conversation.
class LocalMcpEndpoint {
  LocalMcpEndpoint(this._transport);

  final McpTransport _transport;
  final _pending = <Object, Completer<Map<String, Object?>>>{};
  Future<void>? _starting;
  StreamSubscription<Map<String, Object?>>? _subscription;
  bool _closed = false;
  void Function(Map<String, Object?>)? onEvent;

  Future<void> _start() async {
    _subscription = _transport.messages.listen(_receive, onDone: close);
    await _transport.start();
    if (_closed) await _transport.close();
  }

  void _receive(Map<String, Object?> message) {
    if (_closed) return;
    if (message['method'] is String) {
      onEvent?.call(message);
    } else {
      final reply = _pending[message['id']];
      if (reply != null && !reply.isCompleted) reply.complete(message);
    }
  }

  Future<Map<String, Object?>> call(Map<String, Object?> message) async {
    final id = message['id'];
    Map<String, Object?> error(String message) => {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32603, 'message': message},
    };
    try {
      if (!_closed) await (_starting ??= _start());
      if (_closed) return error('Local MCP connection ended');
      if (id == null || !message.containsKey('method')) {
        await _transport.send(message);
        return const {};
      }
      if (_pending.containsKey(id)) return error('MCP request ID is in use');
      final reply = _pending[id] = Completer<Map<String, Object?>>();
      try {
        unawaited(
          _transport.send(message).catchError((Object _) {
            if (!reply.isCompleted) {
              reply.complete(error('Local MCP request failed'));
            }
          }),
        );
        final answer = await reply.future.timeout(
          const Duration(minutes: 10),
          onTimeout: () => error('Local MCP request timed out'),
        );
        if ((message['method'], answer['result'], _transport) case (
          'initialize',
          {'protocolVersion': final String version},
          final StreamableHttpTransport transport,
        )) {
          transport.protocolVersion = version;
        }
        return answer;
      } finally {
        _pending.remove(id);
      }
    } on Object {
      return error('Could not reach the local MCP server');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final entry in _pending.entries) {
      if (entry.value.isCompleted) continue;
      entry.value.complete({
        'jsonrpc': '2.0',
        'id': entry.key,
        'error': {'code': -32603, 'message': 'Local MCP connection ended'},
      });
    }
    unawaited(_subscription?.cancel());
    if (_starting != null) {
      unawaited(_transport.close().catchError((Object _) {}));
    }
  }
}
