import 'dart:async';
import 'dart:io';

import 'package:baocode/kernel/acp/acp_catalog.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _ListingTransport implements AcpTransport {
  _ListingTransport(this.respond);

  final Map<String, Object?>? Function(Map<String, Object?>) respond;
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  final written = <Map<String, Object?>>[];
  final closed = Completer<void>();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    if (respond(message) case final response?) reply(message, response);
  }

  void reply(Map<String, Object?> request, Map<String, Object?> response) {
    if (!_messages.isClosed) {
      _messages.add({'jsonrpc': '2.0', 'id': request['id'], ...response});
    }
  }

  @override
  Future<void> close() async {
    if (!closed.isCompleted) closed.complete();
    await _messages.close();
  }
}

const _listingCapabilities = {
  'protocolVersion': 1,
  'agentCapabilities': {
    'loadSession': true,
    'sessionCapabilities': {'list': <String, Object?>{}},
  },
};

Map<String, Object?> _entry(
  String id,
  String cwd, {
  String? title,
  String? at,
}) => {'sessionId': id, 'cwd': cwd, 'title': ?title, 'updatedAt': ?at};

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('acp-catalog-');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'discovers paged Agent sessions without opening a conversation',
    () async {
      final path = p.join(dir.path, 'discovered.json');
      final transports = <_ListingTransport>[];
      final catalog = AcpCatalog(
        agentId: 'listing',
        file: path,
        start: (context) async {
          expect(context.cwd, isNull);
          final transport = _ListingTransport(
            (request) => switch (request) {
              {'method': 'initialize'} => {'result': _listingCapabilities},
              {'method': 'session/list', 'params': Map(:final isEmpty)}
                  when isEmpty =>
                {
                  'result': {
                    'sessions': [
                      _entry(
                        'first',
                        '/work/a',
                        title: 'Agent title',
                        at: '2026-10-11T01:00:00Z',
                      ),
                      _entry('bad-id', 'relative/path'),
                    ],
                    'nextCursor': 'next-page',
                  },
                },
              {'method': 'session/list', 'params': {'cursor': 'next-page'}} => {
                'result': {
                  'sessions': [_entry('second', '/work/b')],
                },
              },
              _ => throw StateError('Unexpected request: $request'),
            },
          );
          transports.add(transport);
          return transport;
        },
      );

      expect(await catalog.discover(), isTrue);
      expect(await catalog.discover(), isFalse);
      for (final transport in transports) {
        expect(transport.written.map((m) => m['method']), [
          'initialize',
          'session/list',
          'session/list',
        ]);
        expect(transport.written[1]['params'], isEmpty);
        expect(transport.written[2]['params'], {'cursor': 'next-page'});
        await transport.closed.future;
      }
      final reloaded = AcpCatalog(agentId: 'listing', file: path);
      final projects = await reloaded.projects();
      expect(projects.map((project) => project.path), ['/work/a', '/work/b']);
      final first = projects.first.sessions.single;
      expect(first.id, 'first');
      expect(first.title, 'Agent title');
      expect(first.updatedAt, DateTime.utc(2026, 10, 11, 1));
      expect(projects.last.sessions.single.id, 'second');
    },
  );

  test(
    'unsupported, failed and empty listings retain cached history',
    () async {
      final path = p.join(dir.path, 'fallback.json');
      final probes = [
        _ListingTransport(
          (_) => {
            'result': {'protocolVersion': 1},
          },
        ),
        _ListingTransport(
          (request) => request['method'] == 'initialize'
              ? {'result': _listingCapabilities}
              : {
                  'error': {'code': -32601, 'message': 'Method not found'},
                },
        ),
        _ListingTransport(
          (request) => request['method'] == 'initialize'
              ? {'result': _listingCapabilities}
              : {
                  'result': {'sessions': []},
                },
        ),
      ];
      var index = 0;
      final catalog = AcpCatalog(
        agentId: 'listing',
        file: path,
        start: (_) async => probes[index++],
      );
      await catalog.upsert(
        SessionRecord(
          id: 'cached',
          title: 'Cached',
          cwd: '/work/a',
          updatedAt: DateTime.utc(2026),
        ),
      );

      for (final probe in probes) {
        expect(await catalog.discover(), isFalse);
        expect((await catalog.sessionsIn('/work/a')).single.id, 'cached');
        await probe.closed.future;
      }
      expect(probes.first.written.map((m) => m['method']), ['initialize']);
      for (final probe in probes.skip(1)) {
        expect(probe.written.map((m) => m['method']), [
          'initialize',
          'session/list',
        ]);
      }
    },
  );

  test(
    'scopes identical IDs to each host and persists a scoped deletion',
    () async {
      final path = p.join(dir.path, 'scoped.json');
      const cwd = '/work/a';
      const remote = 'ssh://box/work/a';
      final scopes = <String?>[];
      final params = <Object?>[];
      Future<AcpTransport> start(KernelContext context) async {
        scopes.add(context.cwd);
        return _ListingTransport((request) {
          if (request['method'] == 'initialize') {
            return {'result': _listingCapabilities};
          }
          if (request['method'] != 'session/list') {
            throw StateError('Unexpected request: $request');
          }
          params.add(request['params']);
          return {
            'result': {
              'sessions': [
                _entry(
                  'shared',
                  cwd,
                  title: context.cwd == null ? 'Local' : 'SSH',
                ),
                if (context.cwd != null) _entry('unrelated', '/work/other'),
              ],
            },
          };
        });
      }

      final catalog = AcpCatalog(agentId: 'listing', file: path, start: start);
      expect(await catalog.discover(), isTrue);
      expect(await catalog.discover(location: remote), isTrue);
      expect(scopes, [null, remote]);
      expect(params, [
        {},
        {'cwd': cwd},
      ]);
      expect((await catalog.sessionsIn(cwd)).single.title, 'Local');
      expect((await catalog.sessionsIn(remote)).single.title, 'SSH');
      expect(await catalog.sessionsIn('ssh://box/work/other'), isEmpty);

      await catalog.delete('shared', cwd: remote);
      final reloaded = AcpCatalog(agentId: 'listing', file: path, start: start);
      expect(await reloaded.discover(location: remote), isFalse);
      expect(await reloaded.sessionsIn(remote), isEmpty);
      expect((await reloaded.sessionsIn(cwd)).single.title, 'Local');
    },
  );

  test(
    'timed-out discovery closes a late transport without sending requests',
    () async {
      final launched = Completer<AcpTransport>();
      final probe = _ListingTransport((_) => null);
      final catalog = AcpCatalog(
        agentId: 'listing',
        file: p.join(dir.path, 'timeout.json'),
        start: (_) => launched.future,
        discoveryTimeout: const Duration(milliseconds: 20),
      );
      expect(await catalog.discover(), isFalse);
      launched.complete(probe);
      await probe.closed.future.timeout(const Duration(seconds: 1));
      expect(probe.written, isEmpty);
    },
  );

  test(
    'workspace opens discovered history using the original session ID',
    () async {
      const cwd = '/work/acp-discovery';
      const id = 'agent-owned-history';
      final listStarted = Completer<void>();
      final listReady = Completer<void>();
      late final _ListingTransport listing;
      final history = MockAcpTransport();
      final catalog = AcpCatalog(
        agentId: 'listing',
        file: p.join(dir.path, 'workspace-history.json'),
        start: (_) async => listing,
      );
      listing = _ListingTransport((request) {
        if (request['method'] == 'initialize') {
          return {'result': _listingCapabilities};
        }
        if (request['method'] != 'session/list') {
          throw StateError('Unexpected request: $request');
        }
        listStarted.complete();
        unawaited(
          listReady.future.then((_) {
            listing.reply(request, {
              'result': {
                'sessions': [_entry(id, cwd, title: 'From the Agent')],
              },
            });
          }),
        );
        return null;
      });
      late final KernelDescriptor kernel;
      kernel = KernelDescriptor(
        id: 'listing',
        label: 'History ACP',
        icon: Icons.hub,
        description: '',
        catalog: catalog,
        create: (context) => AcpKernel(kernel, context, (_) async => history),
      );
      final workspace = Workspace(kernels: [MockKernels.codex, kernel]);
      addTearDown(workspace.dispose);

      await workspace.load().timeout(const Duration(seconds: 2));
      await listStarted.future.timeout(const Duration(seconds: 2));
      expect(workspace.threads.where((thread) => thread.id == id), isEmpty);
      expect(history.written, isEmpty);
      listReady.complete();
      await workspace.refresh();

      final thread = workspace.threads.singleWhere((thread) => thread.id == id);
      expect(thread.title, 'From the Agent');
      expect(thread.project.path, cwd);
      expect(workspace.sidebarProjects, contains(thread.project));
      expect(thread.isOpen, isFalse);
      workspace.select(thread);
      final session = thread.session;
      final ready = Completer<void>();
      void onChange() {
        if (session.itemCount > 0 && !ready.isCompleted) ready.complete();
      }

      session.addListener(onChange);
      try {
        session.attach();
        onChange();
        await ready.future.timeout(const Duration(seconds: 2));
        final load = history.written.singleWhere(
          (m) => m['method'] == 'session/load',
        );
        expect(load['params'], containsPair('sessionId', id));
        expect(
          history.written.map((m) => m['method']),
          isNot(contains('session/new')),
        );
      } finally {
        session.removeListener(onChange);
        session.detach();
      }
    },
  );

  test('upsert lists sessions by cwd and survives reload', () async {
    final path = p.join(dir.path, 'acp-sessions-mock.json');
    final catalog = AcpCatalog(agentId: 'mock', file: path);
    final first = SessionRecord(
      id: 'sess-1',
      title: 'hello',
      updatedAt: DateTime.utc(2026, 10, 11, 1),
      cwd: '/tmp/a',
    );
    final second = SessionRecord(
      id: 'sess-2',
      title: 'remote',
      updatedAt: DateTime.utc(2026, 10, 11, 2),
      cwd: 'ssh://box/home/proj',
    );

    await catalog.upsert(first);
    await catalog.upsert(second);
    await catalog.upsert(
      SessionRecord(
        id: 'sess-1',
        title: 'hello again',
        updatedAt: DateTime.utc(2026, 10, 11, 3),
        cwd: '/tmp/a',
      ),
    );

    expect(await catalog.sessionsIn('/tmp/a'), [
      isA<SessionRecord>()
          .having((s) => s.id, 'id', 'sess-1')
          .having((s) => s.title, 'title', 'hello again'),
    ]);
    expect(
      (await catalog.sessionsIn('ssh://box/home/proj')).single.id,
      'sess-2',
    );

    final projects = await catalog.projects();
    expect(projects.map((project) => project.path), [
      '/tmp/a',
      'ssh://box/home/proj',
    ]);

    final reloaded = AcpCatalog(agentId: 'mock', file: path);
    expect((await reloaded.sessionsIn('/tmp/a')).single.title, 'hello again');
    await reloaded.delete('sess-1');
    expect(await reloaded.sessionsIn('/tmp/a'), isEmpty);
    expect(
      await AcpCatalog(agentId: 'mock', file: path).sessionsIn('/tmp/a'),
      isEmpty,
    );
  });

  test('AcpKernel only indexes a new session after a real prompt, with a stable title', () async {
    final path = p.join(dir.path, 'acp-sessions-kernel.json');
    final catalog = AcpCatalog(agentId: 'mock-acp', file: path);
    final transport = MockAcpTransport();
    final descriptor = KernelDescriptor(
      id: 'mock-acp',
      label: 'Mock ACP',
      icon: Icons.hub,
      description: '',
      catalog: catalog,
      create: (_) => throw UnimplementedError(),
    );
    final kernel = AcpKernel(
      descriptor,
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
      catalog: catalog,
    );

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(kernel.sessionId, 'acp_mock_session');

    // Ready/configuration-only sessions must not appear as empty image chats.
    expect(await catalog.sessionsIn('/tmp/project'), isEmpty);
    expect(await catalog.projects(), isEmpty);
    expect(File(path).existsSync(), isFalse);

    kernel.send(
      const KernelTurn(id: 'first', text: '  First question\nwith details  '),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final sessions = await catalog.sessionsIn('/tmp/project');
    expect(sessions, [
      isA<SessionRecord>()
          .having((s) => s.id, 'id', 'acp_mock_session')
          .having((s) => s.cwd, 'cwd', '/tmp/project')
          .having((s) => s.title, 'title', 'First question with details'),
    ]);
    final firstUpdate = sessions.single.updatedAt;
    kernel.send(const KernelTurn(id: 'second', text: 'Second question'));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final reloaded = await AcpCatalog(
      agentId: 'mock-acp',
      file: path,
    ).sessionsIn('/tmp/project');
    expect(reloaded.single.title, 'First question with details');
    expect(reloaded.single.updatedAt.isAfter(firstUpdate), isTrue);
    kernel.dispose();
    await kernel.stopped;
  });

  test(
    'repeated configuration-only sessions never enter the catalog',
    () async {
      final path = p.join(dir.path, 'previews.json');
      final catalog = AcpCatalog(agentId: 'mock-acp', file: path);
      final descriptor = KernelDescriptor(
        id: 'mock-acp',
        label: 'Mock ACP',
        icon: Icons.hub,
        description: '',
        create: (_) => throw UnimplementedError(),
      );
      for (var i = 0; i < 4; i++) {
        final kernel = AcpKernel(
          descriptor,
          const KernelContext(cwd: '/tmp/project'),
          (_) async => MockAcpTransport(),
          catalog: catalog,
        );
        kernel.prepare();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(kernel.health.status, KernelHealthStatus.ready);
        kernel.mode.select('bypass');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        kernel.dispose();
        await kernel.stopped;
      }
      expect(await catalog.projects(), isEmpty);
      expect(
        await AcpCatalog(agentId: 'mock-acp', file: path).projects(),
        isEmpty,
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test('reopening an unsent session does not index its retained id', () async {
    final catalog = AcpCatalog(
      agentId: 'mock-acp',
      file: p.join(dir.path, 'retained.json'),
    );
    final descriptor = KernelDescriptor(
      id: 'mock-acp',
      label: 'Mock ACP',
      icon: Icons.hub,
      description: '',
      create: (_) => throw UnimplementedError(),
    );
    final transports = <MockAcpTransport>[];
    final kernel = AcpKernel(
      descriptor,
      const KernelContext(cwd: '/tmp/project'),
      (_) async {
        final transport = MockAcpTransport();
        transports.add(transport);
        return transport;
      },
      catalog: catalog,
    );
    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    kernel.release();
    await kernel.stopped;
    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(transports, hasLength(2));
    expect(
      transports.last.written.any((m) => m['method'] == 'session/load'),
      isTrue,
    );
    expect(await catalog.projects(), isEmpty);
    kernel.dispose();
    await kernel.stopped;
  });

  test('AcpKernel upserts after session/load', () async {
    final path = p.join(dir.path, 'acp-sessions-load.json');
    final catalog = AcpCatalog(agentId: 'mock-acp', file: path);
    final transport = MockAcpTransport();
    final descriptor = KernelDescriptor(
      id: 'mock-acp',
      label: 'Mock ACP',
      icon: Icons.hub,
      description: '',
      catalog: catalog,
      create: (_) => throw UnimplementedError(),
    );
    final kernel = AcpKernel(
      descriptor,
      KernelContext(
        cwd: 'ssh://box/tmp/project',
        resume: SessionRecord(
          id: 'sess_history',
          title: 'Earlier',
          updatedAt: DateTime.utc(2026, 10, 9),
          cwd: 'ssh://box/tmp/project',
        ),
      ),
      (_) async => transport,
      catalog: catalog,
    );

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(kernel.sessionId, 'sess_history');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final sessions = await catalog.sessionsIn('ssh://box/tmp/project');
    expect(sessions.single.id, 'sess_history');
    expect(sessions.single.title, 'Earlier');
    expect(sessions.single.updatedAt, DateTime.utc(2026, 10, 9));
    kernel.send(const KernelTurn(id: 'followup', text: 'Follow-up question'));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final updated = (await catalog.sessionsIn('ssh://box/tmp/project')).single;
    expect(updated.title, 'Earlier');
    expect(updated.updatedAt.isAfter(sessions.single.updatedAt), isTrue);
    expect(
      transport.written.any((message) => message['method'] == 'session/load'),
      isTrue,
    );
    kernel.dispose();
  });
}
