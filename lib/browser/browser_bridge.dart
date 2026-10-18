import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';

/// The user's own browsers, reached through BaoCode's extension in them
/// (browser_extension/): each runs the app's native messaging host
/// (macos/BrowserBridge/host.c), which connects to this socket and passes
/// the extension's messages. Agents use the tabs shared there through the
/// tools of browser_tools.dart.
///
/// A message is the browser's way: its length (4 bytes, little-endian),
/// then that much JSON. The app asks `{id, method, params}` (see
/// background.js) and is answered `{id, result}` or `{id, error}`; what
/// happens comes as `{type: "event", event, …}`.
class BrowserBridge extends ChangeNotifier {
  BrowserBridge._();

  static final instance = BrowserBridge._();

  /// The native messaging host's name, as the extension asks for it.
  static const hostName = 'dev.baocode.browser';

  /// The extension's id: the Chrome Web Store's, and the zip's to load
  /// unpacked (its manifest's key), the same (docs/release.md, 11).
  static const extensionIds = ['jfjagocghaaheooicmdnhcholmgdkngk'];

  /// What BaoCode and the extension say to each other: background.js's
  /// BRIDGE, one more with each change the other has to know of. A browser
  /// whose extension says another is not used ([mismatched]).
  static const protocol = 1;

  /// settings.json's `browser.enabled`: whether the agents may use the
  /// user's browsers, as Settings → Browser turns it on or off. Unset: on.
  static const settingKey = 'browser.enabled';

  /// Sets [enabled] from [read] now and whenever [changes] notifies.
  void follow(Listenable changes, Object? Function() read) {
    void update() => enabled = read() != false;
    update();
    changes.addListener(update);
  }

  /// Where the host finds the app: the same folder for both, the user's
  /// temporary one ([socketFolder] in a test).
  static String get socketPath =>
      p.join(socketFolder ?? Directory.systemTemp.path, 'baocode-browser.sock');

  /// A test's own folder for the socket: given as TMPDIR to a browser it
  /// launches, whose host alone finds it there (not the user's browsers').
  @visibleForTesting
  static String? socketFolder;

  /// A test's own home, where the browsers' folders are looked for: the
  /// user's are left alone.
  @visibleForTesting
  static String? home;

  static String? get _home => home ?? Platform.environment['HOME'];

  bool get supported => !kIsWeb && Platform.isMacOS;

