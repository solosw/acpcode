import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import 'acp_transport.dart';

/// Local index of ACP sessions for one agent: only [SessionRecord] metadata
/// so [Workspace] can resume via `session/load`. The conversation itself
/// stays with the agent.
class AcpCatalog implements SessionCatalog {
  AcpCatalog({
    required this.agentId,
    this.file,
    this._start,
    this._discoveryTimeout = const Duration(seconds: 10),
  });

  final String agentId;
  final String? file;
  final AcpTransportFactory? _start;
  final Duration _discoveryTimeout;
  final _discovering = <String?, Future<bool>>{};
  final _hidden = <(String?, String)>{};

  Future<void> _writing = Future.value();
  Future<void>? _loading;
  List<SessionRecord> _sessions = const [];
  var _loaded = false;

  File get _file => File(
    file ??
        p.join(
          DataDirectory.current.stateDir,
          'acp-sessions-${_safe(agentId)}.json',
        ),
  );

  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  Future<List<SessionRecord>> _load() async {
    if (_loaded) return _sessions;
    final loading = _loading ??= () async {
      try {
        final path = _file;
        if (!await path.exists()) {
          _sessions = const [];
          return;
        }
        final decoded = jsonDecode(await path.readAsString());
        if (decoded is! Map) {
          _sessions = const [];
          return;
        }
        if (decoded['hidden'] case final List hidden) {
          for (final entry in hidden) {
            if (entry case [final String? host, final String id]) {
              _hidden.add((host, id));
            }
          }
        }
        final raw = decoded['sessions'];
        if (raw is! List) {
          _sessions = const [];
          return;
        }
        final sessions = <SessionRecord>[
          for (final entry in raw)
            if (entry is Map) ?_sessionFromJson(entry.cast<String, Object?>()),
        ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        _sessions = sessions;
      } on Object {
        _sessions = const [];
      } finally {
        _loaded = true;
        _loading = null;
      }
    }();
    await loading;
    return _sessions;
  }

  Future<void> _save(List<SessionRecord> sessions) {
    _sessions = [...sessions]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _loaded = true;
    final text = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      if (_hidden.isNotEmpty)
        'hidden': [
          for (final (host, id) in _hidden) [host, id],
        ],
      'sessions': [
        for (final session in _sessions)
          {
            'id': session.id,
            'title': session.title,
            'updatedAt': session.updatedAt.toUtc().toIso8601String(),
            'cwd': session.cwd,
          },
      ],
    });
    return _writing = _writing.then((_) async {
      try {
        final path = _file;
        await path.parent.create(recursive: true);
        await writeFileAtomically(path, '$text\n');
      } on Object {
        // Not kept this time; the next change tries again.
      }
    });
  }

  static SessionRecord? _sessionFromJson(Map<String, Object?> json) {
    final id = json['id'];
    final cwd = json['cwd'];
    if (id is! String || id.isEmpty || cwd is! String || cwd.isEmpty) {
      return null;
    }
    final updated = switch (json['updatedAt']) {
      final String text => DateTime.tryParse(text)?.toUtc(),
      final int millis => DateTime.fromMillisecondsSinceEpoch(
        millis,
        isUtc: true,
      ),
      _ => null,
    };
    return SessionRecord(
      id: id,
      title: json['title'] is String ? json['title'] as String : '',
      updatedAt: updated ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      cwd: cwd,
    );
  }

  static (String?, String) _key(SessionRecord record) =>
      (RemoteLocation.hostOf(record.cwd), record.id);

  /// Merges metadata returned by the Agent into the local index. A missing
  /// capability, failed page, or empty list never removes cached sessions.
  /// With no [location], asks the local Agent for all its sessions.
  Future<bool> discover({String? location}) {
    final start = _start;
    if (start == null) return Future.value(false);
    return _discovering.putIfAbsent(
      location,
      () => _discover(start, location).whenComplete(() {
        _discovering.remove(location);
      }),
    );
  }

  Future<bool> _discover(AcpTransportFactory start, String? location) async {
    AcpTransport? transport;
    StreamIterator<Map<String, Object?>>? messages;
    var expired = false;
    final host = location == null ? null : RemoteLocation.hostOf(location);
    final cwd = location == null ? null : RemoteLocation.pathOf(location);
    final found = <SessionRecord>[];
    try {
      await (() async {
        final opened = await start(KernelContext(cwd: location));
        if (expired) {
          await _closeDiscovery(opened);
          return;
        }
        transport = opened;
        final replies = messages = StreamIterator(opened.messages);
        var nextId = 0;
        Future<Map> request(String method, Map<String, Object?> params) async {
          final id = ++nextId;
          var next = replies.moveNext();
          try {
            opened.write({
              'jsonrpc': '2.0',
              'id': id,
              'method': method,
              'params': params,
            });
          } on Object {
            unawaited(next.then<void>((_) {}, onError: (Object _) {}));
            rethrow;
          }
          while (await next && !expired) {
            final reply = replies.current;
            if (reply['id'] == id && !reply.containsKey('method')) {
              if (reply['result'] case final Map result) return result;
              break;
            }
            next = replies.moveNext();
          }
          throw StateError('No ACP result for $method');
        }

        final initialized = await request('initialize', {
          'protocolVersion': 1,
          'clientInfo': {'name': 'BaoCode', 'version': '1.0.0'},
          'clientCapabilities': <String, Object?>{},
        });
        if (initialized['agentCapabilities'] case {
          'sessionCapabilities': {'list': final Map _},
        }) {
          final seenCursors = <String>{};
          String? cursor;
          do {
            final page = await request('session/list', {
              'cwd': ?cwd,
              'cursor': ?cursor,
            });
            if (page['sessions'] is! List) break;
            for (final entry in page['sessions'] as List) {
              if (entry
                  case {'sessionId': final String id, 'cwd': final String path}
                  when id.isNotEmpty &&
                      RemoteLocation.pathsFor(path).isAbsolute(path)) {
                final discovered = RemoteLocation.of(host, path);
                // Defend against Agents that ignore the optional cwd filter.
                if (location != null &&
                    !RemoteLocation.pathsOf(location).equals(path, cwd!)) {
                  continue;
                }
                found.add(
                  _sessionFromJson({
                    'id': id,
                    'cwd': location ?? discovered,
                    'title': entry['title'],
                    'updatedAt': entry['updatedAt'],
                  })!,
                );
              }
            }
            cursor = page['nextCursor'] is String
                ? page['nextCursor'] as String
                : null;
          } while (cursor != null && seenCursors.add(cursor) && !expired);
        }
      })().timeout(_discoveryTimeout);
    } on Object {
      // Offline, timed out, or an older Agent: keep cache and any good pages.
    } finally {
      expired = true;
      if (messages case final replies?) {
        unawaited(replies.cancel().catchError((Object _) {}));
      }
      if (transport case final opened?) unawaited(_closeDiscovery(opened));
    }
    if (found.isEmpty) return false;
    final sessions = {for (final record in await _load()) _key(record): record};
    var changed = false;
    for (final record in found) {
      final key = _key(record);
      if (_hidden.contains(key)) continue;
      final existing = sessions[key];
      final merged = existing == null
          ? record
          : SessionRecord(
              id: existing.id,
              cwd: existing.cwd,
              title:
                  record.title.isNotEmpty &&
                      (existing.title.isEmpty ||
                          !record.updatedAt.isBefore(existing.updatedAt))
                  ? record.title
                  : existing.title,
              updatedAt: record.updatedAt.isAfter(existing.updatedAt)
                  ? record.updatedAt
                  : existing.updatedAt,
            );
      if (existing != null &&
          existing.title == merged.title &&
          existing.updatedAt == merged.updatedAt) {
        continue;
      }
      sessions[key] = merged;
      changed = true;
    }
    if (changed) await _save(sessions.values.toList());
    return changed;
  }

  static Future<void> _closeDiscovery(AcpTransport transport) async {
    try {
      await transport.close();
    } on Object {
      // Best effort: discovery is independent of the chat connection.
    }
  }

  /// Remembers [session] under its [SessionRecord.cwd] (app location, which
  /// may be `ssh://…`). Later loads call `session/load` with that id.
  Future<void> upsert(SessionRecord session) async {
    if (session.id.isEmpty || session.cwd.isEmpty) return;
    final sessions = [...await _load()];
    final key = _key(session);
    if (_hidden.contains(key)) return;
    final index = sessions.indexWhere((item) => _key(item) == key);
    final next = SessionRecord(
      id: session.id,
      title: session.title,
      updatedAt: session.updatedAt.toUtc(),
      cwd: session.cwd,
    );
    if (index >= 0) {
      sessions[index] = next;
    } else {
      sessions.add(next);
    }
    await _save(sessions);
  }

  @override
  Future<void> delete(String id, {String? cwd}) async {
    final sessions = await _load();
    final keys = cwd == null
        ? {
            for (final session in sessions)
              if (session.id == id) _key(session),
          }
        : {(RemoteLocation.hostOf(cwd), id)};
    if (keys.isEmpty) return;
    _hidden.addAll(keys);
    await _save([
      for (final session in sessions)
        if (!keys.contains(_key(session))) session,
    ]);
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final byCwd = <String, List<SessionRecord>>{};
    for (final session in await _load()) {
      byCwd.putIfAbsent(session.cwd, () => []).add(session);
    }
    final projects =
        [
          for (final MapEntry(:key, :value) in byCwd.entries)
            ProjectRecord(
              path: key,
              sessions: [...value]
                ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
            ),
        ]..sort(
          (a, b) => (b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
        );
    return projects;
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final sessions = [
      for (final session in await _load())
        if (session.cwd == cwd) session,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }
}
