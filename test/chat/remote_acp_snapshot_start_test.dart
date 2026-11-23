@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

class _Gate {
  final entered = Completer<void>();
  final proceed = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return proceed.future;
  }

  void release() {
    if (!proceed.isCompleted) proceed.complete();
  }
}

/// Only the scheduling is gated: super.begin still takes real remote snapshots.
class _Review extends ChangeReview {
  _Review(super.store, {required super.root});

  _Gate? gate;

  @override
  Future<void> begin({Iterable<String>? roots}) async {
    await gate?.wait();
    await super.begin(roots: roots);
  }
}

/// The simulated remote agent edits the disk in response to session/prompt,
/// never sending a filesystem RPC, FileEdited, or a tool diff notification.
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
  final prompts = <Map<String, Object?>>[];
  void Function(int index)? onPrompt;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == 'session/prompt') {
      written.add(message);
      prompts.add(message);
      onPrompt?.call(prompts.length - 1);
      return;
    }
    super.write(message);
  }

  void complete(int index) => _messages.add({
    'jsonrpc': '2.0',
    'id': prompts[index]['id'],
    'result': {'stopReason': 'end_turn'},
  });

  @override
  Future<void> close() async {
    await super.close();
    await _subscription.cancel();
    await _messages.close();
  }
}

class _Harness {
  _Harness._(this.temp, this.review, this.openerGate) {
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'remote-snapshot-start',
      label: 'ACP',
      icon: Icons.hub,
      description: '',
      create: (context) =>
          kernel = AcpKernel(descriptor, context, (_) async => transport),
    );
    session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      historyCount: 0,
      kernelContext: KernelContext(cwd: 'ssh://dev${review.root}'),
      openReview: (_, {session}) async {
        if (openerGate case final gate?) await gate.wait();
        return review;
      },
    );
    subscription = kernel.events.listen(events.add);
  }

  static Future<_Harness> create({_Gate? openerGate, _Gate? beginGate}) async {
    final temp = Directory.systemTemp.createTempSync('remote-acp-baseline-');
    final root = Directory(p.join(temp.path, 'project'))..createSync();
    final data = Directory(p.join(temp.path, 'server'))..createSync();
    final previous = SshHosts.instance;
    SshHosts.instance = SshHosts(connect: MemoryConnector(data.path).call);
    _Harness? h;
    addTearDown(() async {
      if (h case final harness?) await harness.close();
      await SshHosts.instance.closeAll();
      SshHosts.instance = previous;
      temp.deleteSync(recursive: true);
    });
    final store = (await (await SshHosts.instance['dev'].ready).openReview())!;
    final review = _Review(store, root: root.resolveSymbolicLinksSync())
      ..gate = beginGate;
    return h = _Harness._(temp, review, openerGate);
  }

  final Directory temp;
  final _Review review;
  final _Gate? openerGate;
  final transport = _Transport();
  late final AcpKernel kernel;
  late final ChatSession session;
  late final StreamSubscription<KernelEvent> subscription;
  final events = <KernelEvent>[];
  bool disposed = false;

  String at(String name) => p.join(review.root, name);
  void write(String name, String text) =>
      File(at(name)).writeAsStringSync(text);
  String read(String name) => File(at(name)).readAsStringSync();

  Future<void> ready() async {
    session.attach();
    await until(() => kernel.health.status == KernelHealthStatus.ready);
  }

  void send(String text) => session.send(ComposerMessage(text: text));
  Future<void> prompted(int count) =>
      until(() => transport.prompts.length == count);

  Future<void> finish(int index) async {
    transport.complete(index);
    await until(() => events.whereType<TurnEnded>().length > index);
    // Drain the real turn-end observation already scheduled by ChatSession.
    await review.look();
    expect(events.whereType<FileEdited>(), isEmpty);
    expect(review.failure, isNull);
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    session.dispose();
  }

  Future<void> close() async {
    openerGate?.release();
    review.gate?.release();
    dispose();
    await kernel.stopped;
    await subscription.cancel();
  }
}

