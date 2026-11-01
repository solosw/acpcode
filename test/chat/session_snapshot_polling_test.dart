import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoStore implements ReviewStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Review extends ChangeReview {
  _Review() : super(_NoStore(), root: '/project');
  int scans = 0;
  List<String> roots = [];
  List<FileChange> pending = [];
  List<FileChange> listed = [];
  Completer<void>? hold;

  @override
  List<FileChange> get changes => listed;

  @override
  Future<void> begin({Iterable<String>? roots}) async {
    this.roots = roots?.toList() ?? [];
  }

  @override
  Future<void> observe() async {
    scans++;
    await hold?.future;
    listed = [...pending];
    notifyListeners();
  }

  @override
  Future<void> look() async {}
}

/// Deliberately neither ACP nor WatchesEdits, and never emits FileEdited.
class _Kernel with KernelEventSource implements AgentKernel {
  _Kernel(this.descriptor);
  @override
  final KernelDescriptor descriptor;
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  String get sessionId => 'snapshot-session';
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
  testWidgets('workspace polling is independent of ACP/edit events, coalesces '
      'slow polls and always makes a final observation', (tester) async {
    late _Kernel kernel;
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'snapshot-test',
      label: 'Snapshot test',
      description: '',
      icon: Icons.code,
      create: (_) => kernel = _Kernel(descriptor),
    );
    final review = _Review();
    final session = ChatSession(
      kernel: descriptor,
      historyCount: 0,
      kernelContext: KernelContext(
        cwd: '/project',
        workspace: () => const KernelWorkspace(folders: ['/project', '/other']),
      ),
      openReview: (_, {session}) async => review,
    );
    addTearDown(session.dispose);
    session.attach();
    await tester.pump();
    expect(review.roots.toSet(), {'/project', '/other'});
    await tester.pump(const Duration(seconds: 6));
    expect(
      review.scans,
      0,
      reason: 'idle conversations do not attribute user edits',
    );

    kernel.emit(TurnStarted(kernel.nextSeq, 'turn'));
    await tester.pump();
    expect(session.isStreaming, isTrue);
    const change = FileChange(path: '/other/shell.txt', added: 1, removed: 0);
    review.pending = [change];
    await tester.pump(const Duration(seconds: 3));
    expect(session.fileChanges, [change]);
    expect(review.scans, 1);

    review.hold = Completer<void>();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 9));
    expect(
      review.scans,
      2,
      reason: 'a slow scan must not accumulate poll ticks',
    );
    kernel.emit(TurnEnded(kernel.nextSeq, 'turn'));
    await tester.pump();
    expect(
      review.scans,
      3,
      reason: 'turn-end discovery must not be coalesced away',
    );
    review.hold!.complete();
    await tester.pump();
    final finished = review.scans;
    await tester.pump(const Duration(seconds: 9));
    expect(review.scans, finished);
    expect(session.isStreaming, isFalse);
  });
}
