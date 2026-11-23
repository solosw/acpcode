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
  void update(Map<String, Object?> update, {String session = _sessionId}) =>
      _messages.add({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'sessionId': session, 'update': update},
      });
  void Function()? onLoad;
  bool holdPrompt = false;

  void completePrompt() {
    final prompt = written.lastWhere(
      (message) => message['method'] == 'session/prompt',
    );
    _messages.add({
      'jsonrpc': '2.0',
      'id': prompt['id'],
      'result': {'stopReason': 'end_turn'},
    });
  }

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
  var transport = _Transport();
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
  Future<void> before(String path, {String? turn}) async {
    await super.before(path, turn: turn);
    entered.complete();
    await proceed.future;
  }
}

// Real remote review/file RPC, with an ACP process that writes its own files.
Future<_Harness> _remoteHarness(Directory temp, {SessionRecord? resume}) async {
  final data = Directory(p.join(temp.path, 'server'))..createSync();
  final connector = MemoryConnector(data.path);
  final previous = SshHosts.instance;
  SshHosts.instance = SshHosts(connect: connector.call);
  addTearDown(() async {
    await SshHosts.instance.closeAll();
    SshHosts.instance = previous;
  });
  final client = await SshHosts.instance['dev'].ready;
  return _Harness(
    temp,
    location: 'ssh://dev${p.join(temp.path, 'project')}',
    store: (await client.openReview())!,
    resume: resume,
  );
}

Map<String, Object?> _diff(String path, String? before, String after) => {
  'type': 'diff',
  'path': path,
  'oldText': before,
  'newText': after,
};

void _tool(
  _Harness h,
  String id, {
  String? status,
  List<Object?>? content,
  String session = _sessionId,
}) => h.transport.update({
  'sessionUpdate': 'tool_call_update',
  'toolCallId': id,
  'status': ?status,
  'content': ?content,
}, session: session);