void main() {
  test(
    'SSH prompt waits for a delayed opener before a direct agent write',
    () async {
      final gate = _Gate();
      final h = await _Harness.create(openerGate: gate);
      h.write('agent.txt', 'original\n');
      h.transport.onPrompt = (_) => h.write('agent.txt', 'agent wrote\n');
      await h.ready();
      await gate.entered.future;
      h.send('edit directly');
      await pumpEventQueue(times: 50);
      expect(
        h.transport.prompts,
        isEmpty,
        reason: 'The first write must not become the remote snapshot baseline',
      );
      expect(h.read('agent.txt'), 'original\n');
      gate.release();
      await h.prompted(1);
      await h.finish(0);
      expect(h.session.fileChanges.single.path, h.at('agent.txt'));
      expect(h.session.fileChanges.single.tracked, isTrue);
      expect(await h.review.original(h.at('agent.txt'))!(), 'original\n');
      await h.review.undoAll();
      expect(h.read('agent.txt'), 'original\n');
    },
    skip: Platform.isWindows,
  );

  test(
    'SSH prompt waits for actual begin snapshot completion, not only open',
    () async {
      final gate = _Gate();
      final h = await _Harness.create(beginGate: gate);
      h.write('agent.txt', 'before\n');
      h.transport.onPrompt = (_) => h.write('agent.txt', 'after\n');
      await h.ready();
      await gate.entered.future;
      h.send('fast direct edit');
      await pumpEventQueue(times: 50);
      expect(h.transport.prompts, isEmpty);
      expect(h.read('agent.txt'), 'before\n');
      h.review.gate = null;
      gate.release();
      await h.prompted(1);
      await h.finish(0);
      expect(h.session.fileChanges.single.path, h.at('agent.txt'));
      expect(await h.review.original(h.at('agent.txt'))!(), 'before\n');
      await h.review.undoAll();
      expect(h.read('agent.txt'), 'before\n');
    },
    skip: Platform.isWindows,
  );

  test('SSH queued dispatch rebases intervening user writes before the next agent write', () async {
    final h = await _Harness.create();
    const original = 'agent=0\nline1\nline2\nline3\nline4\nuser=0\n';
    h.write('agent.txt', original);
    h.write('user.txt', 'user before\n');
    h.transport.onPrompt = (index) => h.write(
      'agent.txt',
      h
          .read('agent.txt')
          .replaceFirst(
            index == 0 ? 'agent=0' : 'agent=1',
            index == 0 ? 'agent=1' : 'agent=2',
          ),
    );
    await h.ready();
    h.send('first');
    await h.prompted(1);
    h.send('second queued');
    expect(h.session.queued, hasLength(1));
    final gate = h.review.gate = _Gate();
    await h.finish(0);
    await gate.entered.future;
    expect(h.transport.prompts, hasLength(1));
    h.write('user.txt', 'user between turns\n');
    h.write('agent.txt', h.read('agent.txt').replaceFirst('user=0', 'user=1'));
    h.review.gate = null;
    gate.release();
    await h.prompted(2);
    await h.finish(1);
    expect(h.session.fileChanges.map((change) => change.path), [
      h.at('agent.txt'),
    ]);
    await h.review.undoAll();
    expect(h.read('agent.txt'), original.replaceFirst('user=0', 'user=1'));
    expect(h.read('user.txt'), 'user between turns\n');
  }, skip: Platform.isWindows);

  test('SSH slash command awaits a fresh user baseline', () async {
    final h = await _Harness.create();
    h.write('agent.txt', 'before\n');
    h.write('user.txt', 'user before\n');
    h.transport.onPrompt = (_) => h.write('agent.txt', 'slash wrote\n');
    await h.ready();
    await h.review.begin();
    final gate = h.review.gate = _Gate();
    h.send('/splash edit');
    await gate.entered.future;
    expect(h.transport.prompts, isEmpty);
    h.write('user.txt', 'user before slash\n');
    h.review.gate = null;
    gate.release();
    await h.prompted(1);
    final prompt =
        (h.transport.prompts.single['params'] as Map)['prompt'] as List;
    expect(prompt, contains(containsPair('text', '/splash edit')));
    await h.finish(0);
    expect(h.session.fileChanges.map((change) => change.path), [
      h.at('agent.txt'),
    ]);
    expect(await h.review.original(h.at('agent.txt'))!(), 'before\n');
    await h.review.undoAll();
    expect(h.read('agent.txt'), 'before\n');
    expect(h.read('user.txt'), 'user before slash\n');
  }, skip: Platform.isWindows);

  test(
    'SSH dispose while opening a baseline prevents the pending prompt',
    () async {
      final gate = _Gate();
      final h = await _Harness.create(openerGate: gate);
      h.write('agent.txt', 'before\n');
      h.transport.onPrompt = (_) => h.write('agent.txt', 'unexpected\n');
      await h.ready();
      await gate.entered.future;
      h.send('never dispatch');
      await pumpEventQueue(times: 50);
      expect(h.transport.prompts, isEmpty);
      h.dispose();
      gate.release();
      await h.kernel.stopped;
      await pumpEventQueue(times: 50);
      expect(h.transport.prompts, isEmpty);
      expect(h.read('agent.txt'), 'before\n');
    },
    skip: Platform.isWindows,
  );

  test(
    'SSH cancelQueued during the next baseline prevents its prompt',
    () async {
      final h = await _Harness.create();
      h.write('agent.txt', 'before\n');
      h.transport.onPrompt = (index) {
        if (index != 0) h.write('agent.txt', 'unexpected\n');
      };
      await h.ready();
      h.send('first');
      await h.prompted(1);
      h.send('withdraw queued');
      final queuedId = h.session.queued.single.$1;
      final gate = h.review.gate = _Gate();
      await h.finish(0);
      await gate.entered.future;
      expect(h.transport.prompts, hasLength(1));
      expect(await h.kernel.cancelQueued(queuedId), isTrue);
      h.review.gate = null;
      gate.release();
      await pumpEventQueue(times: 50);
      await h.review.look();
      expect(h.transport.prompts, hasLength(1));
      expect(h.session.queued, isEmpty);
      expect(h.read('agent.txt'), 'before\n');
    },
    skip: Platform.isWindows,
  );
}
