/// A TCP proxy that makes a bad network of a good one, for end-to-end
/// tests of what goes over it (test/remote/ssh_resilience_e2e_test.dart).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Forwards connections to [host]:[targetPort], as a network would, or
/// not: [cut] (each connection reset), [blackhole] (nothing passes and
/// nothing ends, as a Wi-Fi gone), [refusing] (no new connection), slow
/// ([latency], [jitter], [bytesPerSecond]).
class FaultProxy {
  FaultProxy._(this._server, this.host, this.targetPort);

  static Future<FaultProxy> start(String host, int targetPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = FaultProxy._(server, host, targetPort);
    server.listen(proxy._accept);
    return proxy;
  }

  final ServerSocket _server;
  final String host;
  final int targetPort;
  final Random _random = Random(42);
  final List<_Pair> _pairs = [];

  int get port => _server.port;

  /// New connections closed at once, as a host that cannot be reached.
  bool refusing = false;

  /// Connections forwarded, and refused.
  int accepted = 0;
  int refused = 0;

  /// Each chunk held this long (and up to [jitter] more), in order.
  Duration latency = Duration.zero;
  Duration jitter = Duration.zero;

  /// At most this fast each way; null for as fast as it goes.
  int? bytesPerSecond;

  bool _holding = false;
  Completer<void> _released = Completer()..complete();

  /// Nothing passes from now, and nothing ends: what is sent is held
  /// (as TCP retries it) until [restore].
  void blackhole() {
    if (_holding) return;
    _holding = true;
    _released = Completer();
  }

  /// Every connection there is reset.
  void cut() {
    for (final pair in [..._pairs]) {
      pair.destroy();
    }
  }

  /// A good network again.
  void restore() {
    refusing = false;
    latency = Duration.zero;
    jitter = Duration.zero;
    bytesPerSecond = null;
    _holding = false;
    if (!_released.isCompleted) _released.complete();
  }

  Future<void> close() async {
    restore();
    cut();
    await _server.close();
  }

  Future<void> _accept(Socket client) async {
    if (refusing) {
      refused++;
      client.destroy();
      return;
    }
    accepted++;
    final Socket upstream;
    try {
      upstream = await Socket.connect(host, targetPort);
    } on SocketException {
      client.destroy();
      return;
    }
    _pairs.add(_Pair(this, client, upstream));
  }

  Duration _delay() =>
      latency +
      (jitter == Duration.zero
          ? Duration.zero
          : Duration(microseconds: _random.nextInt(jitter.inMicroseconds)));
}

class _Pair {
  _Pair(this._proxy, this._client, this._upstream) {
    for (final socket in [_client, _upstream]) {
      unawaited(socket.done.then((_) {}, onError: (Object _) {}));
    }
    _up = _Direction(_proxy, _client, _upstream, destroy);
    _down = _Direction(_proxy, _upstream, _client, destroy);
  }

  final FaultProxy _proxy;
  final Socket _client;
  final Socket _upstream;
  late final _Direction _up;
  late final _Direction _down;
  bool _destroyed = false;

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _proxy._pairs.remove(this);
    _up.stop();
    _down.stop();
    _client.destroy();
    _upstream.destroy();
  }
}

/// One way of a connection: chunks forwarded in order, each when the
/// network lets it.
class _Direction {
  _Direction(this._proxy, Socket from, this._to, this._ended) {
    _subscription = from.listen(
      (data) {
        _queue.add((data, DateTime.now()));
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (Object _) => _ended(),
      cancelOnError: true,
    );
    unawaited(_pump());
  }

  final FaultProxy _proxy;
  final Socket _to;
  final void Function() _ended;
  late final StreamSubscription<Uint8List> _subscription;
  final Queue<(Uint8List, DateTime)> _queue = Queue();
  Completer<void>? _waiting;
  DateTime _lastDue = DateTime.fromMillisecondsSinceEpoch(0);
  bool _done = false;
  bool _stopped = false;

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<void> _pump() async {
    while (!_stopped) {
      if (_queue.isEmpty) {
        if (_done) {
          _ended();
          return;
        }
        await (_waiting = Completer()).future;
        continue;
      }
      if (_proxy._holding) {
        await _proxy._released.future;
        continue;
      }
      final (data, at) = _queue.first;
      var due = at.add(_proxy._delay());
      if (due.isBefore(_lastDue)) due = _lastDue;
      _lastDue = due;
      final wait = due.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      if (_stopped) return;
      if (_proxy._holding) continue;
      _queue.removeFirst();
      if (_proxy.bytesPerSecond case final rate?) {
        await Future<void>.delayed(
          Duration(microseconds: data.length * 1000000 ~/ rate),
        );
        if (_stopped) return;
      }
      try {
        _to.add(data);
      } on Object {
        _ended();
        return;
      }
    }
  }

  void stop() {
    _stopped = true;
    unawaited(_subscription.cancel());
    _wake();
  }
}
