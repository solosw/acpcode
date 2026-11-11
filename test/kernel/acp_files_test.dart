@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show BlobReviewStore;
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

const _sessionId = 'acp_mock_session';

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
  void Function()? onLoad;
  bool holdPrompt = false;
  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == 'session/load') onLoad?.call();
    if (holdPrompt && message['method'] == 'session/prompt') {
      written.add(message);
      return;
    }
    super.write(message);
  }

  @override
  Future<void> close() async {
    await super.close();
    await _subscription.cancel();
    await _messages.close();
  }
}

class _Harness {
  _Harness(
    this.temp, {
    String? location,
    ReviewStore? store,
    bool gated = false,
    SessionRecord? resume,
  }) {
    root = Directory(p.join(temp.path, 'project'))..createSync();
    final kept =
        store ?? BlobReviewStore.open(p.join(temp.path, 'checkpoints'));
    review = gated
        ? _GateReview(kept, root: root.path)
        : ChangeReview(kept, root: root.path);
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'files-test',
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
      kernelContext: KernelContext(cwd: location ?? root.path, resume: resume),
      openReview: (_, {session}) async => review,
    );
    subscription = kernel.events.listen(events.add);
    addTearDown(() async {
      session.dispose();
      await kernel.stopped;
      await subscription.cancel();
    });
  }
  final Directory temp;
  late final Directory root;
  late final ChangeReview review;
  late final AcpKernel kernel;
  late final ChatSession session;
  late final StreamSubscription<KernelEvent> subscription;
  final transport = _Transport();
  final events = <KernelEvent>[];
  int _nextId = 1000;
  String get outside => p.join(temp.path, 'outside.txt');
  Future<void> start() async {
    session.attach();
    await until(() => kernel.health.status == KernelHealthStatus.ready);
  }

  Object request(
    String method,
    Map<String, Object?> params, {
    Object? id,
    String session = _sessionId,
  }) {
    final rpcId = id ?? _nextId++;
    transport.request(rpcId, method, {'sessionId': session, ...params});
    return rpcId;
  }

  Future<Map<String, Object?>> response(Object id) async {
    await until(() => transport.written.any((m) => m['id'] == id));
    return transport.written.firstWhere((m) => m['id'] == id);
  }

  Future<void> write(String path, String text) async {
    final result = await response(
      request('fs/write_text_file', {'path': path, 'content': text}),
    );
    expect(result['error'], isNull, reason: '$result');
    expect(result['result'], isEmpty);
  }
}

class _GateWatch implements EditWatch {
  _GateWatch(this.review);
  final ChangeReview review;
  final entered = Completer<void>();
  final proceed = Completer<void>();
  @override
  Future<void> beforeEdit(String path) async {
    await review.before(path);
    entered.complete();
    await proceed.future;
  }

  @override
  Future<void> afterEdit(String path) => review.after(path);
}

