import 'dart:async';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements AcpTransport {
  _Transport({
    this.stallInitialize = false,
    this.rejectLoad = false,
    this.stallLoad = false,
    this.closeGate,
  });

  final bool stallInitialize;
  final bool rejectLoad;
  final bool stallLoad;
  final Completer<void>? closeGate;
  final _out = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final written = <Map<String, Object?>>[];
  bool closed = false;
  Object? prompt;
  int get prompts =>
      written.where((m) => m['method'] == 'session/prompt').length;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    if (closed) throw StateError('transport already closed');
    written.add(message);
    switch (message['method']) {
      case 'initialize':
        if (!stallInitialize) reply(message, {'protocolVersion': 1});
      case 'session/new':
        reply(message, {'sessionId': 'kept-session'});
      case 'session/load':
        if (stallLoad) return;
        if (rejectLoad) {
          _out.add({
            'jsonrpc': '2.0',
            'id': message['id'],
            'error': {'message': 'session/load unsupported'},
          });
        } else {
          text('replayed history');
          reply(message, {});
        }
      case 'session/prompt':
        prompt = message['id'];
    }
  }

  void reply(Map<String, Object?> message, Map<String, Object?> result) =>
      _out.add({'jsonrpc': '2.0', 'id': message['id'], 'result': result});

  void text(String text) => _out.add({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {
      'sessionId': 'kept-session',
      'update': {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': text},
      },
    },
  });

  void complete() {
    _out.add({
      'jsonrpc': '2.0',
      'id': prompt,
      'result': {'stopReason': 'end_turn'},
    });
    prompt = null;
  }

  @override
  Future<void> close() {
    closed = true;
    if (!_out.isClosed) unawaited(_out.close());
    return closeGate?.future ?? Future.value();
  }
}

