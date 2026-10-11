import 'dart:io';

import 'package:baocode/kernel/acp/acp_catalog.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
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
    expect(await AcpCatalog(agentId: 'mock', file: path).sessionsIn('/tmp/a'),
        isEmpty);
  });

  test('AcpKernel upserts after session/new', () async {
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

    // Catalog write is unawaited from the kernel.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final sessions = await catalog.sessionsIn('/tmp/project');
    expect(sessions, [
      isA<SessionRecord>()
          .having((s) => s.id, 'id', 'acp_mock_session')
          .having((s) => s.cwd, 'cwd', '/tmp/project'),
    ]);
    kernel.dispose();
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
    expect(
      transport.written.any((message) => message['method'] == 'session/load'),
      isTrue,
    );
    kernel.dispose();
  });
}
