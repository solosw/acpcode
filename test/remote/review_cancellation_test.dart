@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/remote/remote_services.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

class _Connector extends MemoryConnector {
  _Connector(super.dataDir);

  int openings = 0;
  Future<void>? blocked;

  @override
  Future<SshConnection> call(
    SshTarget target, {
    void Function(String message)? onProgress,
  }) async {
    await blocked;
    final connection = await super.call(target, onProgress: onProgress);
    final peer = links.last.server.peer;
    final open = peer.handlers[RemoteProtocol.reviewOpen]!;
    peer.handlers[RemoteProtocol.reviewOpen] = (params, call) {
      openings++;
      return open(params, call);
    };
    return connection;
  }
}

class _Host extends SshHost {
  _Host(MemoryConnector connector) : super('dev', connect: connector.call);

  final listeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }
}

class _Kernel with KernelEventSource implements AgentKernel {
  _Kernel(this.descriptor);

  @override
  final KernelDescriptor descriptor;
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  String get sessionId => 'cancellation-session';
  @override
  void prepare() {}
  @override
  void dispose() => closeEvents();
  @override
  Future<void> get stopped async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late Directory temp;
  late String root;
  late _Connector connector;
  late _Host host;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('review-cancellation-');
    root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
    File(p.join(root, 'file.txt')).writeAsStringSync('before\n');
    connector = _Connector(p.join(temp.path, 'server'));
    host = _Host(connector);
  });

  tearDown(() async {
    await host.close();
    host.dispose();
    temp.deleteSync(recursive: true);
  });

  test('cancels before the first SSH connection is ready', () async {
    final gate = Completer<void>();
    final closed = Completer<void>();
    connector.blocked = gate.future;
    try {
      final opening = remoteReviewStore(
        host,
        cancel: closed.future,
      ).then<Object?>((store) => store, onError: (Object error) => error);
      await until(() => host.state == SshHostState.connecting);
      closed.complete();
      expect(
        await opening.timeout(const Duration(seconds: 1)),
        isA<RpcCancelled>(),
      );
      expect(host.listeners, isEmpty);
      gate.complete();
      await host.ready;
      expect(connector.openings, 0);
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  });

  test('cancels the first review RPC without closing shared SSH', () async {
    final client = await host.ready;
    final entered = Completer<void>();
    final cancelled = Completer<void>();
    final closed = Completer<void>();
    connector.links.single.server.peer.handlers[RemoteProtocol.reviewOpen] =
        (_, call) async {
          entered.complete();
          await call.cancelled;
          cancelled.complete();
          return null;
        };
    final opening = remoteReviewStore(
      host,
      cancel: closed.future,
    ).then<Object?>((store) => store, onError: (Object error) => error);
    await entered.future.timeout(const Duration(seconds: 1));
    closed.complete();
    expect(
      await opening.timeout(const Duration(seconds: 1)),
      isA<RpcCancelled>(),
    );
    await cancelled.future.timeout(const Duration(seconds: 1));
    expect(host.listeners, isEmpty);
    expect(await client.stat(root), isNotNull);
  });

  test(
    'cancels the first opening waiting after SSH authentication fails',
    () async {
      await host.ready;
      final entered = Completer<void>();
      final closed = Completer<void>();
      final first = connector.links.single;
      first.server.peer.handlers[RemoteProtocol.reviewOpen] = (_, call) async {
        entered.complete();
        await call.cancelled;
        return null;
      };
      final count = host.listeners.length;
      final opening = remoteReviewStore(
        host,
        cancel: closed.future,
      ).then<Object?>((store) => store, onError: (Object error) => error);
      await entered.future.timeout(const Duration(seconds: 1));
      connector.failure = const SshConnectException(
        SshFailure.authentication,
        'expired login',
      );
      await first.drop();
      await until(
        () =>
            host.state == SshHostState.failed && host.listeners.length > count,
      );
      closed.complete();
      expect(
        await opening.timeout(const Duration(seconds: 1)),
        isA<RpcCancelled>(),
      );
      expect(host.listeners.length, count);
      final openings = connector.openings;
      connector.failure = null;
      await host.reconnect();
      await pumpEventQueue(times: 30);
      expect(connector.openings, openings);
    },
  );

  for (final disposedReview in ['original', 'resumed']) {
    test(
      'disposing the $disposedReview review keeps a shared external store usable',
      () async {
        final store = (await remoteReviewStore(host))!;
        final original = ChangeReview(store, root: root)
          ..session = 'shared-store';
        ChangeReview? resumed;
        var originalDisposed = false;
        var resumedDisposed = false;
        try {
          final file = File(p.join(root, 'file.txt'));
          await original.begin();
          file.writeAsStringSync('first edit\n');
          await original.observe();
          resumed = await ChangeReview.resume(
            store,
            'shared-store',
            root: root,
          );
          await resumed.begin();
          expect(resumed.changes.single.path, file.path);
          final ChangeReview survivor;
          if (disposedReview == 'original') {
            original.dispose();
            originalDisposed = true;
            survivor = resumed;
          } else {
            resumed.dispose();
            resumedDisposed = true;
            survivor = original;
          }
          file.writeAsStringSync('later edit\n');
          await survivor.observe();
          expect(survivor.failure, isNull);
          expect(survivor.changes.single.path, file.path);
          expect(await survivor.original(file.path)!(), 'before\n');
          await survivor.undoAll();
          expect(file.readAsStringSync(), 'before\n');
          expect(survivor.changes, isEmpty);
        } finally {
          if (!originalDisposed) original.dispose();
          if (!resumedDisposed) resumed?.dispose();
          store.dispose();
        }
      },
    );
  }

  test('disposing a review cancels its pending RPC and future calls', () async {
    final store = (await remoteReviewStore(host))!;
    final review = ChangeReview(store, root: root, ownsStore: true);
    final entered = Completer<void>();
    final cancelled = Completer<void>();
    final peer = connector.links.single.server.peer;
    peer.handlers[RemoteProtocol.reviewCall] = (_, call) async {
      entered.complete();
      await call.cancelled;
      cancelled.complete();
      return null;
    };
    final reading = store
        .current(p.join(root, 'file.txt'))
        .then<Object?>((value) => value, onError: (Object error) => error);
    await entered.future.timeout(const Duration(seconds: 1));
    review.dispose();
    expect(
      await reading.timeout(const Duration(seconds: 1)),
      isA<RpcCancelled>(),
    );
    await cancelled.future.timeout(const Duration(seconds: 1));
    await expectLater(
      store.current(p.join(root, 'file.txt')),
      throwsA(isA<RpcCancelled>()),
    );
    expect(host.state, SshHostState.connected);
  });

  test(
    'disposing a session cancels a review waiting for SSH reconnect',
    () async {
      final store = (await remoteReviewStore(host))!;
      final review = ChangeReview(store, root: root, ownsStore: true);
      late final KernelDescriptor descriptor;
      descriptor = KernelDescriptor(
        id: 'cancellation',
        label: 'Cancellation',
        description: '',
        icon: Icons.code,
        create: (_) => _Kernel(descriptor),
      );
      final session = ChatSession(
        kernel: descriptor,
        historyCount: 0,
        kernelContext: KernelContext(cwd: 'ssh://dev$root'),
        openReview: (_, {session}) async => review,
      );
      var disposed = false;
      try {
        session.attach();
        await pumpEventQueue(times: 30);
        await review.look();
        final count = host.listeners.length;
        // Follow a replacement store first: disposal must also cancel its wait.
        await host.close();
        final resumed = store.current(p.join(root, 'file.txt'));
        await until(() => host.listeners.length > count);
        await host.reconnect();
        expect(await resumed.timeout(const Duration(seconds: 1)), isNotNull);
        expect(host.listeners.length, count);
        await host.close();
        final reading = store
            .current(p.join(root, 'file.txt'))
            .then<Object?>((value) => value, onError: (Object error) => error);
        await until(() => host.listeners.length > count);
        session.dispose();
        disposed = true;
        expect(
          await reading.timeout(const Duration(seconds: 1)),
          isA<RpcCancelled>(),
        );
        expect(host.listeners.length, count);
        final openings = connector.openings;
        await host.reconnect();
        await pumpEventQueue(times: 30);
        expect(connector.openings, openings);
      } finally {
        if (!disposed) session.dispose();
      }
    },
  );
}
