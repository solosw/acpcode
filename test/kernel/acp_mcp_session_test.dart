import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _CapabilityTransport extends MockAcpTransport {
  Object? _initializeId;
  Map<String, Object?> capabilities = {'http': true, 'sse': false};

  @override
  Stream<Map<String, Object?>> get messages => super.messages.map((message) {
    if (message['id'] != _initializeId) return message;
    return {
      ...message,
      'result': {
        ...(message['result'] as Map).cast<String, Object?>(),
        'agentCapabilities': {'mcpCapabilities': capabilities},
      },
    };
  });

  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == 'initialize') _initializeId = message['id'];
    super.write(message);
  }
}

void main() {
  KernelDescriptor descriptor() => KernelDescriptor(
    id: 'acp-test',
    label: 'ACP',
    icon: Icons.hub,
    description: 'Test',
    create: (_) => throw UnimplementedError(),
  );
  const servers = AcpMcpServers(
    servers: [
      {'name': 'browser', 'command': '/bin/mcp', 'args': [], 'env': []},
    ],
  );

  for (final resume in [false, true]) {
    test(
      'passes MCP to session/${resume ? 'load' : 'new'} after initialize',
      () async {
        final transport = _CapabilityTransport();
        var loads = 0;
        final context = KernelContext(
          cwd: 'ssh://dev/project',
          resume: resume
              ? SessionRecord(
                  id: 'saved',
                  title: 'Saved',
                  cwd: 'ssh://dev/project',
                  updatedAt: DateTime.utc(2026),
                )
              : null,
        );
        final kernel = AcpKernel(
          descriptor(),
          context,
          (_) async => transport,
          loadMcpServers: (receivedContext, capabilities) async {
            loads++;
            expect(identical(receivedContext, context), isTrue);
            expect(capabilities, {'http': true, 'sse': false});
            expect(transport.written.map((m) => m['method']), ['initialize']);
            return servers;
          },
        );
        addTearDown(kernel.dispose);
        kernel.prepare();
        kernel.prepare();
        await Future<void>.delayed(Duration.zero);
        expect(kernel.health.status, KernelHealthStatus.ready);
        final request = transport.written.singleWhere(
          (message) =>
              message['method'] == 'session/${resume ? 'load' : 'new'}',
        );
        expect((request['params'] as Map)['mcpServers'], servers.servers);
        expect((request['params'] as Map)['cwd'], '/project');
        expect(loads, 1);
      },
    );
  }

  test('missing optional capabilities default to an empty map', () async {
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(),
      (_) async => MockAcpTransport(),
      loadMcpServers: (_, capabilities) async {
        expect(capabilities, isEmpty);
        return const AcpMcpServers();
      },
    );
    addTearDown(kernel.dispose);
    kernel.prepare();
    await Future<void>.delayed(Duration.zero);
    expect(kernel.health.status, KernelHealthStatus.ready);
  });

  test('skipped MCP warnings appear in the conversation', () async {
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(),
      (_) async => MockAcpTransport(),
      loadMcpServers: (_, _) async => const AcpMcpServers(
        warnings: ['MCP browser skipped: unsupported transport.'],
      ),
    );
    addTearDown(kernel.dispose);
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);
    addTearDown(subscription.cancel);
    kernel.prepare();
    await Future<void>.delayed(Duration.zero);
    expect(kernel.health.status, KernelHealthStatus.ready);
    final notice = events.whereType<ItemUpserted>().single.item as NoticeItem;
    expect(notice.kind, NoticeKind.warning);
    expect(notice.text, contains('unsupported transport'));
  });

  test(
    'config read failure is reported, not silently replaced with no MCP',
    () async {
      final transport = MockAcpTransport();
      final kernel = AcpKernel(
        descriptor(),
        const KernelContext(),
        (_) async => transport,
        loadMcpServers: (_, _) async =>
            throw StateError('Remote config disconnected'),
      );
      addTearDown(kernel.dispose);
      kernel.prepare();
      await Future<void>.delayed(Duration.zero);
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(kernel.health.message, contains('Remote config disconnected'));
      expect(transport.written.map((m) => m['method']), ['initialize']);
    },
  );

  test('disposing during config loading does not create a session', () async {
    final transport = MockAcpTransport();
    final pending = Completer<AcpMcpServers>();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(),
      (_) async => transport,
      loadMcpServers: (_, _) => pending.future,
    );
    kernel.prepare();
    await Future<void>.delayed(Duration.zero);
    kernel.dispose();
    pending.complete(servers);
    await Future<void>.delayed(Duration.zero);
    expect(transport.written.map((m) => m['method']), ['initialize']);
  });

  test(
    'restart reloads configs and rechecks capabilities on the new agent',
    () async {
      final transports = <_CapabilityTransport>[];
      var loads = 0;
      final kernel = AcpKernel(
        descriptor(),
        const KernelContext(),
        (_) async {
          final transport = _CapabilityTransport();
          if (transports.isNotEmpty) transport.capabilities = {'sse': true};
          transports.add(transport);
          return transport;
        },
        loadMcpServers: (_, capabilities) async {
          loads++;
          expect(
            capabilities,
            loads == 1 ? {'http': true, 'sse': false} : {'sse': true},
          );
          return AcpMcpServers(
            servers: [
              {
                'name': 'server-$loads',
                'command': '/bin/server',
                'args': [],
                'env': [],
              },
            ],
          );
        },
      );
      addTearDown(kernel.dispose);
      kernel.prepare();
      await Future<void>.delayed(Duration.zero);
      kernel.restart();
      await Future<void>.delayed(Duration.zero);
      expect(loads, 2);
      final params = transports.last.written.last['params'] as Map;
      expect((params['mcpServers'] as List).single['name'], 'server-2');
      expect(kernel.health.status, KernelHealthStatus.ready);
    },
  );
  test('restart during MCP loading does not attach stale configs', () async {
    final pending = Completer<AcpMcpServers>();
    final transports = <MockAcpTransport>[];
    var loads = 0;
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(),
      (_) async {
        final transport = MockAcpTransport();
        transports.add(transport);
        return transport;
      },
      loadMcpServers: (_, _) {
        loads++;
        return loads == 1
            ? pending.future
            : Future.value(const AcpMcpServers());
      },
    );
    addTearDown(kernel.dispose);
    kernel.prepare();
    await Future<void>.delayed(Duration.zero);
    kernel.restart();
    await Future<void>.delayed(Duration.zero);
    pending.complete(servers);
    await Future<void>.delayed(Duration.zero);
    expect(transports.first.written.map((m) => m['method']), ['initialize']);
    final sessions = transports.last.written.where(
      (m) => m['method'] == 'session/new',
    );
    expect(sessions, hasLength(1));
    expect((sessions.single['params'] as Map)['mcpServers'], isEmpty);
    expect(kernel.health.status, KernelHealthStatus.ready);
  });
  test(
    'a prompt submitted during MCP loading waits for the configured session',
    () async {
      final transport = MockAcpTransport();
      final pending = Completer<AcpMcpServers>();
      final kernel = AcpKernel(
        descriptor(),
        const KernelContext(),
        (_) async => transport,
        loadMcpServers: (_, _) => pending.future,
      );
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 'early', text: 'hello'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.written.map((m) => m['method']), ['initialize']);
      pending.complete(servers);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final sessions = transport.written.where(
        (m) => m['method'] == 'session/new',
      );
      expect(sessions, hasLength(1));
      expect((sessions.single['params'] as Map)['mcpServers'], servers.servers);
      expect(transport.written.map((m) => m['method']), [
        'initialize',
        'session/new',
        'session/prompt',
      ]);
    },
  );
  test('dispose revokes MCP access returned after an obsolete load', () async {
    final pending = Completer<AcpMcpServers>();
    var closed = false;
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(),
      (_) async => MockAcpTransport(),
      loadMcpServers: (_, _) => pending.future,
    );
    kernel.prepare();
    await Future<void>.delayed(Duration.zero);
    kernel.dispose();
    pending.complete(AcpMcpServers(onClose: () => closed = true));
    await Future<void>.delayed(Duration.zero);
    expect(closed, isTrue);
  });

  test(
    'restart revokes only the old MCP access; dispose revokes the new one',
    () async {
      final closed = <int>{};
      var loads = 0;
      final kernel = AcpKernel(
        descriptor(),
        const KernelContext(),
        (_) async => MockAcpTransport(),
        loadMcpServers: (_, _) async {
          final id = ++loads;
          return AcpMcpServers(onClose: () => closed.add(id));
        },
      );
      kernel.prepare();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isEmpty);
      kernel.restart();
      await Future<void>.delayed(Duration.zero);
      expect(closed, {1});
      kernel.dispose();
      expect(closed, {1, 2});
    },
  );
  test('agent exit revokes its MCP access exactly once', () async {
    var closes = 0;
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(),
      (_) async => transport,
      loadMcpServers: (_, _) async => AcpMcpServers(onClose: () => closes++),
    );
    kernel.prepare();
    await Future<void>.delayed(Duration.zero);
    transport.close();
    await Future<void>.delayed(Duration.zero);
    expect(kernel.health.status, KernelHealthStatus.failed);
    expect(closes, 1);
    kernel.dispose();
    expect(closes, 1);
  });
}