class _GateReview extends ChangeReview {
  _GateReview(super.store, {required super.root});
  final entered = Completer<void>();
  final proceed = Completer<void>();
  @override
  Future<void> before(String path) async {
    await super.before(path);
    entered.complete();
    await proceed.future;
  }
}

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory(
      Directory.systemTemp
          .createTempSync('acp-files-')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
  });

  test(
    'advertises both filesystem capabilities locally and remotely',
    () async {
      final h = _Harness(temp);
      await h.start();
      Map capabilities(_Harness h) =>
          (h.transport.written.firstWhere(
                    (m) => m['method'] == 'initialize',
                  )['params']
                  as Map)['clientCapabilities']
              as Map;
      expect(capabilities(h)['fs'], {
        'readTextFile': true,
        'writeTextFile': true,
      });
      final other = Directory(p.join(temp.path, 'remote'))..createSync();
      final remote = _Harness(other, location: 'ssh://host/tmp/project');
      await remote.start();
      expect(capabilities(remote)['fs'], {
        'readTextFile': true,
        'writeTextFile': true,
      });
    },
  );

  test(
    'reads outside files, supports line ranges and preserves RPC id types',
    () async {
      final h = _Harness(temp);
      await h.start();
      File(h.outside).writeAsStringSync('one\r\ntwo\r\nthree\r\n');
      final full = await h.response(
        h.request('fs/read_text_file', {'path': h.outside}, id: 'read-full'),
      );
      expect(full['id'], 'read-full');
      expect((full['result'] as Map)['content'], 'one\r\ntwo\r\nthree\r\n');
      final range = await h.response(
        h.request('fs/read_text_file', {
          'path': h.outside,
          'line': 2,
          'limit': 1,
        }),
      );
      expect(range['id'], isA<int>());
      expect((range['result'] as Map)['content'], 'two');
      expect(h.review.changes, isEmpty);
    },
  );

  test(
    'outside edits appear in the chat review and undo restores original bytes',
    () async {
      final h = _Harness(temp);
      await h.start();
      final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode('before\r\n')];
      File(h.outside).writeAsBytesSync(bytes);
      await h.write(h.outside, 'after\n');
      await h.review.look();
      expect(h.session.fileChanges.single.path, h.outside);
      expect(h.session.fileChanges.single.tracked, isTrue);
      expect(h.session.fileChanges.single.conflict, isFalse);
      expect(h.session.fileChanges.single.added, 1);
      expect(h.session.fileChanges.single.removed, 1);
      await h.review.undoAll();
      expect(File(h.outside).readAsBytesSync(), bytes);
      expect(h.session.fileChanges, isEmpty);
    },
  );

  test('outside creation includes missing parents and is undoable', () async {
    final h = _Harness(temp);
    await h.start();
    final path = p.join(temp.path, 'outside', 'nested', 'new.txt');
    await h.write(path, 'created\n');
    expect(h.session.fileChanges.single.kind, FileChangeKind.added);
    expect(File(path).readAsStringSync(), 'created\n');
    await h.review.undoAll();
    expect(File(path).existsSync(), isFalse);
  });

  test(
    'pipelined writes retain the first baseline and keep starts a new one',
    () async {
      final h = _Harness(temp);
      await h.start();
      File(h.outside).writeAsStringSync('before\n');
      final first = h.request('fs/write_text_file', {
        'path': h.outside,
        'content': 'middle\n',
      });
      final second = h.request('fs/write_text_file', {
        'path': h.outside,
        'content': 'after\n',
      });
      expect((await h.response(first))['error'], isNull);
      expect((await h.response(second))['error'], isNull);
      expect(await h.review.original(h.outside)!(), 'before\n');
      await h.review.keepAll();
      await h.write(h.outside, 'last\n');
      await h.review.undoAll();
      expect(File(h.outside).readAsStringSync(), 'after\n');
    },
  );

  test('no-op writes and failures do not create pending changes', () async {
    final h = _Harness(temp);
    await h.start();
    File(h.outside).writeAsStringSync('same\n');
    await h.write(h.outside, 'same\n');
    final result = await h.response(
      h.request('fs/write_text_file', {'path': h.root.path, 'content': 'bad'}),
    );
    expect(result['error'], isNotNull);
    expect(h.review.failure, isNull);
    expect(h.session.fileChanges, isEmpty);
    await h.write(h.outside, 'changed\n');
    expect(h.session.fileChanges.single.path, h.outside);
  });

  test('invalid sessions and parameters fail without writing, then the queue recovers', () async {
    final h = _Harness(temp);
    await h.start();
    final invalid = [
      h.request('fs/write_text_file', {
        'path': h.outside,
        'content': 'bad',
      }, session: 'other'),
      h.request('fs/write_text_file', {
        'path': '../outside.txt',
        'content': 'bad',
      }),
      h.request('fs/write_text_file', {'path': h.outside, 'content': null}),
      h.request('fs/read_text_file', {'path': h.outside, 'line': 0}),
      h.request('fs/read_text_file', {'path': h.outside, 'limit': -1}),
    ];
    for (final id in invalid) {
      expect(((await h.response(id))['error'] as Map)['code'], -32602);
    }
    expect(File(h.outside).existsSync(), isFalse);
    final unknown = await h.response(
      h.request('fs/delete', {'path': h.outside}),
    );
    expect((unknown['error'] as Map)['code'], -32601);
    await h.write(h.outside, 'ok');
    expect(File(h.outside).readAsStringSync(), 'ok');
  });

  test(
    'cancelling during the checkpoint prevents the deferred write',
    () async {
      final h = _Harness(temp);
      await h.start();
      File(h.outside).writeAsStringSync('before\n');
      final gate = _GateWatch(h.review);
      h.kernel.editWatch = gate;
      final id = h.request('fs/write_text_file', {
        'path': h.outside,
        'content': 'after\n',
      });
      await gate.entered.future;
      h.kernel.cancel();
      gate.proceed.complete();
      expect((await h.response(id))['error'], isNotNull);
      expect(File(h.outside).readAsStringSync(), 'before\n');
      expect(h.review.changes, isEmpty);
    },
  );

  test('file symlinks track and undo their actual outside target', () async {
    final h = _Harness(temp);
    await h.start();
    File(h.outside).writeAsStringSync('before\n');
    final link = Link(p.join(h.root.path, 'link.txt'))..createSync(h.outside);
    await h.write(link.path, 'after\n');
    expect(h.session.fileChanges.single.path, h.outside);
    await h.review.undoAll();
    expect(File(h.outside).readAsStringSync(), 'before\n');
    expect(link.targetSync(), h.outside);
  }, skip: Platform.isWindows);

  test('new outside files keep the same key through a linked parent', () async {
    final h = _Harness(temp);
    await h.start();
    final target = Directory(p.join(temp.path, 'target'))..createSync();
    final link = Link(p.join(h.root.path, 'linked'))..createSync(target.path);
    final path = p.join(link.path, 'new.txt');
    await h.write(path, 'one\n');
    await h.write(path, 'two\n');
    expect(h.session.fileChanges.single.path, p.join(target.path, 'new.txt'));
    await h.review.undoAll();
    expect(File(path).existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('SSH outside writes use remote files and remote checkpoints', () async {
    final data = Directory(p.join(temp.path, 'server'))..createSync();
    final connector = MemoryConnector(data.path);
    final previous = SshHosts.instance;
    SshHosts.instance = SshHosts(connect: connector.call);
    addTearDown(() async {
      await SshHosts.instance.closeAll();
      SshHosts.instance = previous;
    });
    final client = await SshHosts.instance['dev'].ready;
    final store = (await client.openReview())!;
    final h = _Harness(
      temp,
      location: 'ssh://dev${p.join(temp.path, 'project')}',
      store: store,
    );
    await h.start();
    File(h.outside).writeAsStringSync('before\n');
    await h.write(h.outside, 'after\n');
    final read = await h.response(
      h.request('fs/read_text_file', {'path': h.outside}),
    );
    expect((read['result'] as Map)['content'], 'after\n');
    expect(h.session.fileChanges.single.path, h.outside);
    await h.review.undoAll();
    expect(File(h.outside).readAsStringSync(), 'before\n');
    final created = p.join(temp.path, 'remote-created', 'new.txt');
    await h.write(created, 'new\n');
    await h.review.undoAll();
    expect(File(created).existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test(
    'writes received during replay stay rejected after queued reads finish',
    () async {
      final h = _Harness(
        temp,
        resume: SessionRecord(
          id: _sessionId,
          title: 'resume',
          updatedAt: DateTime(2026),
          cwd: p.join(temp.path, 'project'),
        ),
      );
      File(h.outside).writeAsStringSync('before\n');
      h.transport.onLoad = () {
        h.request('fs/read_text_file', {'path': h.outside}, id: 'replay-read');
        h.request('fs/write_text_file', {
          'path': h.outside,
          'content': 'bad\n',
        }, id: 'replay-write');
      };
      await h.start();
      expect((await h.response('replay-read'))['error'], isNull);
      expect((await h.response('replay-write'))['error'], isNotNull);
      expect(File(h.outside).readAsStringSync(), 'before\n');
      await h.write(h.outside, 'live\n');
      expect(File(h.outside).readAsStringSync(), 'live\n');
    },
  );

  test(
    'parent turn completion preserves an in-flight edit checkpoint',
    () async {
      final h = _Harness(temp, gated: true);
      await h.start();
      final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode('before\r\n')];
      File(h.outside).writeAsBytesSync(bytes);
      h.transport.holdPrompt = true;
      h.session.send(const ComposerMessage(text: 'edit'));
      await until(() => h.events.whereType<TurnStarted>().isNotEmpty);
      final id = h.request('fs/write_text_file', {
        'path': h.outside,
        'content': 'after\n',
      });
      final gate = h.review as _GateReview;
      await gate.entered.future;
      h.transport.notify({'sessionUpdate': 'turn_complete'});
      await until(() => h.events.whereType<TurnEnded>().isNotEmpty);
      await pumpEventQueue(times: 100);
      gate.proceed.complete();
      expect((await h.response(id))['error'], isNull);
      await h.review.undoAll();
      expect(File(h.outside).readAsBytesSync(), bytes);
    },
  );

  test(
    'idle release waits for a pending filesystem write and its reply',
    () async {
      final h = _Harness(temp);
      await h.start();
      final gate = _GateWatch(h.review);
      h.kernel.editWatch = gate;
      final id = h.request('fs/write_text_file', {
        'path': h.outside,
        'content': 'after\n',
      });
      await gate.entered.future;
      h.kernel.release();
      gate.proceed.complete();
      expect((await h.response(id))['error'], isNull);
      expect(File(h.outside).readAsStringSync(), 'after\n');
      expect(h.review.changes.single.tracked, isTrue);
    },
  );
}
