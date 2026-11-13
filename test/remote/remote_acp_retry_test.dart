import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart'
    show RemoteProcess, SshConnectException, SshFailure;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/remote/remote_acp.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../fixtures/lsp/fake_lsp.dart' show dartExecutable;
import 'remote_harness.dart';

// The line-oriented agent from remote_acp_test.dart, extended with load and
// prompt replies. Its on-disk request log survives losing the server session.
const _agent = r'''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final log = File(args.single);
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.trim().isEmpty) return;
    final message = jsonDecode(line) as Map<String, Object?>;
    log.writeAsStringSync('$line\n', mode: FileMode.append);
    final method = message['method'];
    final id = message['id'];
    void reply(Map<String, Object?> result) => stdout.writeln(jsonEncode({
      'jsonrpc': '2.0', 'id': id, 'result': result,
    }));
    if (method == 'initialize') {
      if (Platform.environment['ACP_FAIL_INITIALIZE'] == '1') {
        stdout.writeln(jsonEncode({
          'jsonrpc': '2.0', 'id': id,
          'error': {'code': -32603, 'message': 'ACP initialization timed out'},
        }));
      } else {
        reply({'protocolVersion': 1, 'agentCapabilities': {'loadSession': true}});
      }
    } else if (method == 'session/new') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0', 'method': 'session/update',
        'params': {
          'sessionId': 'remote-session',
          'update': {
            'sessionUpdate': 'available_commands_update',
            'availableCommands': [
              {'name': 'remote-only', 'description': Directory.current.path},
            ],
          },
        },
      }));
      reply({'sessionId': 'remote-session'});
    } else if (method == 'session/load') {
      // Loading replays history, just as an ACP agent does. The client already
      // has these messages when recovering, so they must not appear twice.
      for (final previous in log.readAsLinesSync().map(jsonDecode)) {
        if (previous['method'] != 'session/prompt') continue;
        final text = (previous['params']['prompt'].first as Map)['text'];
        for (final update in ['user_message_chunk', 'agent_message_chunk']) {
          stdout.writeln(jsonEncode({
            'jsonrpc': '2.0', 'method': 'session/update',
            'params': {
              'sessionId': 'remote-session',
              'update': {
                'sessionUpdate': update,
                'content': {
                  'type': 'text',
                  'text': update == 'user_message_chunk' ? text : 'remote reply: $text',
                },
              },
            },
          }));
        }
      }
      reply({});
    } else if (method == 'session/prompt') {
      final params = message['params'] as Map;
      final prompt = params['prompt'] as List;
      final text = (prompt.first as Map)['text'];
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0', 'method': 'session/update',
        'params': {
          'sessionId': params['sessionId'],
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'remote reply: $text'},
          },
        },
      }));
      reply({'stopReason': 'end_turn'});
    }
  });
}
''';

// The remote process really exists. The first close either times out or
// stays pending behind firstClose. Every successful close confirms its exit;
// gates make replacement ordering observable without racing timers.
class _CloseTimeoutOnce implements AcpTransport {
  _CloseTimeoutOnce(this.inner, this.process, {this.firstClose});

  final Completer<void>? firstClose;
  Future<void> Function()? beforeExit;

  final AcpTransport inner;
  final RemoteProcess process;
  final allowExit = Completer<void>();
  int closeCalls = 0;
  bool exited = false;
  final timeout = TimeoutException(
    'ACP process did not exit after forced termination.',
  );

  @override
  Stream<Map<String, Object?>> get messages => inner.messages;

  @override
  void write(Map<String, Object?> message) => inner.write(message);

  @override
  Future<void> close() async {
    closeCalls++;
    if (closeCalls == 1) {
      if (firstClose case final gate?) {
        await gate.future;
        await cleanup();
        return;
      }
      throw timeout;
    }
    await allowExit.future;
    await cleanup();
  }

  Future<void> cleanup() async {
    if (firstClose case final gate? when !gate.isCompleted) gate.complete();
    if (!allowExit.isCompleted) allowExit.complete();
    await beforeExit?.call();
    await inner.close();
    await process.exitCode;
    exited = true;
  }
}

