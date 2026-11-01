import 'dart:io';

import 'package:baocode/kernel/acp/acp_catalog.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('acp-catalog-');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

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