Future<void> _diffsDone(_Harness h) async {
  await until(() => !h.kernel.hasPendingEdits);
  await h.review.observe();
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
    'SSH tool diffs are listed only after completion without guessed Undo',
    () async {
      final h = await _remoteHarness(temp);
      await h.start();
      File(h.outside).writeAsStringSync('before\n');
      _tool(
        h,
        'edit',
        status: 'pending',
        content: [_diff(h.outside, 'before\n', 'after\n')],
      );
      await _diffsDone(h);
      expect(h.session.fileChanges, isEmpty);
      File(h.outside).writeAsStringSync('after\n');
      _tool(h, 'edit', status: 'completed');
      await _diffsDone(h);
      expect(h.session.fileChanges.single.path, h.outside);
      expect(h.session.fileChanges.single.tracked, isFalse);
      final edit = h.events.whereType<FileEdited>().single;
      expect(edit.original, isNull);
      expect(edit.after!.known, isFalse);
      await h.review.undoAll();
      expect(File(h.outside).readAsStringSync(), 'after\n');
    },
    skip: Platform.isWindows,
  );

  test(
    'SSH outside deletion hint remains listed after the turn ends',
    () async {
      final h = await _remoteHarness(temp);
      await h.start();
      File(h.outside).writeAsStringSync('deleted original');
      h.transport.holdPrompt = true;
      h.session.send(const ComposerMessage(text: 'delete outside file'));
      await until(
        () => h.transport.written.any((m) => m['method'] == 'session/prompt'),
      );
      File(h.outside).deleteSync();
      _tool(
        h,
        'delete',
        status: 'completed',
        content: [_diff(h.outside, 'deleted original', '')],
      );
      await _diffsDone(h);
      h.transport.completePrompt();
      await until(() => h.events.whereType<TurnEnded>().isNotEmpty);
      await h.review.look();
      expect(h.session.fileChanges.single.path, h.outside);
      expect(h.session.fileChanges.single.tracked, isFalse);
      await h.review.undoAll();
      expect(File(h.outside).existsSync(), isFalse);
      expect(h.session.fileChanges.single.path, h.outside);
      await h.review.keepAll();
      expect(h.session.fileChanges, isEmpty);
    },
    skip: Platform.isWindows,
  );

  test('SSH completed diff fragments and missing targets are hints, never file originals', () async {
    final h = await _remoteHarness(temp);
    await h.start();
    File(h.outside).writeAsStringSync('header\nnew fragment\nfooter\n');
    final missing = p.join(temp.path, 'unreadable', 'file.txt');
    _tool(
      h,
      'fragment',
      status: 'completed',
      content: [
        _diff(h.outside, 'old fragment', 'new fragment'),
        _diff(missing, null, 'proposed creation'),
      ],
    );
    await _diffsDone(h);
    expect(
      h.session.fileChanges.map((change) => change.path),
      unorderedEquals([h.outside, missing]),
    );
    expect(h.session.fileChanges.every((change) => !change.tracked), isTrue);
    expect(
      h.events.whereType<FileEdited>().every((edit) => edit.original == null),
      isTrue,
    );
    await h.review.undoAll();
    expect(
      File(h.outside).readAsStringSync(),
      'header\nnew fragment\nfooter\n',
    );
    expect(File(missing).existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('SSH diff completion patches deduplicate canonical paths and ignore failed proposals', () async {
    final h = await _remoteHarness(temp);
    await h.start();
    File(h.outside).writeAsStringSync('after\n');
    final alias = p.join(temp.path, 'alias.txt');
    Link(alias).createSync(h.outside);
    final block = _diff(h.outside, 'before\n', 'after\n');
    _tool(h, 'edit', status: 'completed');
    _tool(h, 'edit', content: [block]);
    _tool(h, 'edit', status: 'completed', content: [block]);
    _tool(h, 'edit', content: [_diff(alias, 'before\n', 'after\n')]);
    _tool(
      h,
      'failed',
      status: 'pending',
      content: [_diff(p.join(temp.path, 'failed.txt'), 'before', 'after')],
    );
    _tool(h, 'failed', status: 'failed');
    _tool(h, 'failed', status: 'completed');
    h.transport.update({
      'sessionUpdate': 'tool_call_update',
      'status': 'completed',
      'content': [_diff('/no-tool-id', null, 'text')],
    });
    _tool(
      h,
      'invalid',
      status: 'completed',
      content: [_diff('relative.txt', null, 'text')],
    );
    await _diffsDone(h);
    expect(h.events.whereType<FileEdited>(), hasLength(1));
    expect(h.session.fileChanges.single.path, h.outside);
  }, skip: Platform.isWindows);

  test(
    'SSH fs checkpoint survives full and fragment diff UI updates',
    () async {
      final h = await _remoteHarness(temp);
      await h.start();
      final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode('before\r\n')];
      File(h.outside).writeAsBytesSync(bytes);
      await h.write(h.outside, 'after\n');
      _tool(
        h,
        'fs-edit',
        status: 'completed',
        content: [
          _diff(
            h.outside,
            'before',
            utf8.decode(h.events.whereType<FileEdited>().single.after!.bytes!),
          ),
        ],
      );
      await _diffsDone(h);
      expect(h.events.whereType<FileEdited>(), hasLength(1));
      _tool(
        h,
        'fs-fragment',
        status: 'completed',
        content: [_diff(h.outside, 'before', 'after')],
      );
      await _diffsDone(h);
      expect(h.events.whereType<FileEdited>(), hasLength(2));
      expect(h.session.fileChanges.single.tracked, isTrue);
      await h.review.undoAll();
      expect(File(h.outside).readAsBytesSync(), bytes);
    },
    skip: Platform.isWindows,
  );

  test('SSH declared child diff tool IDs are isolated and unknown sessions ignored', () async {
    final h = await _remoteHarness(temp);
    await h.start();
    File(h.outside).writeAsStringSync('after\n');
    final block = _diff(h.outside, 'before\n', 'after\n');
    for (final child in ['first', 'second']) {
      h.transport.update({
        'sessionUpdate': 'subagent_update',
        'sessionId': child,
      });
      _tool(h, 'edit', status: 'pending', content: [block], session: child);
      _tool(h, 'edit', status: 'completed', session: child);
    }
    _tool(h, 'edit', status: 'completed', content: [block], session: 'unknown');
    await _diffsDone(h);
    expect(h.events.whereType<FileEdited>(), hasLength(2));
    expect(h.session.fileChanges.single.path, h.outside);
  }, skip: Platform.isWindows);

  test(
    'SSH initial replay never caches a diff for a later live completion',
    () async {
      final h = await _remoteHarness(
        temp,
        resume: SessionRecord(
          id: _sessionId,
          title: 'resume',
          updatedAt: DateTime(2026),
          cwd: p.join(temp.path, 'project'),
        ),
      );
      File(h.outside).writeAsStringSync('after\n');
      h.transport.onLoad = () {
        _tool(
          h,
          'history-pending',
          status: 'pending',
          content: [_diff(h.outside, 'before\n', 'after\n')],
        );
        _tool(
          h,
          'history-complete',
          status: 'completed',
          content: [_diff(h.outside, 'before\n', 'after\n')],
        );
      };
      await h.start();
      _tool(h, 'history-pending', status: 'completed');
      await _diffsDone(h);
      expect(h.events.whereType<FileEdited>(), isEmpty);
      expect(h.session.fileChanges, isEmpty);
    },
    skip: Platform.isWindows,
  );

  test('SSH idle release clears proposals and retained load cannot reintroduce diffs', () async {
    final h = await _remoteHarness(
      temp,
      resume: SessionRecord(
        id: _sessionId,
        title: 'resume',
        updatedAt: DateTime(2026),
        cwd: p.join(temp.path, 'project'),
      ),
    );
    await h.start();
    File(h.outside).writeAsStringSync('after\n');
    final block = _diff(h.outside, 'before\n', 'after\n');
    _tool(h, 'stale', status: 'pending', content: [block]);
    h.kernel.release();
    await until(() => h.kernel.health.status == KernelHealthStatus.idle);
    await h.kernel.stopped;
    h.transport = _Transport()
      ..onLoad = () {
        _tool(h, 'retained', status: 'pending', content: [block]);
        _tool(h, 'retained-completed', status: 'completed', content: [block]);
      };
    h.kernel.prepare();
    await until(() => h.kernel.health.status == KernelHealthStatus.ready);
    _tool(h, 'stale', status: 'completed');
    _tool(h, 'retained', status: 'completed');
    await _diffsDone(h);
    expect(h.events.whereType<FileEdited>(), isEmpty);
    expect(h.session.fileChanges, isEmpty);
    _tool(h, 'live', status: 'completed', content: [block]);
    await _diffsDone(h);
    expect(h.events.whereType<FileEdited>(), hasLength(1));
    await h.review.keepAll();
    expect(h.session.fileChanges, isEmpty);
    h.kernel.release();
    await until(() => h.kernel.health.status == KernelHealthStatus.idle);
    await h.kernel.stopped;
    h.transport = _Transport();
    h.kernel.prepare();
    await until(() => h.kernel.health.status == KernelHealthStatus.ready);
    _tool(h, 'live', status: 'completed', content: [block]);
    await _diffsDone(h);
    expect(h.events.whereType<FileEdited>(), hasLength(1));
    expect(h.session.fileChanges, isEmpty);
  }, skip: Platform.isWindows);

  test(
    'SSH late child and completed-only tool diffs retain their original turn',
    () async {
      final h = await _remoteHarness(temp);
      await h.start();
      h.transport.holdPrompt = true;
      h.session.send(const ComposerMessage(text: 'first'));
      await until(() => h.events.whereType<TurnStarted>().length == 1);
      final first = h.events.whereType<TurnStarted>().single.turnId;
      h.transport.update({
        'sessionUpdate': 'subagent_update',
        'sessionId': 'child',
      });
      _tool(
        h,
        'edit',
        status: 'pending',
        content: [_diff(h.outside, 'before', 'after')],
        session: 'child',
      );
      _tool(h, 'parent-edit', status: 'in_progress');
      h.transport.completePrompt();
      await until(() => h.events.whereType<TurnEnded>().length == 1);
      h.session.send(const ComposerMessage(text: 'second'));
      await until(() => h.events.whereType<TurnStarted>().length == 2);
      File(h.outside).writeAsStringSync('after');
      final other = p.join(temp.path, 'other.txt');
      File(other).writeAsStringSync('other after');
      _tool(h, 'edit', status: 'completed', session: 'child');
      _tool(
        h,
        'parent-edit',
        status: 'completed',
        content: [_diff(other, 'other before', 'other after')],
      );
      await _diffsDone(h);
      final edits = h.events.whereType<FileEdited>().toList();
      expect(edits, hasLength(2));
      expect(edits.map((edit) => edit.turnId), [first, first]);
    },
    skip: Platform.isWindows,
  );

  test('SSH asynchronous path resolution cannot move a completed diff to the next turn', () async {
    final h = await _remoteHarness(temp);
    await h.start();
    h.transport.holdPrompt = true;
    h.session.send(const ComposerMessage(text: 'first'));
    await until(() => h.events.whereType<TurnStarted>().length == 1);
    final first = h.events.whereType<TurnStarted>().single.turnId;
    final gate = _GateWatch(h.review);
    h.kernel.editWatch = gate;
    final heldWrite = h.request('fs/write_text_file', {
      'path': p.join(temp.path, 'held.txt'),
      'content': 'held write',
    });
    await gate.entered.future;
    File(h.outside).writeAsStringSync('after');
    _tool(
      h,
      'queued-path',
      status: 'completed',
      content: [_diff(h.outside, 'before', 'after')],
    );
    h.transport.completePrompt();
    await until(() => h.events.whereType<TurnEnded>().length == 1);
    h.session.send(const ComposerMessage(text: 'second'));
    await until(() => h.events.whereType<TurnStarted>().length == 2);
    gate.proceed.complete();
    expect((await h.response(heldWrite))['error'], isNull);
    await _diffsDone(h);
    final diff = h.events.whereType<FileEdited>().singleWhere(
      (edit) => edit.change.path == h.outside,
    );
    expect(diff.turnId, first);
  }, skip: Platform.isWindows);

  test(
    'SSH tool completion after the parent turn ends keeps its non-null owner',
    () async {
      final h = await _remoteHarness(temp);
      await h.start();
      h.transport.holdPrompt = true;
      h.session.send(const ComposerMessage(text: 'parent'));
      await until(() => h.events.whereType<TurnStarted>().length == 1);
      final first = h.events.whereType<TurnStarted>().single.turnId;
      _tool(h, 'late', status: 'pending');
      h.transport.completePrompt();
      await until(() => h.events.whereType<TurnEnded>().length == 1);
      File(h.outside).writeAsStringSync('after');
      _tool(
        h,
        'late',
        status: 'completed',
        content: [_diff(h.outside, 'before', 'after')],
      );
      await _diffsDone(h);
      expect(h.events.whereType<FileEdited>().single.turnId, first);
    },
    skip: Platform.isWindows,
  );

  test('SSH only a new tool_call in a new turn allows an explicitly reused tool ID', () async {
    final h = await _remoteHarness(temp);
    await h.start();
    h.transport.holdPrompt = true;
    h.session.send(const ComposerMessage(text: 'first'));
    await until(() => h.events.whereType<TurnStarted>().length == 1);
    File(h.outside).writeAsStringSync('after');
    final block = _diff(h.outside, 'before', 'after');
    _tool(h, 'reused', status: 'completed', content: [block]);
    await _diffsDone(h);
    await h.review.keepAll();
    h.transport.completePrompt();
    await until(() => h.events.whereType<TurnEnded>().length == 1);
    h.session.send(const ComposerMessage(text: 'second'));
    await until(() => h.events.whereType<TurnStarted>().length == 2);
    final second = h.events.whereType<TurnStarted>().last.turnId;
    _tool(h, 'reused', status: 'pending', content: [block]);
    _tool(h, 'reused', status: 'completed');
    await _diffsDone(h);
    expect(h.events.whereType<FileEdited>(), hasLength(1));
    expect(h.session.fileChanges, isEmpty);
    h.transport.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'reused',
      'status': 'pending',
      'content': [block],
    });
    _tool(h, 'reused', status: 'completed');
    await _diffsDone(h);
    expect(h.events.whereType<FileEdited>(), hasLength(2));
    expect(h.events.whereType<FileEdited>().last.turnId, second);
    expect(h.session.fileChanges.single.path, h.outside);
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
      h.transport.completePrompt();
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
