import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import '../agent_kernel.dart';

/// Local index of ACP sessions for one agent: only [SessionRecord] metadata
/// so [Workspace] can resume via `session/load`. The conversation itself
/// stays with the agent.
class AcpCatalog implements SessionCatalog {
  AcpCatalog({required this.agentId, this.file});

  final String agentId;
  final String? file;

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
        final raw = decoded['sessions'];
        if (raw is! List) {
          _sessions = const [];
          return;
        }
        final sessions = <SessionRecord>[
          for (final entry in raw)
            if (entry is Map)
              ?_sessionFromJson(entry.cast<String, Object?>()),
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
    _sessions = [
      ...sessions,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _loaded = true;
    final text = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
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

  /// Remembers [session] under its [SessionRecord.cwd] (app location, which
  /// may be `ssh://…`). Later loads call `session/load` with that id.
  Future<void> upsert(SessionRecord session) async {
    if (session.id.isEmpty || session.cwd.isEmpty) return;
    final sessions = [...await _load()];
    final index = sessions.indexWhere((item) => item.id == session.id);
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
  Future<void> delete(String id) async {
    final sessions = [...await _load()];
    final next = [
      for (final session in sessions)
        if (session.id != id) session,
    ];
    if (next.length == sessions.length) return;
    await _save(next);
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final byCwd = <String, List<SessionRecord>>{};
    for (final session in await _load()) {
      byCwd.putIfAbsent(session.cwd, () => []).add(session);
    }
    final projects = [
      for (final MapEntry(:key, :value) in byCwd.entries)
        ProjectRecord(
          path: key,
          sessions: [...value]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
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
