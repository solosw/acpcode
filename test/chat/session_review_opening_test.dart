@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show BlobReviewStore;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

class _FastKernel with KernelEventSource implements AgentKernel {
  _FastKernel(this.descriptor, this.path, {this.script, this.snapshot = false});
  final void Function(_FastKernel)? script;
  final bool snapshot;
  String? activeTurn;

  @override
  void cancel() {
    if (activeTurn case final turn?) {
      emit(TurnEnded(nextSeq, turn, interrupted: true));
      activeTurn = null;
    }
  }

  @override
  final KernelDescriptor descriptor;
  final String path;
  @override
  String get sessionId => 'fast-session';
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  void prepare() {}
  @override
  void release() {}
  @override
  void dispose() => closeEvents();
  @override
  Future<void> get stopped async {}
  @override
  void send(KernelTurn turn) {
    activeTurn = turn.id;
    emit(TurnStarted(nextSeq, turn.id));
    emit(ItemUpserted(nextSeq, turn.id, UserMessageItem(text: turn.text)));
    if (script case final run?) {
      run(this);
      return;
    }
    final file = File(path);
    final original = file.existsSync() ? file.readAsStringSync() : null;
    file.writeAsStringSync('agent edit\n');
    emit(
      FileEdited(
        nextSeq,
        FileChange(path: path, added: 1, removed: original == null ? 0 : 1),
        original: OriginalText(original),
        after: snapshot ? FileSnapshot.text('agent edit\n') : null,
      ),
    );
    emit(TurnEnded(nextSeq, turn.id));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _delayedReview({
  bool remote = false,
  bool reviewReady = false,
  void Function(_FastKernel kernel, File file)? script,
  void Function(ChatSession session)? beforeOpen,
  required void Function(_FastKernel kernel, File file) edit,
  required Future<void> Function(ChatSession session, File file) verify,
}) async {
  final temp = Directory.systemTemp.createTempSync('opening-snapshot-');
  final root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
  final file = File(p.join(root, 'file.txt'))
    ..writeAsStringSync('A\n2\n3\n4\n5\n');
  RemoteHarness? harness;
  final ReviewStore store;
  if (remote) {
    harness = await RemoteHarness.start();
    store = (await harness.client.openReview())!;
  } else {
    store = BlobReviewStore.open(p.join(temp.path, 'checkpoints'));
  }
  final gate = Completer<ChangeReview?>();
  final review = ChangeReview(store, root: root);
  late _FastKernel kernel;
  late final KernelDescriptor descriptor;
  descriptor = KernelDescriptor(
    id: 'fast',
    label: 'Fast',
    icon: Icons.bolt,
    description: '',
    create: (_) => kernel = _FastKernel(
      descriptor,
      file.path,
      snapshot: remote,
      script: script == null ? null : (kernel) => script(kernel, file),
    ),
  );
  final session = ChatSession(
    kernel: descriptor,
    historyCount: 0,
    kernelContext: KernelContext(cwd: remote ? 'ssh://dev$root' : root),
    openReview: (_, {session}) => gate.future,
  );
  try {
    session.attach();
    if (reviewReady) {
      gate.complete(review);
      await pumpEventQueue(times: 100);
    }
    session.send(const ComposerMessage(text: 'edit'));
    // The opener intentionally cannot finish until AFTER send returns.
    edit(kernel, file);
    beforeOpen?.call(session);
    if (!reviewReady) gate.complete(review);
    await pumpEventQueue(times: 100);
    await review.look();
    await verify(session, file);
  } finally {
    session.dispose();
    await harness?.close();
    temp.deleteSync(recursive: true);
  }
}

void _toolResult(
  ClaudeTranslator translator,
  String id,
  String name,
  Map<String, Object?> input,
  Map<String, Object?> result,
) {
  translator
    ..translate({
      'type': 'assistant',
      'message': {
        'id': 'msg-$id',
        'role': 'assistant',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
        ],
      },
    })
    ..translate({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok'},
        ],
      },
      'tool_use_result': result,
    });
}