void main() {
  late Directory temp;
  late Directory project;
  late File script;
  late File log;
  late MemoryConnector connector;
  late SshHosts previousHosts;
  ChatSession? session;
  _CloseTimeoutOnce? timedOut;
  var launches = 0;
  Future<void> Function()? connectGate;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('baocode-acp-retry-');
    project = Directory(p.join(temp.path, 'project'))..createSync();
    script = File(p.join(temp.path, 'agent.dart'))..writeAsStringSync(_agent);
    log = File(p.join(temp.path, 'requests.jsonl'));
    final data = Directory(p.join(temp.path, 'server'))..createSync();
    connector = MemoryConnector(data.path);
    previousHosts = SshHosts.instance;
    connectGate = null;
    SshHosts.instance = SshHosts(
      connect: (target, {onProgress}) async {
        await connectGate?.call();
        return connector.call(target, onProgress: onProgress);
      },
    );
    session = null;
    timedOut = null;
    launches = 0;
  });

  tearDown(() async {
    try {
      session?.dispose();
      await timedOut?.cleanup();
      try {
        await session?.stopped;
      } on TimeoutException catch (error) {
        // The baseline retains the already asserted close timeout forever.
        // The real process has been stopped explicitly above in that case.
        if (!identical(error, timedOut?.timeout)) rethrow;
      }
    } finally {
      await SshHosts.instance.closeAll();
      SshHosts.instance = previousHosts;
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });

  List<Map<String, Object?>> requests(String method) => !log.existsSync()
      ? []
      : log
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .map((line) {
              return (jsonDecode(line) as Map).cast<String, Object?>();
            })
            .where((message) => message['method'] == method)
            .toList();

  ChatSession open({
    bool failFirstInitialize = false,
    Completer<void>? firstClose,
  }) {
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'remote-retry',
      label: 'Remote retry',
      icon: Icons.hub,
      description: 'test',
      create: (context) => AcpKernel(descriptor, context, (_) async {
        launches++;
        if (timedOut case final previous?) {
          expect(
            previous.exited,
            isTrue,
            reason: 'a new ACP process must wait for the previous exit',
          );
        }
        final host = SshHosts.instance['dev'];
        if (failFirstInitialize && launches == 1) {
          final client = await host.ready;
          final process = await client.start(
            dartExecutable,
            [script.path, log.path],
            cwd: project.path,
            login: false,
            environment: {'ACP_FAIL_INITIALIZE': '1'},
          );
          return timedOut = _CloseTimeoutOnce(
            RemoteAcpTransport.forProcess(process),
            process,
            firstClose: firstClose,
          );
        }
        return RemoteAcpTransport.start(
          host,
          dartExecutable,
          arguments: [script.path, log.path],
          cwd: project.path,
          login: false,
        );
      }),
    );
    return session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      historyCount: 0,
      kernelContext: KernelContext(
        cwd: RemoteLocation.of('dev', project.resolveSymbolicLinksSync()),
      ),
      openReview: (_, {session}) async => null,
    )..attach();
  }

  Future<void> settled(ChatSession chat) => until(
    () =>
        chat.health.status == KernelHealthStatus.ready ||
        chat.health.status == KernelHealthStatus.failed,
  );

  Future<void> sendOnce(ChatSession chat, String text) async {
    final before = requests('session/prompt').length;
    chat.send(ComposerMessage(text: text));
    await until(() => requests('session/prompt').length > before);
    await until(() => !chat.isStreaming);
    final prompts = requests('session/prompt');
    expect(
      prompts.length,
      before + 1,
      reason: 'one composer submission must produce exactly one ACP prompt',
    );
    final params = prompts.last['params'] as Map;
    expect(params['sessionId'], chat.sessionId);
    expect(
      (params['prompt'] as List)
          .whereType<Map>()
          .where((part) => part['type'] == 'text')
          .map((part) => part['text']),
      contains(text),
    );
    expect(
      [for (var i = 0; i < chat.itemCount; i++) chat.itemAt(i)]
          .whereType<AssistantTextItem>()
          .map((item) => item.text),
      contains('remote reply: $text'),
    );
    expect(
      chat.health.status,
      KernelHealthStatus.ready,
      reason: chat.health.message,
    );
  }

  for (final closeFails in [false, true]) {
    test(
      closeFails
          ? 'Retry rechecks a close that fails after SSH reconnect failed'
          : 'Retry keeps an unfinished close after SSH reconnect fails',
      () async {
        final closeGate = Completer<void>();
        final chat = open(failFirstInitialize: true, firstClose: closeGate);
        await settled(chat);
        expect(chat.health.status, KernelHealthStatus.failed);
        expect(chat.health.message, contains('ACP initialization timed out'));
        final old = timedOut!;
        await until(() => old.closeCalls == 1);
        final link = connector.links.single;
        // Closing the RPC peer forces a new SSH connection but leaves the
        // old server/child alive. Its real shutdown stays behind closeGate.
        old.beforeExit = link.server.shutdown;
        final refused = Completer<void>();
        final resumed = Completer<void>();
        var reconnects = 0;
        connectGate = () async {
          reconnects++;
          if (reconnects == 1) {
            await refused.future;
            throw const SshConnectException(
              SshFailure.authentication,
              'SSH reconnect refused',
            );
          }
          await resumed.future;
        };
        link.client.peer.close();
        chat.restart();
        await until(() => reconnects == 1);
        refused.complete();
        // Observe SSH itself: Retry may still be waiting for the old close
        // before it reports failure. A second Retry must keep that wait.
        await until(
          () => SshHosts.instance['dev'].state == SshHostState.failed,
        );
        expect(SshHosts.instance['dev'].error, isA<SshConnectException>());
        expect(old.exited, isFalse);
        expect(closeGate.isCompleted, isFalse);

        chat.restart();
        await until(() => reconnects == 2);
        resumed.complete();
        await until(
          () => SshHosts.instance['dev'].state == SshHostState.connected,
        );
        await pumpEventQueue();
        expect(reconnects, 2);
        expect(connector.links.length, 2);
        expect(
          launches,
          1,
          reason: 'a failed SSH reconnect must not lose the unfinished close',
        );
        expect(old.closeCalls, 1);
        expect(old.exited, isFalse);
        expect(requests('session/prompt'), isEmpty);

        if (closeFails) {
          closeGate.completeError(old.timeout);
          await until(
            () =>
                old.closeCalls > 1 ||
                chat.health.status == KernelHealthStatus.failed,
          );
          expect(
            old.closeCalls,
            2,
            reason:
                'a late close failure still requires a fresh exit confirmation',
          );
          expect(old.exited, isFalse);
          expect(old.allowExit.isCompleted, isFalse);
          expect(
            launches,
            1,
            reason: 'replacement must also wait for the repeated close',
          );
          old.allowExit.complete();
        } else {
          closeGate.complete();
        }
        await settled(chat);
        expect(
          chat.health.status,
          KernelHealthStatus.ready,
          reason: chat.health.message,
        );
        expect(old.exited, isTrue);
        expect(launches, 2);
        await sendOnce(chat, 'after SSH retry and old exit');
      },
    );
  }

  test('Retry redials after the first remote connection times out', () async {
    connector.failure = TimeoutException('remote connection timed out');
    final chat = open();
    await settled(chat);
    expect(chat.health.status, KernelHealthStatus.failed);
    expect(chat.health.message, contains('remote connection timed out'));
    expect(connector.attempts, 1);
    expect(connector.links, isEmpty);

    connector.failure = null;
    chat.restart();
    await settled(chat);
    expect(
      chat.health.status,
      KernelHealthStatus.ready,
      reason: chat.health.message,
    );
    expect(connector.attempts, 2);
    expect(chat.sessionId, 'remote-session');
    expect(requests('session/prompt'), isEmpty);
    await sendOnce(chat, 'after timeout');
  });

  test('Retry reconnects after a cached authentication failure', () async {
    connector.failure = const SshConnectException(
      SshFailure.authentication,
      'The host refused the key',
    );
    final chat = open();
    await settled(chat);
    expect(chat.health.status, KernelHealthStatus.failed);
    expect(chat.health.message, contains('The host refused the key'));
    expect(connector.attempts, 1);

    connector.failure = null;
    // Merely asking ready must keep the permanent failure cached. Only the
    // user's explicit Retry should clear it and dial the host again.
    await expectLater(
      SshHosts.instance['dev'].ready,
      throwsA(isA<SshConnectException>()),
    );
    expect(connector.attempts, 1);
    chat.restart();
    await settled(chat);
    expect(
      connector.attempts,
      2,
      reason: 'explicit Retry must reconnect instead of reusing ready failure',
    );
    expect(
      chat.health.status,
      KernelHealthStatus.ready,
      reason: chat.health.message,
    );
    await sendOnce(chat, 'after signing in');
  });

  test(
    'Retry rechecks a timed out close before starting a remote replacement',
    () async {
      final chat = open(failFirstInitialize: true);
      await settled(chat);
      expect(chat.health.status, KernelHealthStatus.failed);
      expect(chat.health.message, contains('ACP initialization timed out'));
      final old = timedOut!;
      await until(() => old.closeCalls == 1);
      expect(old.exited, isFalse);
      expect(launches, 1);

      chat.restart();
      await until(
        () =>
            old.closeCalls > 1 ||
            chat.health.status == KernelHealthStatus.failed,
      );
      expect(
        old.closeCalls,
        2,
        reason: 'Retry must confirm exit again after the earlier close timeout',
      );
      expect(old.exited, isFalse);
      expect(
        launches,
        1,
        reason: 'replacement must wait while the old process is alive',
      );
      expect(requests('session/prompt'), isEmpty);
      old.allowExit.complete();
      await settled(chat);
      expect(old.exited, isTrue);
      expect(launches, 2);
      expect(
        chat.health.status,
        KernelHealthStatus.ready,
        reason: chat.health.message,
      );
      await sendOnce(chat, 'after confirming exit');
      chat.dispose();
      session = null;
      await chat.stopped;
    },
  );

  test(
    'Retry loads the same ACP session after the remote server is lost',
    () async {
      final chat = open();
      await settled(chat);
      expect(
        chat.health.status,
        KernelHealthStatus.ready,
        reason: chat.health.message,
      );
      await sendOnce(chat, 'before losing host');
      final id = chat.sessionId;
      final previousClient = SshHosts.instance['dev'].client;
      final lost = connector.links.single;

      // End the actual server and child, then cut the RPC streams. Keep the
      // automatic host retry unavailable until the conversation shows failure.
      connector.failure = TimeoutException('remote server is unavailable');
      await lost.server.shutdown();
      await lost.drop();
      await until(() => chat.health.status == KernelHealthStatus.failed);
      await until(() => SshHosts.instance['dev'].error is TimeoutException);
      expect(chat.sessionId, id);

      connector.failure = null;
      chat.restart();
      await settled(chat);
      expect(
        chat.health.status,
        KernelHealthStatus.ready,
        reason: chat.health.message,
      );
      expect(SshHosts.instance['dev'].client, isNot(same(previousClient)));
      expect(connector.links.length, 2);
      expect(chat.sessionId, id);
      expect(
        requests('session/new').length,
        1,
        reason:
            'recover the existing conversation rather than create a new one',
      );
      expect(requests('session/load').length, 1);
      expect(
        (requests('session/load').single['params'] as Map)['sessionId'],
        id,
      );
      expect(
        requests('session/prompt').length,
        1,
        reason: 'Retry must not resend the previous prompt',
      );
      expect(
        [for (var i = 0; i < chat.itemCount; i++) chat.itemAt(i)]
            .whereType<AssistantTextItem>()
            .map((item) => item.text),
        ['remote reply: before losing host'],
        reason: 'session/load replay must not duplicate the retained history',
      );

      await sendOnce(chat, 'after loading again');
      expect(requests('session/prompt').length, 2);
      expect(
        [for (var i = 0; i < chat.itemCount; i++) chat.itemAt(i)]
            .whereType<AssistantTextItem>()
            .map((item) => item.text),
        [
          'remote reply: before losing host',
          'remote reply: after loading again',
        ],
      );
    },
  );
}
