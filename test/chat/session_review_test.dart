import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/change_reviews.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoStore implements ReviewStore {
  _NoStore([this.root = '/p']);

  @override
  final String root;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A review that records what the session asks of it.
class _Review extends ChangeReview {
  _Review([String root = '/p']) : super(_NoStore(root));

  final calls = <String>[];
  final reported = <String>[];
  Completer<void>? holdRefresh;
  Completer<void>? holdBegin;
  Completer<void>? holdObserve;
  List<FileChange> listed = const [];

  @override
  List<FileChange> get changes => listed;

  void list(List<FileChange> changes) {
    listed = changes;
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    calls.add('refresh');
    await holdRefresh?.future;
  }

  @override
  Future<void> begin() async {
    calls.add('begin');
    await holdBegin?.future;
  }

  @override
  Future<void> observe() async {
    calls.add('observe');
    await holdObserve?.future;
  }

  @override
  void report(FileChange change, {FileOriginal? original}) =>
      reported.add(change.path);

  @override
  Future<void> keep(Iterable<String> paths) async =>
      calls.add('keep ${paths.join(',')}');

  @override
  Future<void> keepAll() async => calls.add('keepAll');

  @override
  Future<void> undo(Iterable<String> paths) async =>
      calls.add('undo ${paths.join(',')}');

  @override
  Future<void> undoAll() async => calls.add('undoAll');
}

class _ShellKernel extends AcpKernel {
  _ShellKernel(KernelDescriptor descriptor, KernelContext context)
    : super(descriptor, context, (_) => throw UnimplementedError());
  String? turnId;
  @override
  String get sessionId => 'shell-session';
  @override
  void prepare() {}
  @override
  void send(KernelTurn turn) {
    turnId = turn.id;
    emit(TurnStarted(nextSeq, turn.id));
    emit(ItemUpserted(nextSeq, turn.id, UserMessageItem(text: turn.text)));
  }

  void finish() => emit(TurnEnded(nextSeq, turnId!));
}

void main() {
  late _Review review;

  Future<ChatSession> pump(WidgetTester tester) async {
    review = _Review();
    final session = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: const KernelContext(cwd: '/p'),
      historyCount: 0,
      openReview: (root, {session}) async => review,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: ChatScreen(session: session),
      ),
    );
    await tester.pump();
    return session;
  }

  Future<void> finish(WidgetTester tester, ChatSession session) async {
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 400 && session.isStreaming; i++) {
      switch (session.pendingInteraction) {
        case QuestionRequest():
          session.answer(const QuestionAnswer([], skipped: true));
        case ApprovalRequest():
          session.answer(const ApprovalAnswer(ApprovalDecision.allowOnce));
        default:
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('the edits go to the review, its files looked at again around '
      'a turn, which does not wait for it', (tester) async {
    final session = await pump(tester);
    expect(review.calls, ['refresh']);

    review.holdRefresh = Completer();
    session.send(const ComposerMessage(text: '把输入框改成随内容增高'));
    // Shown at once.
    expect(review.calls, ['refresh', 'refresh']);
    expect(session.itemCount, greaterThan(0));

    review.holdRefresh!.complete();
    await finish(tester, session);

    expect(review.reported, isNotEmpty);
    // And again at the turn's end.
    expect(review.calls.last, 'refresh');
    // Its background tests settle.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the changes, and Keep and Undo, are the review\'s', (
    tester,
  ) async {
    final session = await pump(tester);
    session.send(const ComposerMessage(text: '把输入框改成随内容增高'));
    await finish(tester, session);

    const change = FileChange(path: '/p/lib/a.dart', added: 2, removed: 1);
    review.list(const [change]);
    await tester.pump();
    expect(session.fileChanges, [change]);
    expect(find.text('1 file changed'), findsOneWidget);

    session.keepChanges(const [change]);
    session.undoChanges!(const [change]);
    session.undoAllChanges!();
    await tester.tap(find.text('Keep all'));
    expect(
      review.calls,
      containsAllInOrder([
        'keep /p/lib/a.dart',
        'undo /p/lib/a.dart',
        'undoAll',
        'keepAll',
      ]),
    );

    // Failed, it gives way to what the kernel reported.
    review.abandon('gone');
    await tester.pump();
    expect(session.fileChanges, isNot([change]));
    expect(session.undoChanges, isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  test('in a workspace, each folder\'s files are its review\'s', () async {
    final reviews = <String, _Review>{};
    final opened = <String>[];
    final session = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: KernelContext(
        cwd: '/w',
        workspace: () =>
            const KernelWorkspace(folders: ['/a', '/b', '/a/inner']),
      ),
      historyCount: 0,
      openReview: (root, {session}) async {
        opened.add(root);
        return reviews[root] = _Review(root);
      },
    );
    addTearDown(session.dispose);
    session.attach();
    await pumpEventQueue();
    // A folder inside another is the other's.
    expect(opened, ['/w', '/a', '/b']);

    const inA = FileChange(path: '/a/lib/x.dart', added: 1, removed: 0);
    const inB = FileChange(path: '/b/y.dart', added: 1, removed: 0);
    reviews['/a']!.list(const [inA]);
    reviews['/b']!.list(const [inB]);
    expect(session.fileChanges, [inA, inB]);

    session.keepChanges(const [inA]);
    session.undoChanges!(const [inB]);
    await pumpEventQueue();
    expect(reviews['/a']!.calls, contains('keep /a/lib/x.dart'));
    expect(reviews['/b']!.calls, contains('undo /b/y.dart'));
    expect(reviews['/w']!.calls, isNot(contains(startsWith('keep'))));

    // A file in none of them is the agent's directory's.
    final parts = <String, _Review>{};
    final both = await ChangeReviews.open([
      '/w',
      '/a',
    ], open: (root, {session}) async => parts[root] = _Review(root));
    addTearDown(both!.dispose);
    both
      ..report(const FileChange(path: 'notes.md', added: 1, removed: 0))
      ..report(const FileChange(path: '/a/z.dart', added: 1, removed: 0))
      ..report(const FileChange(path: '/elsewhere.txt', added: 1, removed: 0));
    expect(parts['/w']!.reported, ['notes.md', '/elsewhere.txt']);
    expect(parts['/a']!.reported, ['/a/z.dart']);
  });

  testWidgets('a message still goes when opening the review never returns', (
    tester,
  ) async {
    // Upstream send does not wait on the opener: a hung folder must not
    // keep the composer from sending.
    final hang = Completer<ChangeReview?>();
    final session = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: const KernelContext(cwd: '/p'),
      historyCount: 0,
      openReview: (root, {session}) => hang.future,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: ChatScreen(session: session),
      ),
    );
    await tester.pump();

    session.send(const ComposerMessage(text: 'hello'));
    await tester.pump();
    expect(session.itemCount, greaterThan(0));
    await finish(tester, session);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a remote review opened during a turn starts periodic scans', (
    tester,
  ) async {
    final opening = Completer<ChangeReview?>();
    review = _Review('/srv/project');
    late _ShellKernel shell;
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'shell',
      label: 'Shell',
      icon: Icons.hub,
      description: '',
      create: (context) => shell = _ShellKernel(descriptor, context),
    );
    final session = ChatSession(
      kernel: descriptor,
      kernelContext: const KernelContext(cwd: 'ssh://dev/srv/project'),
      historyCount: 0,
      openReview: (root, {session}) => opening.future,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: ChatScreen(session: session),
      ),
    );
    await tester.pump();
    session.send(const ComposerMessage(text: '改一下'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.isStreaming, isTrue);

    opening.complete(review);
    await tester.pump();
    expect(review.calls, contains('begin'));
    final before = review.calls.where((call) => call == 'observe').length;
    await tester.pump(const Duration(seconds: 3));
    expect(
      review.calls.where((call) => call == 'observe').length,
      greaterThan(before),
    );
    shell.finish();
    await tester.pump();
    final after = review.calls.where((call) => call == 'observe').length;
    await tester.pump(const Duration(seconds: 4));
    expect(review.calls.where((call) => call == 'observe').length, after);
  });

  testWidgets('ACP scans every workspace folder, coalesces slow ticks, '
      'and sends without waiting for a baseline', (tester) async {
    late _ShellKernel shell;
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'shell',
      label: 'Shell',
      icon: Icons.hub,
      description: '',
      create: (context) => shell = _ShellKernel(descriptor, context),
    );
    final reviews = <String, _Review>{};
    final session = ChatSession(
      kernel: descriptor,
      kernelContext: KernelContext(
        cwd: '/a',
        workspace: () => const KernelWorkspace(folders: ['/a', '/b']),
      ),
      historyCount: 0,
      openReview: (root, {session}) async => reviews[root] = _Review(root),
    );
    addTearDown(session.dispose);
    session.attach();
    await tester.pump();
    for (final review in reviews.values) {
      review.holdBegin = Completer();
      review.holdObserve = Completer();
    }
    session.send(const ComposerMessage(text: 'shell edit'));
    await tester.pump();
    expect(session.isStreaming, isTrue);
    expect(session.itemCount, greaterThan(0));
    expect(reviews.keys, ['/a', '/b']);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 9));
    for (final review in reviews.values) {
      expect(review.calls.where((call) => call == 'observe'), hasLength(1));
    }
    shell.finish();
    await tester.pump();
    for (final review in reviews.values) {
      // End-of-turn discovery is never coalesced away by a slow tick.
      expect(review.calls.where((call) => call == 'observe'), hasLength(2));
      review.holdBegin!.complete();
      review.holdObserve!.complete();
    }
    await tester.pump(const Duration(seconds: 4));
    for (final review in reviews.values) {
      expect(review.calls.where((call) => call == 'observe'), hasLength(2));
    }
  });

  testWidgets('reported-file kernels do not scan the whole project', (
    tester,
  ) async {
    final session = await pump(tester);
    session.send(const ComposerMessage(text: '改一下'));
    await tester.pump(const Duration(milliseconds: 200));
    final before = review.calls.where((call) => call == 'observe').length;

    await tester.pump(const Duration(seconds: 3));
    expect(review.calls.where((call) => call == 'observe').length, before);
    expect(review.calls, isNot(contains('begin')));

    await finish(tester, session);
    final after = review.calls.where((call) => call == 'observe').length;
    await tester.pump(const Duration(seconds: 4));
    expect(review.calls.where((call) => call == 'observe').length, after);
  });
}
