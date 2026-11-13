@TestOn('vm')
library;

import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

/// Snapshot discovery must keep the list even without kernel edit events.
class _Kernel with KernelEventSource implements AgentKernel {
  _Kernel(this.descriptor);
  @override
  final KernelDescriptor descriptor;
  @override
  String get sessionId => 'persistence-session';
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
  for (final failure in ['save', 'forget']) {
    test(
      'a temporary $failure failure keeps the source session during migration',
      () async {
        final project = Directory.systemTemp.createTempSync(
          'review-migration-',
        );
        final file = File(p.join(project.path, 'file.txt'))
          ..writeAsStringSync('before\n');
        final harness = await RemoteHarness.start();
        final store = (await harness.client.openReview())!;
        final review = ChangeReview(store, root: project.path)
          ..session = 'source';
        try {
          await review.begin();
          file.writeAsStringSync('after\n');
          await review.observe();
          final peer = harness.server.peer;
          final original = peer.handlers[RemoteProtocol.reviewCall]!;
          var unavailable = true;
          peer.handlers[RemoteProtocol.reviewCall] = (params, call) {
            if (unavailable &&
                (params as Map)['method'] == failure &&
                (params['args'] as Map)['session'] ==
                    (failure == 'save' ? 'target' : 'source')) {
              throw const ReviewUnavailable(
                'Try saving again.',
                retryable: true,
              );
            }
            return original(params, call);
          };
          review.session = 'target';
          await review.look();
          expect(review.failure, isNull);
          expect(await store.load('source'), isNotNull);
          expect(
            await store.load('target'),
            failure == 'save' ? isNull : isNotNull,
          );
          unavailable = false;
          await review.observe();
          expect(await store.load('target'), isNotNull);
          expect(await store.load('source'), isNull);
          await review.undoAll();
          expect(file.readAsStringSync(), 'before\n');
        } finally {
          review.dispose();
          await harness.close();
          project.deleteSync(recursive: true);
        }
      },
    );
  }

  for (final method in ['save', 'forget']) {
    test(
      'remote $method interruption keeps review usable and retries persistence',
      () async {
        final project = Directory.systemTemp.createTempSync(
          'review-persistence-',
        );
        final file = File(p.join(project.path, 'file.txt'))
          ..writeAsStringSync('before\n');
        final harness = await RemoteHarness.start();
        final store = (await harness.client.openReview())!;
        final review = ChangeReview(store, root: project.path);
        late final KernelDescriptor descriptor;
        descriptor = KernelDescriptor(
          id: 'persistence',
          label: 'Persistence',
          description: '',
          icon: Icons.code,
          create: (_) => _Kernel(descriptor),
        );
        final session = ChatSession(
          kernel: descriptor,
          historyCount: 0,
          kernelContext: KernelContext(cwd: 'ssh://dev${project.path}'),
          openReview: (_, {session}) async => review,
        );
        try {
          session.attach();
          await until(() => session.changeReview != null);
          await review.begin();
          file.writeAsStringSync('first edit\n');
          await review.observe();
          expect(session.fileChanges.single.path, file.path);
          final peer = harness.server.peer;
          final original = peer.handlers[RemoteProtocol.reviewCall]!;
          var unavailable = true;
          var failures = 0;
          peer.handlers[RemoteProtocol.reviewCall] = (params, call) {
            if (unavailable && (params as Map)['method'] == method) {
              failures++;
              throw const ReviewUnavailable(
                'Checkpoint temporarily unavailable.',
                retryable: true,
              );
            }
            return original(params, call);
          };
          if (method == 'save') {
            file.writeAsStringSync('second edit\n');
            await review.observe();
          } else {
            await review.keepAll();
          }
          expect(failures, 1);
          expect(review.failure, isNull);
          expect(session.changeReview, same(review));
          if (method == 'save') {
            expect(session.fileChanges.single.tracked, isTrue);
            expect(
              await session.originalOf(session.fileChanges.single)!(),
              'before\n',
            );
          } else {
            expect(session.fileChanges, isEmpty);
          }
          unavailable = false;
          // No further edits: the unsaved record must still be retried.
          await review.observe();
          final resumed = await ChangeReview.resume(
            store,
            'persistence-session',
            root: project.path,
          );
          try {
            expect(resumed.failure, isNull);
            expect(resumed.changes.length, method == 'save' ? 1 : 0);
            if (method == 'save') {
              await resumed.undoAll();
              expect(file.readAsStringSync(), 'before\n');
            } else {
              file.writeAsStringSync('later edit\n');
              await review.observe();
              expect(session.fileChanges.single.tracked, isTrue);
              await review.undoAll();
              expect(file.readAsStringSync(), 'first edit\n');
            }
          } finally {
            resumed.dispose();
          }
        } finally {
          session.dispose();
          await harness.close();
          project.deleteSync(recursive: true);
        }
      },
    );
  }
}
