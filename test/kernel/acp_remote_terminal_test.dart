@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

const _session = 'acp_mock_session';

Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out awaiting remote terminal');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Transport extends MockAcpTransport {
  _Transport() {
    _subscription = super.messages.listen(
      _messages.add,
      onDone: _messages.close,
    );
  }
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  late final StreamSubscription<Map<String, Object?>> _subscription;
  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  void request(Object id, String method, Map<String, Object?> params) =>
      _messages.add({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
  @override
  Future<void> close() async {
    await super.close();
    await _subscription.cancel();
    await _messages.close();
  }
}

class _Harness {
  _Harness(String root, {List<String> folders = const []}) {
    kernel = AcpKernel(
      KernelDescriptor(
        id: 'remote-terminal-test',
        label: 'ACP',
        icon: Icons.hub,
        description: '',
        create: (_) => throw UnimplementedError(),
      ),
      KernelContext(
        cwd: RemoteLocation.of('dev', root),
        workspace: () => KernelWorkspace(folders: folders),
      ),
      (_) async => transport,
    );
    subscription = kernel.events.listen(events.add);
    addTearDown(() async {
      kernel.dispose();
      await kernel.stopped;
      await subscription.cancel();
    });
  }
  final transport = _Transport();
  final events = <KernelEvent>[];
  late final AcpKernel kernel;
  late final StreamSubscription<KernelEvent> subscription;
  int _nextId = 1000;

  Future<void> start() async {
    kernel.prepare();
    await _until(() => kernel.health.status == KernelHealthStatus.ready);
  }

  Object request(
    String method,
    Map<String, Object?> params, {
    String session = _session,
  }) {
    final id = _nextId++;
    transport.request(id, method, {'sessionId': session, ...params});
    return id;
  }

  Future<Map<String, Object?>> response(Object id) async {
    await _until(() => transport.written.any((m) => m['id'] == id));
    return transport.written.firstWhere((m) => m['id'] == id);
  }

  List<ApprovalRequest> get approvals => [
    for (final event in events.whereType<InteractionRequested>())
      if (event.request case final ApprovalRequest request) request,
  ];
  Future<(Object, ApprovalRequest)> pending(
    String script, {
    Map<String, Object?> extra = const {},
    String session = _session,
  }) async {
    final count = approvals.length;
    final id = request('terminal/create', {
      'command': '/bin/sh',
      'args': ['-c', script],
      ...extra,
    }, session: session);
    await _until(() => approvals.length > count);
    return (id, approvals.last);
  }

  void approve(ApprovalRequest request, {bool allow = true}) => kernel.answer(
    request.id,
    ApprovalAnswer(allow ? ApprovalDecision.allowOnce : ApprovalDecision.deny),
  );
  Future<String> create(
    String script, {
    Map<String, Object?> extra = const {},
    String session = _session,
  }) async {
    final (id, approval) = await pending(
      script,
      extra: extra,
      session: session,
    );
    approve(approval);
    final reply = await response(id);
    expect(reply['error'], isNull, reason: '$reply');
    return (reply['result'] as Map)['terminalId'] as String;
  }

  Future<Map> call(
    String method,
    String terminalId, {
    String session = _session,
  }) async {
    final reply = await response(
      request(method, {'terminalId': terminalId}, session: session),
    );
    expect(reply['error'], isNull, reason: '$reply');
    return reply['result'] as Map;
  }
}

void main() {
  late Directory project;
  late Directory data;
  late String root;
  late MemoryConnector connector;

  setUp(() {
    project = Directory.systemTemp.createTempSync(
      'baocode-acp-remote-terminal-',
    );
    data = Directory.systemTemp.createTempSync('baocode-acp-remote-data-');
    root = project.resolveSymbolicLinksSync();
    connector = MemoryConnector(data.path);
    final previous = SshHosts.instance;
    SshHosts.instance = SshHosts(connect: connector.call);
    addTearDown(() async {
      await SshHosts.instance.closeAll();
      SshHosts.instance = previous;
      for (final dir in [project, data]) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    });
  });

  test('SSH advertises terminal support and executes the approved command through remote PTY', () async {
    final h = _Harness(root);
    await h.start();
    final initialize = h.transport.written.firstWhere(
      (m) => m['method'] == 'initialize',
    );
    expect(
      ((initialize['params'] as Map)['clientCapabilities'] as Map)['terminal'],
      isTrue,
    );
    final client = await SshHosts.instance['dev'].ready;
    final handler =
        connector.links.single.server.peer.handlers[RemoteProtocol.ptyStart]!;
    Map? launch;
    connector.links.single.server.peer.handlers[RemoteProtocol.ptyStart] =
        (params, token) {
          launch = params as Map;
          return handler(params, token);
        };
    final (requestId, approval) = await h.pending(
      r'printf "%s|%s" "$PWD" "$ACP_REMOTE_VALUE"; sleep 0.2; printf "|late"; printf "|stderr" >&2; exit 7',
      extra: {
        'env': [
          {'name': 'ACP_REMOTE_VALUE', 'value': 'spaces; not shell syntax'},
        ],
      },
    );
    expect(launch, isNull, reason: 'No process before approval');
    expect(approval.title, contains('dev'));
    expect(approval.reason, contains('remote'));
    final preview = jsonDecode((approval.preview as TextPreview).text) as Map;
    expect(preview['host'], 'dev');
    expect(preview['cwd'], root);
    h.approve(approval);
    final reply = await h.response(requestId);
    expect(reply['error'], isNull);
    final id = (reply['result'] as Map)['terminalId'] as String;
    expect(launch!['cwd'], root);
    expect(launch!['shellIntegration'], isFalse);
    expect(launch!['shell'], ['/bin/sh', '-c', (preview['args'] as List).last]);
    expect(launch!['environment'], {
      'ACP_REMOTE_VALUE': 'spaces; not shell syntax',
    }, reason: 'Never send the app environment to SSH');
    expect(launch!['workspaceRoots'], [root]);
    expect((await h.call('terminal/output', id))['exitStatus'], isNull);
    expect((await h.call('terminal/wait_for_exit', id))['exitCode'], 7);
    final output = (await h.call('terminal/output', id))['output'] as String;
    expect(output, contains('$root|spaces; not shell syntax|late|stderr'));
    expect(client.peer.isClosed, isFalse);
  });

  test('remote output is UTF-8 bounded and terminal control sequences are filtered', () async {
    final h = _Harness(root);
    await h.start();
    final id = await h.create(
      r"printf '\033]52;c;clipboard\007\033[31m前中文尾\033[0m'",
      extra: {'outputByteLimit': 7},
    );
    await h.call('terminal/wait_for_exit', id);
    final output = await h.call('terminal/output', id);
    expect(output['output'], '文尾');
    expect(output['truncated'], isTrue);
  });

  test('mixed workspaces only authorize folders on the session host', () async {
    final allowed = Directory(p.join(root, 'allowed'))..createSync();
    final localOnly = Directory.systemTemp.createTempSync(
      'baocode-local-only-',
    );
    final otherHost = Directory.systemTemp.createTempSync(
      'baocode-other-host-',
    );
    addTearDown(() {
      localOnly.deleteSync(recursive: true);
      otherHost.deleteSync(recursive: true);
    });
    final h = _Harness(
      allowed.path,
      folders: [
        localOnly.path,
        RemoteLocation.of('elsewhere', otherHost.path),
        RemoteLocation.of('dev', root),
      ],
    );
    await h.start();
    final id = await h.create('pwd', extra: {'cwd': root});
    await h.call('terminal/wait_for_exit', id);
    expect((await h.call('terminal/output', id))['output'], contains(root));
    for (final path in [localOnly.path, otherHost.path]) {
      final reply = await h.response(
        h.request('terminal/create', {'command': '/bin/echo', 'cwd': path}),
      );
      expect((reply['error'] as Map)['message'], contains('outside'));
    }
    expect(h.approvals, hasLength(1));
    expect(connector.attempts, 1);
  });

  test('remote symlink escape is rejected before approval', () async {
    final outside = Directory.systemTemp.createTempSync(
      'baocode-remote-outside-',
    );
    addTearDown(() => outside.deleteSync(recursive: true));
    Link(p.join(root, 'escape')).createSync(outside.path);
    final h = _Harness(root);
    await h.start();
    final reply = await h.response(
      h.request('terminal/create', {
        'command': '/bin/echo',
        'cwd': p.join(root, 'escape'),
      }),
    );
    expect((reply['error'] as Map)['message'], contains('outside'));
    expect(h.approvals, isEmpty);
  });

  test('replacing an approved remote cwd cannot redirect execution', () async {
    final cwd = Directory(p.join(root, 'cwd'))..createSync();
    final outside = Directory.systemTemp.createTempSync(
      'baocode-remote-redirect-',
    );
    addTearDown(() => outside.deleteSync(recursive: true));
    final marker = File(p.join(root, 'must-not-run'));
    final h = _Harness(root);
    await h.start();
    final (id, approval) = await h.pending(
      'touch "${marker.path}"',
      extra: {'cwd': cwd.path},
    );
    cwd.deleteSync();
    Link(cwd.path).createSync(outside.path);
    h.approve(approval);
    expect((await h.response(id))['error'], isNotNull);
    expect(marker.existsSync(), isFalse);
  });

  test('server rejects a cwd changed after client validation', () async {
    final cwd = Directory(p.join(root, 'cwd'))..createSync();
    final target = Directory(p.join(root, 'target'))..createSync();
    final marker = File(p.join(root, 'must-not-spawn'));
    final h = _Harness(root);
    await h.start();
    await SshHosts.instance['dev'].ready;
    final peer = connector.links.single.server.peer;
    final start = peer.handlers[RemoteProtocol.ptyStart]!;
    peer.handlers[RemoteProtocol.ptyStart] = (params, call) {
      cwd.deleteSync();
      Link(cwd.path).createSync(target.path);
      return start(params, call);
    };
    final (id, approval) = await h.pending(
      'touch "${marker.path}"',
      extra: {'cwd': cwd.path},
    );
    h.approve(approval);
    final reply = await h.response(id);
    expect(
      (reply['error'] as Map)['message'],
      contains('changed after approval'),
    );
    expect(marker.existsSync(), isFalse);
  });

  test(
    'remote stopTask is independent and escalates a command ignoring TERM',
    () async {
      final h = _Harness(root);
      await h.start();
      final first = await h.create(
        r"trap '' TERM; printf ready; while :; do sleep 1; done",
      );
      final second = await h.create('sleep 30');
      await _until(
        () => h.events.whereType<ItemUpserted>().any(
          (e) =>
              e.item is ToolCallItem &&
              (e.item as ToolCallItem).output == 'ready',
        ),
      );
      h.kernel.stopTask(first);
      expect((await h.call('terminal/wait_for_exit', first))['exitCode'], 137);
      expect((await h.call('terminal/output', second))['exitStatus'], isNull);
      final tasks = h.events.whereType<TasksReported>().last.tasks;
      expect(tasks.firstWhere((t) => t.id == first).canStop, isFalse);
      expect(tasks.firstWhere((t) => t.id == second).canStop, isTrue);
      await h.call('terminal/release', second);
    },
  );

  test('a denied remote command never reaches process creation', () async {
    final marker = File(p.join(root, 'denied'));
    final h = _Harness(root);
    await h.start();
    final (id, approval) = await h.pending('touch "${marker.path}"');
    h.approve(approval, allow: false);
    expect((await h.response(id))['error'], isNotNull);
    expect(marker.existsSync(), isFalse);
  });

  test('connection failure does not run a remote command locally', () async {
    connector.failure = const RpcClosed();
    final marker = File(p.join(root, 'no-local-fallback'));
    final h = _Harness(root);
    await h.start();
    final reply = await h.response(
      h.request('terminal/create', {
        'command': '/bin/sh',
        'args': ['-c', 'touch "${marker.path}"'],
      }),
    );
    expect(reply['error'], isNotNull);
    expect(h.approvals, isEmpty);
    expect(marker.existsSync(), isFalse);
    expect(connector.attempts, 1);
  });

  test('child sessions cannot read or kill another session terminal', () async {
    final h = _Harness(root);
    await h.start();
    h.transport.notify({
      'sessionUpdate': 'subagent_update',
      'sessionId': 'child',
      'state': {'state': 'running'},
    });
    final id = await h.create('sleep 30');
    for (final method in [
      'terminal/output',
      'terminal/wait_for_exit',
      'terminal/kill',
      'terminal/release',
    ]) {
      final reply = await h.response(
        h.request(method, {'terminalId': id}, session: 'child'),
      );
      expect((reply['error'] as Map)['code'], -32602);
    }
    final child = await h.create('printf child', session: 'child');
    await h.call('terminal/wait_for_exit', child, session: 'child');
    expect(
      (await h.call('terminal/output', child, session: 'child'))['output'],
      'child',
    );
    await h.call('terminal/kill', id);
  });

  test('remote release kills the command group, invalidates its id, and preserves output history', () async {
    final marker = File(p.join(root, 'leaked-child'));
    final h = _Harness(root);
    await h.start();
    final id = await h.create(
      'printf before; (sleep 1; touch "${marker.path}") & wait',
    );
    await _until(
      () => h.events.whereType<ItemUpserted>().any(
        (e) =>
            e.item is ToolCallItem &&
            (e.item as ToolCallItem).output == 'before',
      ),
    );
    await h.call('terminal/release', id);
    final reply = await h.response(
      h.request('terminal/output', {'terminalId': id}),
    );
    expect((reply['error'] as Map)['code'], -32602);
    expect(
      h.events
          .whereType<ItemUpserted>()
          .where((e) => e.item is ToolCallItem)
          .last
          .item,
      isA<ToolCallItem>().having((i) => i.output, 'retained output', 'before'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(marker.existsSync(), isFalse);
  });

  test(
    'a launch cancelled while waiting for remote start is cleaned up',
    () async {
      final h = _Harness(root);
      await h.start();
      await SshHosts.instance['dev'].ready;
      final peer = connector.links.single.server.peer;
      final start = peer.handlers[RemoteProtocol.ptyStart]!;
      final entered = Completer<void>();
      final resume = Completer<void>();
      addTearDown(() {
        if (!resume.isCompleted) resume.complete();
      });
      peer.handlers[RemoteProtocol.ptyStart] = (params, token) async {
        entered.complete();
        await resume.future;
        return start(params, token);
      };
      final exits = <Object?>[];
      final clientPeer = connector.links.single.client.peer;
      final exit = clientPeer.notificationHandlers[RemoteProtocol.ptyExit]!;
      clientPeer.notificationHandlers[RemoteProtocol.ptyExit] = (params) {
        exits.add(params);
        exit(params);
      };
      final (id, approval) = await h.pending('sleep 30');
      h.approve(approval);
      await entered.future;
      h.kernel.cancel();
      resume.complete();
      final reply = await h.response(id);
      expect(reply['error'], isNotNull);
      await _until(() => exits.isNotEmpty);
      expect(
        h.events
            .whereType<TasksReported>()
            .expand((e) => e.tasks)
            .where(
              (t) =>
                  t.kind == KernelTaskKind.command &&
                  t.status == CommandStatus.running,
            ),
        isEmpty,
      );
    },
  );

  test('losing SSH settles terminal waits and never restarts commands on a new connection', () async {
    final h = _Harness(root);
    await h.start();
    final id = await h.create('printf running; sleep 30');
    final waiting = h.response(
      h.request('terminal/wait_for_exit', {'terminalId': id}),
    );
    connector.failure = const RpcClosed();
    await connector.links.single.drop();
    final result = await waiting;
    expect(
      (result['error'] as Map)['message'],
      contains('SSH connection lost'),
    );
    final output = await h.call('terminal/output', id);
    expect(output['exitStatus'], {'exitCode': null, 'signal': null});
    connector.failure = null;
    await SshHosts.instance['dev'].reconnect();
    expect(connector.links, hasLength(2));
    final previousApprovals = h.approvals.length;
    final reply = await h.response(
      h.request('terminal/create', {'command': '/bin/echo'}),
    );
    expect(reply['error'], isNotNull);
    expect(h.approvals, hasLength(previousApprovals));
    expect(connector.links, hasLength(2));
  });

  test('disposing the kernel terminates all its remote terminals', () async {
    final h = _Harness(root);
    await h.start();
    final first = await h.create('sleep 30');
    final second = await h.create('sleep 30');
    expect(first, isNot(second));
    final exits = <Object?>[];
    final peer = connector.links.single.client.peer;
    final exit = peer.notificationHandlers[RemoteProtocol.ptyExit]!;
    peer.notificationHandlers[RemoteProtocol.ptyExit] = (params) {
      exits.add(params);
      exit(params);
    };
    h.kernel.dispose();
    await h.kernel.stopped;
    expect(exits, hasLength(2));
    expect(
      peer.isClosed,
      isFalse,
      reason: 'Do not close the shared SSH connection',
    );
  });
}