  /// Whether the user lets the agents use the browsers: off, nothing
  /// listens for them, and the browsers find no host to start (it is
  /// removed); the extension says BaoCode is not running.
  bool get enabled => _enabled;
  bool _enabled = true;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      if (_wanted) unawaited(start());
    } else {
      unawaited(stop());
      unawaited(removeHost());
    }
    notifyListeners();
  }

  /// Whether the agents' tools and the side panel's page are there: once a
  /// browser has connected ([connectedBefore]), never for a user without
  /// the extension, and while [enabled].
  bool get used => enabled && connectedBefore;

  /// Whether a browser has connected, in this run or one before (a mark of
  /// its in the data folder).
  bool get connectedBefore => _used ??= supported && File(_mark).existsSync();
  bool? _used;

  String get _mark => p.join(DataDirectory.current.browserDir, 'connected');

  void _connected() {
    if (_used != true) {
      _used = true;
      try {
        File(_mark)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('');
      } on FileSystemException {
        // Marked next time.
      }
    }
    notifyListeners();
  }

  ServerSocket? _server;
  bool _started = false;

  /// Whether [start] was asked: to start again when [enabled] again.
  bool _wanted = false;

  /// Whether another BaoCode has the socket: its browsers are its.
  bool get otherApp => _otherApp;
  bool _otherApp = false;

  final List<BrowserConnection> _connections = [];

  /// The browsers whose extension is connected, the last to come first.
  List<BrowserConnection> get browsers => [
    for (final connection in _connections.reversed)
      if (connection.browser != null && connection.compatible) connection,
  ];

  /// The browsers whose extension is connected but speaks another
  /// [protocol]: one of them, or BaoCode, has to be updated.
  List<BrowserConnection> get mismatched => [
    for (final connection in _connections.reversed)
      if (connection.browser != null && !connection.compatible) connection,
  ];

  /// What the browsers tell, each with its connection.
  Stream<BrowserEvent> get events => _events.stream;
  final _events = StreamController<BrowserEvent>.broadcast();

  /// Listens for the browsers' hosts, and tells the browsers where the host
  /// is: once a run.
  Future<void> start() {
    _wanted = true;
    return _queue = _queue.then((_) => _start());
  }

  /// Lets the browsers go, and the socket.
  Future<void> stop() => _queue = _queue.then((_) => _stop());

  /// [start] and [stop], one after the other: the switch turned off and on
  /// again at once binds the socket after it was let go, not before.
  Future<void> _queue = Future.value();

  Future<void> _start() async {
    if (_started || !supported || !enabled) return;
    _started = true;
    unawaited(installHost());
    final path = socketPath;
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      try {
        // Another BaoCode's, if it answers: left to it.
        final socket = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        ).timeout(const Duration(seconds: 1));
        socket.destroy();
        _otherApp = true;
        notifyListeners();
        return;
      } on Object {
        // Left by a run that ended.
        try {
          File(path).deleteSync();
        } on FileSystemException {
          // Taken again just now, or not ours to delete: bind says.
        }
      }
    }
    try {
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      _server = server;
      server.listen(_accept);
    } on SocketException catch (error) {
      debugPrint('browser bridge: $error');
    }
  }

  Future<void> _stop() async {
    _started = false;
    _otherApp = false;
    final server = _server;
    _server = null;
    for (final connection in [..._connections]) {
      connection._close();
    }
    // Ours alone: another BaoCode's is left to it. Before the close, which
    // ends later: by then a start again may have bound it anew.
    if (server == null) return;
    try {
      File(socketPath).deleteSync();
    } on FileSystemException {
      // Gone.
    }
    await server.close();
  }

  void _accept(Socket socket) {
    final connection = BrowserConnection._(this, socket);
    _connections.add(connection);
  }

  void _closed(BrowserConnection connection) {
    if (!_connections.remove(connection)) return;
    if (connection.browser != null) notifyListeners();
  }

  // --- The host, as the browsers find it: a manifest of its in each
  // browser's folder for them (those the user has), naming the app's.

  /// The browsers' folders for native messaging hosts' manifests, by the
  /// folder each browser keeps its profile in.
  static List<String> _hostFolders(String home) => [
    for (final browser in [
      'Google/Chrome',
      'Google/Chrome Beta',
      'Google/Chrome Dev',
      'Google/Chrome Canary',
      'Chromium',
      'Microsoft Edge',
      'Microsoft Edge Beta',
      'Microsoft Edge Dev',
      'Microsoft Edge Canary',
      'BraveSoftware/Brave-Browser',
      'BraveSoftware/Brave-Browser-Beta',
      'Vivaldi',
      'Arc/User Data',
    ])
      p.join(home, 'Library', 'Application Support', browser),
  ];

  static File _hostManifest(String folder) =>
      File(p.join(folder, 'NativeMessagingHosts', '$hostName.json'));

  /// The host's executable: beside the app's.
  static String get hostExecutable =>
      p.join(p.dirname(Platform.resolvedExecutable), 'baocode-browser-host');

  /// Writes the host's manifest for each browser installed: the browsers
  /// then start it for the extension.
  Future<void> installHost() async {
    final home = _home;
    if (home == null || !File(hostExecutable).existsSync()) return;
    final manifest = const JsonEncoder.withIndent('  ').convert({
      'name': hostName,
      'description': 'BaoCode',
      'path': hostExecutable,
      'type': 'stdio',
      'allowed_origins': [
        for (final id in extensionIds) 'chrome-extension://$id/',
      ],
    });
    for (final folder in _hostFolders(home)) {
      if (!Directory(folder).existsSync()) continue;
      final file = _hostManifest(folder);
      try {
        if (file.existsSync() && file.readAsStringSync() == manifest) {
          continue;
        }
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(manifest);
      } on FileSystemException catch (error) {
        debugPrint('browser bridge: $error');
      }
    }
  }

  /// Takes the host's manifest out of each browser's folder: they start it
  /// no more. Written again by the next [start].
  Future<void> removeHost() async {
    final home = _home;
    if (home == null || !supported) return;
    for (final folder in _hostFolders(home)) {
      try {
        final file = _hostManifest(folder);
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException catch (error) {
        debugPrint('browser bridge: $error');
      }
    }
  }
}

/// A tab of a browser's.
@immutable
class BrowserTab {
  const BrowserTab(this.browser, this.tabId);

  final BrowserConnection browser;
  final int tabId;

  @override
  bool operator ==(Object other) =>
      other is BrowserTab &&
      identical(other.browser, browser) &&
      other.tabId == tabId;

  @override
  int get hashCode => Object.hash(identityHashCode(browser), tabId);
}

/// What a browser told: [event] (`cdp`, `tab`, `closed`, `detached`,
/// `unshared`) and the rest of the message.
class BrowserEvent {
  const BrowserEvent(this.connection, this.event, this.message);

  final BrowserConnection connection;
  final String event;
  final Map<String, Object?> message;

  int? get tabId => message['tabId'] as int?;
}

/// A browser's extension, through its host.
class BrowserConnection {
  BrowserConnection._(this._bridge, this._socket) {
    _socket.listen(
      _read,
      onDone: _close,
      onError: (Object _) => _close(),
      cancelOnError: true,
    );
  }