void main() {
  for (final name in ['Edit', 'Write']) {
    test(
      'SSH Claude $name supplies a write-time snapshot for delayed review',
      () async {
        await _delayedReview(
          remote: true,
          script: (kernel, file) {
            const before = 'A\n2\n3\n4\n5\n';
            const after = 'C\n2\n3\n4\n5\n';
            file.writeAsStringSync(after);
            if (!Platform.isWindows) {
              expect(Process.runSync('chmod', ['+x', file.path]).exitCode, 0);
            }
            final translator = ClaudeTranslator(
              emit: kernel.emit,
              nextSeq: () => kernel.nextSeq,
            )..turnId = kernel.activeTurn;
            _toolResult(
              translator,
              'edit',
              name,
              {'file_path': file.path, 'old_string': 'A', 'new_string': 'C'},
              {
                'type': 'update',
                'filePath': file.path,
                'originalFile': before,
                'oldString': 'A',
                'newString': 'C',
                'content': after,
                'structuredPatch': [
                  {
                    'oldStart': 1,
                    'oldLines': 1,
                    'newStart': 1,
                    'newLines': 1,
                    'lines': ['-A', '+C'],
                  },
                ],
              },
            );
            kernel.emit(TurnEnded(kernel.nextSeq, kernel.activeTurn!));
          },
          edit: (_, file) => file.writeAsStringSync('C\n2\n3\n4\nuser\n'),
          verify: (session, file) async {
            expect(session.fileChanges.single.tracked, isTrue);
            await session.changeReview!.undoAll();
            expect(file.readAsStringSync(), 'A\n2\n3\n4\nuser\n');
            if (!Platform.isWindows) {
              expect(file.statSync().mode & 0x49, isNonZero);
            }
            expect(session.fileChanges, isEmpty);
          },
        );
      },
    );
  }

  test('Claude Edit snapshots replace_all and rejects ambiguous/user-modified results', () {
    final edits = <FileEdited>[];
    var seq = 0;
    final translator = ClaudeTranslator(
      emit: (event) {
        if (event is FileEdited) edits.add(event);
      },
      nextSeq: () => ++seq,
    );
    for (final (id, all, modified) in [
      ('all', true, false),
      ('ambiguous', false, false),
      ('modified', true, true),
    ]) {
      _toolResult(
        translator,
        id,
        'Edit',
        {'file_path': '/remote/a.txt', 'replace_all': all},
        {
          'filePath': '/remote/a.txt',
          'originalFile': 'a\na\n',
          'oldString': 'a',
          'newString': 'b',
          'userModified': modified,
          'structuredPatch': [
            {
              'oldStart': 1,
              'oldLines': 2,
              'newStart': 1,
              'newLines': 2,
              'lines': ['-a', '-a', '+b', '+b'],
            },
          ],
        },
      );
    }
    expect(utf8.decode(edits[0].after!.bytes!), 'b\nb\n');
    expect(edits[1].after, isNull);
    expect(edits[2].after!.known, isFalse);
  });

  test('early OriginalText does not absorb a later user edit', () async {
    await _delayedReview(
      edit: (_, file) {
        file.writeAsStringSync('user edit\n');
      },
      verify: (session, file) async {
        await session.changeReview!.undoAll();
        expect(file.readAsStringSync(), 'user edit\n');
        expect(session.fileChanges.single.conflict, isTrue);
      },
    );
  });

  for (final remote in [false, true]) {
    for (final ready in [false, true]) {
      for (final patches in [false, true]) {
        for (final user in ['none', 'separate', 'conflict']) {
          test('${remote ? 'SSH' : 'local'} '
              '${ready ? 'ready' : 'opening'} review '
              '${patches ? 'A -> B -> C patches' : 'OriginalText'} '
              'with $user user edits', () async {
            const baseline = 'A\n2\n3\n4\n5\n';
            const agent = 'C\n2\n3\n4\n5\n';
            final current = switch (user) {
              'separate' => 'C\n2\n3\n4\nuser\n',
              'conflict' => 'user\n2\n3\n4\n5\n',
              _ => agent,
            };
            await _delayedReview(
              remote: remote,
              reviewReady: ready,
              script: (kernel, file) {
                for (final (before, after)
                    in patches ? [('A', 'B'), ('B', 'C')] : [('A', 'C')]) {
                  final text = '$after\n2\n3\n4\n5\n';
                  file.writeAsStringSync(text);
                  kernel.emit(
                    FileEdited(
                      kernel.nextSeq,
                      FileChange(path: file.path, added: 1, removed: 1),
                      original: patches
                          ? OriginalByPatch('@@ -1 +1 @@\n-$before\n+$after\n')
                          : const OriginalText(baseline),
                      // A remote producer supplies the exact write result;
                      // local producers exercise synchronous event capture.
                      after: remote ? FileSnapshot.text(text) : null,
                    ),
                  );
                }
                kernel.emit(TurnEnded(kernel.nextSeq, kernel.activeTurn!));
              },
              // Happens synchronously after the last event, before either
              // the opener or the ready review's queued _take can run.
              edit: (_, file) => file.writeAsStringSync(current),
              verify: (session, file) async {
                final change = session.fileChanges.single;
                expect(change.tracked, isTrue);
                expect(await session.originalOf(change)!(), baseline);
                await session.changeReview!.undoAll();
                expect(file.readAsStringSync(), switch (user) {
                  'separate' => 'A\n2\n3\n4\nuser\n',
                  'conflict' => current,
                  _ => baseline,
                });
                if (user == 'conflict') {
                  expect(session.fileChanges.single.conflict, isTrue);
                } else {
                  expect(session.fileChanges, isEmpty);
                }
              },
            );
          });
        }
      }
    }
  }

  for (final remote in [false, true]) {
    test(
      '${remote ? 'SSH' : 'local'} user edits after review opens survive Undo',
      () async {
        await _delayedReview(
          remote: remote,
          edit: (_, _) {},
          verify: (session, file) async {
            file.writeAsStringSync('user edit\n');
            await session.changeReview!.undoAll();
            expect(file.readAsStringSync(), 'user edit\n');
            expect(session.fileChanges.single.conflict, isTrue);
          },
        );
      },
    );

    test(
      '${remote ? 'SSH' : 'local'} a broken edit chain fails closed',
      () async {
        await _delayedReview(
          remote: remote,
          script: (kernel, file) {
            file.writeAsStringSync('B\n2\n3\n4\n5\n');
            kernel.emit(
              FileEdited(
                kernel.nextSeq,
                FileChange(path: file.path, added: 1, removed: 1),
                original: const OriginalText('A\n2\n3\n4\n5\n'),
                after: remote
                    ? FileSnapshot.text(file.readAsStringSync())
                    : null,
              ),
            );
            // User change between writes, then the agent builds on it.
            file.writeAsStringSync('C\n2\n3\n4\nuser\n');
            kernel.emit(
              FileEdited(
                kernel.nextSeq,
                FileChange(path: file.path, added: 1, removed: 1),
                original: const OriginalText('B\n2\n3\n4\nuser\n'),
                after: remote
                    ? FileSnapshot.text(file.readAsStringSync())
                    : null,
              ),
            );
            kernel.emit(TurnEnded(kernel.nextSeq, kernel.activeTurn!));
          },
          edit: (_, _) {},
          verify: (session, file) async {
            await session.changeReview!.undoAll();
            expect(file.readAsStringSync(), 'C\n2\n3\n4\nuser\n');
            expect(session.fileChanges.single.conflict, isTrue);
          },
        );
      },
    );
  }

  for (final remote in [false, true]) {
    for (final creation in [false, true]) {
      for (final user in [false, true]) {
        test(
          '${remote ? 'SSH' : 'local'} early ${creation ? 'creation' : 'deletion'} '
          '${user ? 'preserves user contents' : 'can be undone'}',
          () async {
            await _delayedReview(
              remote: remote,
              script: (kernel, file) {
                if (creation) {
                  file.writeAsStringSync('created\n');
                } else {
                  file.deleteSync();
                }
                kernel.emit(
                  FileEdited(
                    kernel.nextSeq,
                    FileChange(
                      path: file.path,
                      added: creation ? 1 : 0,
                      removed: creation ? 0 : 5,
                    ),
                    original: OriginalText(creation ? null : 'A\n2\n3\n4\n5\n'),
                    after: remote
                        ? FileSnapshot.text(creation ? 'created\n' : null)
                        : null,
                  ),
                );
                kernel.emit(TurnEnded(kernel.nextSeq, kernel.activeTurn!));
              },
              edit: (_, file) {
                if (user) file.writeAsStringSync('user contents\n');
              },
              verify: (session, file) async {
                expect(session.fileChanges.single.tracked, isTrue);
                await session.changeReview!.undoAll();
                if (user) {
                  expect(file.readAsStringSync(), 'user contents\n');
                  expect(session.fileChanges.single.conflict, isTrue);
                } else {
                  expect(file.existsSync(), !creation);
                  if (!creation) {
                    expect(file.readAsStringSync(), 'A\n2\n3\n4\n5\n');
                  }
                  expect(session.fileChanges, isEmpty);
                }
              },
            );
          },
        );
      }
    }
    test(
      '${remote ? 'SSH' : 'local'} per-file Keep before opening skips replay',
      () async {
        await _delayedReview(
          remote: remote,
          edit: (_, _) {},
          beforeOpen: (session) {
            session.keepChanges(session.fileChanges);
          },
          verify: (session, file) async {
            expect(session.fileChanges, isEmpty);
            expect(file.readAsStringSync(), 'agent edit\n');
          },
        );
      },
    );
    test(
      '${remote ? 'SSH' : 'local'} reverted events are not replayed on opening',
      () async {
        await _delayedReview(
          remote: remote,
          edit: (kernel, file) {
            file.writeAsStringSync('A\n2\n3\n4\n5\n');
            kernel.emit(ChangesReverted(kernel.nextSeq));
          },
          verify: (session, file) async {
            expect(session.fileChanges, isEmpty);
            expect(file.readAsStringSync(), 'A\n2\n3\n4\n5\n');
          },
        );
      },
    );
  }

  test('SSH without a snapshot never borrows a local same-path file', () async {
    await _delayedReview(
      remote: true,
      script: (kernel, file) {
        file.writeAsStringSync('agent edit\n');
        kernel.emit(
          FileEdited(
            kernel.nextSeq,
            FileChange(path: file.path, added: 1, removed: 1),
            original: const OriginalText('A\n2\n3\n4\n5\n'),
          ),
        );
        kernel.emit(TurnEnded(kernel.nextSeq, kernel.activeTurn!));
      },
      edit: (_, file) => file.writeAsStringSync('user edit\n'),
      verify: (session, file) async {
        expect(session.fileChanges.single.tracked, isFalse);
        expect(session.undoAllChanges, isNull);
        await session.changeReview!.undoAll();
        expect(file.readAsStringSync(), 'user edit\n');
      },
    );
  });

  test(
    'opening review does not delay streaming, lock or cancellation',
    () async {
      await _delayedReview(
        script: (_, _) {},
        edit: (_, _) {},
        beforeOpen: (session) {
          expect(session.isStreaming, isTrue);
          expect(session.kernelLocked, isTrue);
          session.stop();
          expect(session.isStreaming, isFalse);
        },
        verify: (session, _) async {
          expect(session.isStreaming, isFalse);
          expect(session.fileChanges, isEmpty);
        },
      );
    },
  );
  for (final remote in [false, true]) {
    for (final keep in [false, true]) {
      test('${remote ? 'SSH' : 'local'} edits before review opens '
          '${keep ? 'stay kept' : 'remain tracked and undoable'}', () async {
        final temp = Directory.systemTemp.createTempSync('opening-review-');
        final root = (Directory(
          p.join(temp.path, 'project'),
        )..createSync()).path;
        final path = p.join(root, 'file.txt');
        final file = File(path)..writeAsStringSync('before\n');
        RemoteHarness? harness;
        final ReviewStore store;
        if (remote) {
          harness = await RemoteHarness.start();
          store = (await harness.client.openReview())!;
        } else {
          store = BlobReviewStore.open(p.join(temp.path, 'checkpoints'));
        }
        final gate = Completer<ChangeReview?>();
        final review = ChangeReview(store, root: root);
        late final KernelDescriptor descriptor;
        descriptor = KernelDescriptor(
          id: 'fast',
          label: 'Fast',
          icon: Icons.bolt,
          description: '',
          create: (_) => _FastKernel(descriptor, path, snapshot: remote),
        );
        final session = ChatSession(
          kernel: descriptor,
          historyCount: 0,
          kernelContext: KernelContext(cwd: remote ? 'ssh://dev$root' : root),
          openReview: (_, {session}) => gate.future,
        );
        try {
          session.attach();
          session.send(const ComposerMessage(text: 'edit'));
          await pumpEventQueue(times: 30);
          expect(file.readAsStringSync(), 'agent edit\n');
          expect(session.fileChanges, hasLength(1));
          if (keep) session.keepAllChanges();
          gate.complete(review);
          await pumpEventQueue(times: 100);
          await review.look();
          if (keep) {
            expect(session.fileChanges, isEmpty);
            expect(file.readAsStringSync(), 'agent edit\n');
          } else {
            expect(session.fileChanges, hasLength(1));
            final change = session.fileChanges.single;
            expect(change.tracked, isTrue);
            expect(await session.originalOf(change)!(), 'before\n');
            await session.changeReview!.undoAll();
            expect(file.readAsStringSync(), 'before\n');
            expect(session.fileChanges, isEmpty);
          }
        } finally {
          session.dispose();
          await harness?.close();
          temp.deleteSync(recursive: true);
        }
      });
    }
  }
}