Future<void> _until(bool Function() check) async {
  final watch = Stopwatch()..start();
  while (!check()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw TimeoutException('lifecycle did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late List<_Transport> transports;
  late AcpKernel kernel;
  late ChatSession session;
  late List<KernelEvent> events;
  var mcpClosed = 0;
  _Transport Function() makeTransport = _Transport.new;

  setUp(() {
    transports = [];
    events = [];
    mcpClosed = 0;
    makeTransport = _Transport.new;
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'lifecycle-acp',
      label: 'Lifecycle ACP',
      icon: Icons.hub,
      description: 'test',
      create: (context) {
        kernel = AcpKernel(
          descriptor,
          context,
          (_) async {
            final transport = makeTransport();
            transports.add(transport);
            return transport;
          },
          loadMcpServers: (_, _) async =>
              AcpMcpServers(onClose: () => mcpClosed++),
        );
        kernel.events.listen(events.add);
        return kernel;
      },
    );
    session = ChatSession(
      kernel: descriptor,
      historyCount: 0,
      kernelContext: const KernelContext(cwd: '/tmp/project'),
    );
  });

  tearDown(() async {
    session.dispose();
    await kernel.stopped;
  });

  Future<_Transport> ready() async {
    await _until(() => kernel.health.status == KernelHealthStatus.ready);
    return transports.last;
  }

  test('idle ACP releases when its last view detaches', () async {
    session.attach();
    final transport = await ready();
    session.detach();
    await pumpEventQueue();
    expect(transport.closed, isTrue);
    expect(kernel.health.status, KernelHealthStatus.idle);
    expect(kernel.sessionId, 'kept-session');
    expect(mcpClosed, 1);
  });

  test(
    'unsupported resume fails instead of silently creating a session',
    () async {
      session.attach();
      await ready();
      session.detach();
      await pumpEventQueue();
      makeTransport = () => _Transport(rejectLoad: true);
      session.attach();
      await _until(() => kernel.health.status == KernelHealthStatus.failed);
      expect(kernel.health.message, contains('session/load unsupported'));
      expect(kernel.sessionId, 'kept-session');
      expect(transports.last.closed, isTrue);
      expect(
        transports.last.written.where((m) => m['method'] == 'session/new'),
        isEmpty,
      );
    },
  );

  test(
    'leaving during initialize closes it and returning starts afresh',
    () async {
      makeTransport = () => _Transport(stallInitialize: true);
      session.attach();
      await _until(
        () => transports.isNotEmpty && transports.last.written.isNotEmpty,
      );
      final first = transports.single;
      session.detach();
      await pumpEventQueue();
      expect(first.closed, isTrue);
      expect(kernel.health.status, KernelHealthStatus.idle);
      makeTransport = _Transport.new;
      session.attach();
      await ready();
      expect(transports, hasLength(2));
      expect(transports.last.closed, isFalse);
    },
  );

  test(
    'queued prompt survives leaving before initialization finishes',
    () async {
      makeTransport = () => _Transport(stallInitialize: true);
      session.attach();
      await _until(
        () => transports.isNotEmpty && transports.last.written.isNotEmpty,
      );
      final transport = transports.single;
      kernel.send(const KernelTurn(id: 'queued', text: 'work'));
      session.detach();
      await pumpEventQueue();
      expect(transport.closed, isFalse);
      transport.reply(transport.written.first, {'protocolVersion': 1});
      await _until(() => transport.prompts == 1);
      transport.complete();
      await _until(() => transport.closed);
      expect(events.whereType<TurnEnded>(), hasLength(1));
    },
  );

  test('replacement waits for the old process to finish closing', () async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    makeTransport = () => _Transport(closeGate: gate);
    session.attach();
    final first = await ready();
    session.detach();
    await pumpEventQueue();
    expect(first.closed, isTrue);
    makeTransport = _Transport.new;
    session.attach();
    await pumpEventQueue();
    expect(transports, hasLength(1));
    gate.complete();
    await ready();
    expect(transports, hasLength(2));
  });

  test(
    'command choice after a prompt keeps background ACP until answered',
    () async {
      session.attach();
      final transport = await ready();
      kernel.send(const KernelTurn(id: 'permission', text: 'work'));
      await _until(() => transport.prompts == 1);
      transport._out.add({
        'jsonrpc': '2.0',
        'id': 'permission-rpc',
        'method': 'session/request_permission',
        'params': {
          'toolCall': {'title': '/choose', 'kind': 'command'},
          'options': [
            {'optionId': 'choice', 'name': 'Choice'},
          ],
        },
      });
      await pumpEventQueue();
      session.detach();
      transport.complete();
      await pumpEventQueue();
      expect(transport.closed, isFalse);
      final request = events.whereType<InteractionRequested>().single.request;
      kernel.answer(
        request.id,
        const QuestionAnswer([
          ['Choice'],
        ]),
      );
      await pumpEventQueue();
      expect(transport.closed, isTrue);
      expect(
        transport.written.where((m) => m['id'] == 'permission-rpc'),
        hasLength(1),
      );
    },
  );

  test(
    'app exit includes a previously disposed but still closing ACP',
    () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      makeTransport = () => _Transport(closeGate: gate);
      session.attach();
      await ready();
      kernel.dispose();
      var finished = false;
      final stopping = AcpKernel.stopAll().then((_) => finished = true);
      await pumpEventQueue();
      expect(finished, isFalse);
      gate.complete();
      await stopping;
      expect(finished, isTrue);
    },
  );

  test(
    'interrupted initial history load releases and replays without duplicates',
    () async {
      final first = _Transport(stallLoad: true);
      final second = _Transport();
      var launches = 0;
      final other = AcpKernel(
        kernel.descriptor,
        KernelContext(
          resume: SessionRecord(
            id: 'kept-session',
            title: 'saved',
            updatedAt: DateTime.utc(2026),
            cwd: '/tmp/project',
          ),
        ),
        (_) async => launches++ == 0 ? first : second,
      );
      addTearDown(() async {
        other.dispose();
        await other.stopped;
      });
      final items = <String>{};
      other.events.listen((event) {
        if (event is ItemUpserted) items.add(event.id);
        if (event is ItemRemoved) items.remove(event.id);
      });
      other.prepare();
      await _until(
        () => first.written.any((m) => m['method'] == 'session/load'),
      );
      first._out.add({
        'method': 'session/update',
        'params': {
          'sessionId': 'kept-session',
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': 'partial'},
          },
        },
      });
      first.text('partial answer');
      await pumpEventQueue();
      expect(items, hasLength(2));
      other.release();
      await other.stopped;
      expect(first.closed, isTrue);
      expect(other.health.status, KernelHealthStatus.idle);
      expect(items, isEmpty);
      other.prepare();
      await _until(() => other.health.status == KernelHealthStatus.ready);
      expect(items, hasLength(1));
      expect(
        second.written.where((m) => m['method'] == 'session/new'),
        isEmpty,
      );
    },
  );

  test('shutdown is bounded even if launch has not returned yet', () async {
    final launched = Completer<AcpTransport>();
    final transport = _Transport();
    final other = AcpKernel(
      kernel.descriptor,
      const KernelContext(),
      (_) => launched.future,
    );
    other.prepare();
    await pumpEventQueue();
    other.dispose();
    await expectLater(other.stopped, throwsA(isA<TimeoutException>()));
    launched.complete(transport);
    await other.stopped;
    expect(transport.closed, isTrue);
    expect(transport.written, isEmpty);
  });

  test(
    'failed shutdown is reported and blocks a replacement process',
    () async {
      final gate = Completer<void>();
      final transport = _Transport(closeGate: gate);
      var launches = 0;
      final other = AcpKernel(kernel.descriptor, const KernelContext(), (
        _,
      ) async {
        launches++;
        return transport;
      });
      other.prepare();
      await _until(() => other.health.status == KernelHealthStatus.ready);
      other.release();
      final stopped = expectLater(other.stopped, throwsStateError);
      gate.completeError(StateError('failed to exit'));
      await stopped;
      other.prepare();
      await _until(() => other.health.status == KernelHealthStatus.failed);
      expect(launches, 1);
      expect(other.health.message, contains('failed to exit'));
      other.dispose();
      await expectLater(other.stopped, throwsStateError);
    },
  );

  test('one remaining view keeps the connection', () async {
    session.attach();
    session.attach();
    final transport = await ready();
    session.detach();
    await pumpEventQueue();
    expect(transport.closed, isFalse);
    session.detach();
    await pumpEventQueue();
    expect(transport.closed, isTrue);
  });

  test('background work continues, then releases on completion', () async {
    session.attach();
    final transport = await ready();
    kernel.send(const KernelTurn(id: 'turn', text: 'work'));
    await _until(() => transport.prompts == 1);
    session.detach();
    await pumpEventQueue();
    expect(transport.closed, isFalse);
    transport.text('background answer');
    transport.complete();
    await pumpEventQueue();
    expect(events.whereType<TextDelta>().last.text, 'background answer');
    expect(events.whereType<TurnEnded>(), hasLength(1));
    expect(transport.closed, isTrue);
  });

  test('returning while busy cancels the deferred release', () async {
    session.attach();
    final transport = await ready();
    kernel.send(const KernelTurn(id: 'turn', text: 'work'));
    await _until(() => transport.prompts == 1);
    session.detach();
    await pumpEventQueue();
    session.attach();
    transport.complete();
    await pumpEventQueue();
    expect(transport.closed, isFalse);
    expect(transports, hasLength(1));
  });

  test(
    'reattach reloads the same session without duplicating transcript',
    () async {
      session.attach();
      final first = await ready();
      kernel.send(const KernelTurn(id: 'first', text: 'question'));
      await _until(() => first.prompts == 1);
      first.text('answer');
      first.complete();
      await pumpEventQueue();
      final count = session.itemCount;
      session.detach();
      await pumpEventQueue();
      session.attach();
      await ready();
      expect(transports, hasLength(2));
      final second = transports.last;
      final load = second.written.singleWhere(
        (m) => m['method'] == 'session/load',
      );
      expect((load['params'] as Map)['sessionId'], 'kept-session');
      expect(
        second.written.where((m) => m['method'] == 'session/new'),
        isEmpty,
      );
      expect(session.itemCount, count);
      kernel.send(const KernelTurn(id: 'second', text: 'continue'));
      await _until(() => second.prompts == 1);
      second.text('new answer');
      second.complete();
      await pumpEventQueue();
      expect(session.itemCount, greaterThan(count));
    },
  );

  test(
    'stopped waits for transport cleanup rather than only cancelling messages',
    () async {
      final gate = Completer<void>();
      final transport = _Transport(closeGate: gate);
      final other = AcpKernel(
        kernel.descriptor,
        const KernelContext(),
        (_) async => transport,
      );
      other.prepare();
      await _until(() => other.health.status == KernelHealthStatus.ready);
      other.dispose();
      var stopped = false;
      final waiting = other.stopped.then((_) => stopped = true);
      await pumpEventQueue();
      expect(stopped, isFalse);
      gate.complete();
      await waiting;
      expect(transport.closed, isTrue);
    },
  );

  test(
    'disposing during a delayed launch waits and closes the late transport',
    () async {
      final launched = Completer<AcpTransport>();
      final transport = _Transport();
      final other = AcpKernel(
        kernel.descriptor,
        const KernelContext(),
        (_) => launched.future,
      );
      other.prepare();
      await pumpEventQueue();
      other.dispose();
      var stopped = false;
      final waiting = other.stopped.then((_) => stopped = true);
      await pumpEventQueue();
      expect(stopped, isFalse);
      launched.complete(transport);
      await waiting;
      expect(transport.closed, isTrue);
      expect(transport.written, isEmpty);
    },
  );
}