  final BrowserBridge _bridge;
  final Socket _socket;

  /// The extension's origin, as the browser told its host.
  String? origin;

  /// Its name (`Google Chrome`, `Microsoft Edge`…), once the extension
  /// said hello; null till then (its host connects before it).
  String? browser;

  /// The extension's version.
  String? version;

  /// The [BrowserBridge.protocol] the extension speaks: 1 for one from
  /// before it said.
  int protocol = 1;

  bool get compatible => protocol == BrowserBridge.protocol;

  /// What the extension may be asked beyond the first methods (its
  /// CAPABILITIES): `cdp.session`, `call`, `subscribe`, `configure`. A new
  /// one comes with a new version of the extension, the protocol the same:
  /// what uses it asks [can] first.
  Set<String> capabilities = const {};

  bool can(String capability) => capabilities.contains(capability);

  int _lastId = 0;
  final Map<int, Completer<Object?>> _pending = {};
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _closed = false;

  /// Asks the extension [method] (see background.js): its result, or an
  /// error thrown with what it said.
  Future<Object?> request(
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) {
    if (_closed) {
      return Future.error(StateError('The browser is no longer connected.'));
    }
    final id = ++_lastId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _write({'id': id, 'method': method, 'params': params});
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('The browser did not answer $method.');
      },
    );
  }

  /// Asks a shared tab's page [method] of the DevTools protocol; with
  /// [sessionId], a session of the tab's (a frame's or a worker's, attached
  /// to with Target.setAutoAttach, flatten: [can] `cdp.session`).
  Future<Map<String, Object?>> cdp(
    int tabId,
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
    String? sessionId,
  ]) async {
    final result = await request('cdp', {
      'tabId': tabId,
      'method': method,
      'params': params,
      'sessionId': ?sessionId,
    }, timeout);
    return (result as Map?)?.cast<String, Object?>() ?? {};
  }

  /// Calls the browser's `chrome.<api>` (`tabs.update`, `windows.get`…, of
  /// tabs, windows and tab groups) with [args], as the extension lets it:
  /// on shared tabs alone, answering of them alone ([can] `call`).
  Future<Object?> call(String api, [List<Object?> args = const []]) =>
      request('call', {'api': api, 'args': args});

  /// Has the browser's [events] (`tabs.onActivated`…) told, of the shared
  /// tabs, as `chrome` events ([can] `subscribe`): those it passes on.
  Future<List<String>> subscribe(List<String> events) async => [
    for (final event in await request('subscribe', {'events': events}) as List)
      '$event',
  ];

  /// Tells the extension how BaoCode wants it ([can] `configure`):
  /// `followOpeners`, whether a tab a shared one opens is shared (on).
  Future<void> configure(Map<String, Object?> config) =>
      request('configure', config);

  void _write(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    final header = ByteData(4)..setUint32(0, body.length, Endian.little);
    _socket
      ..add(header.buffer.asUint8List())
      ..add(body);
  }

  void _read(Uint8List data) {
    _buffer.add(data);
    final bytes = _buffer.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 4) {
      final length = ByteData.sublistView(
        bytes,
        offset,
        offset + 4,
      ).getUint32(0, Endian.little);
      if (bytes.length - offset - 4 < length) break;
      final body = utf8.decode(
        Uint8List.sublistView(bytes, offset + 4, offset + 4 + length),
      );
      offset += 4 + length;
      try {
        _received(jsonDecode(body) as Map<String, Object?>);
      } on FormatException {
        // Not a message.
      }
    }
    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
  }

  void _received(Map<String, Object?> message) {
    if (message['id'] case final int id when message['type'] == null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (message['error'] case final String error) {
        completer.completeError(BrowserError(error));
      } else {
        completer.complete(message['result']);
      }
      return;
    }
    switch (message['type']) {
      case 'hello' when message['origin'] != null:
        // The host's: who started it.
        origin = message['origin'] as String?;
        final allowed = BrowserBridge.extensionIds.any(
          (id) => origin == 'chrome-extension://$id/',
        );
        if (!allowed) _close();
      case 'hello':
        browser = message['browser'] as String? ?? 'Browser';
        version = message['version'] as String?;
        protocol = (message['protocol'] as num?)?.toInt() ?? 1;
        capabilities = {
          for (final capability in message['capabilities'] as List? ?? [])
            '$capability',
        };
        _bridge._connected();
      case 'event':
        final event = message['event'] as String? ?? '';
        _bridge._events.add(BrowserEvent(this, event, message));
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    for (final completer in _pending.values) {
      completer.completeError(
        StateError('The browser is no longer connected.'),
      );
    }
    _pending.clear();
    _bridge._closed(this);
  }
}

/// What the extension answered for a request it could not do.
class BrowserError implements Exception {
  const BrowserError(this.message);

  final String message;

  @override
  String toString() => message;
}
