import 'package:baocode/chat/resume_after_reset.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

/// Three kept sessions, each in a project of its own.
class _Catalog implements SessionCatalog {
  static final kept = [
    for (final (id, project) in [
      ('a', '/tmp/alpha'),
      ('b', '/tmp/beta'),
      ('c', '/tmp/gamma'),
    ])
      SessionRecord(
        id: id,
        title: 'Task $id',
        updatedAt: DateTime(2026, 10, 13, 14),
        cwd: project,
        path: '$project/$id.jsonl',
      ),
  ];

  @override
  Future<List<ProjectRecord>> projects() async => [
    for (final session in kept)
      ProjectRecord(path: session.cwd, sessions: [session]),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}

const _continue = 'The usage limit has reset. Continue where you left off.';

void main() {
  late ResumeAfterReset resumes;
  late MemoryPreferenceStore store;
  late Map<String, FakeCli> clis;
  late Workspace workspace;
  late DateTime now;
  // The setting, as settings.json has it.
  late bool on;

  /// The workspace (and the scheduler, kept in [store]) as the app starts.
  Future<void> start(WidgetTester tester) async {
    resumes = ResumeAfterReset(
      store: store,
      enabled: () => on,
      clock: () => now,
    );
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      catalog: _Catalog(),
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (launch) async => clis[launch.resume!] = FakeCli(),
        readHistory: (_) async => const [],
        providers: ModelProviders.memory(),
      ),
    );
    workspace = Workspace(kernels: [descriptor], resumes: resumes);
    addTearDown(() {
      workspace.dispose();
      resumes.dispose();
    });
    await tester.runAsync(workspace.load);
    // Read after (in the test's time): what it times is on its clock.
    await resumes.load();
  }

  setUp(() {
    now = DateTime.now();
    on = true;
    store = MemoryPreferenceStore();
    clis = {};
  });

  AgentThread thread(String id) =>
      workspace.threads.firstWhere((thread) => thread.id == id);

  /// The clock and the timers moved on by [duration].
  Future<void> elapse(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// [id]'s agent, shown, stopped at the limit resetting at [resets].
  Future<void> hit(WidgetTester tester, String id, DateTime resets) async {
    final session = thread(id).session..attach();
    addTearDown(session.detach);
    await tester.pump(const Duration(milliseconds: 100));
    clis[id]!.push({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'rejected',
        'resetsAt': resets.millisecondsSinceEpoch ~/ 1000,
      },
    });
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// How many times [id]'s agent was told to continue.
  int continued(String id) => [
    for (final user in clis[id]?.users ?? const <Map<String, Object?>>[])
      if ('${user['message']}'.contains(_continue)) user,
  ].length;

  List<String> listed() => [
    for (final entry in resumes.entries) entry.sessionId,
  ];

  testWidgets('agents stopped one after another at the same limit all go '
      'on once it resets, then are no longer listed', (tester) async {
    await start(tester);
    final resets = now.add(const Duration(hours: 2));
    await hit(tester, 'a', resets);
    // Half an hour on, another stops at it, while the user looks elsewhere.
    await elapse(tester, const Duration(minutes: 30));
    await hit(tester, 'b', resets);
    await elapse(tester, const Duration(minutes: 30));
    await hit(tester, 'c', resets);
    expect(listed(), unorderedEquals(['a', 'b', 'c']));

    await elapse(tester, const Duration(hours: 1, minutes: 1));
    expect([continued('a'), continued('b'), continued('c')], [1, 1, 1]);
    expect(listed(), isEmpty);
  });

  testWidgets('the setting off: none goes on, and none is listed past the '
      'reset', (tester) async {
    on = false;
    await start(tester);
    final resets = now.add(const Duration(hours: 1));
    await hit(tester, 'a', resets);
    await hit(tester, 'b', resets);
    expect(listed(), unorderedEquals(['a', 'b']));
    await elapse(tester, const Duration(hours: 1, minutes: 1));
    expect([continued('a'), continued('b')], [0, 0]);
    expect(listed(), isEmpty);
  });

  testWidgets('limits resetting at different times: each goes on at its '
      'own, and leaves the list then', (tester) async {
    await start(tester);
    await hit(tester, 'a', now.add(const Duration(hours: 1)));
    await hit(tester, 'b', now.add(const Duration(hours: 3)));

    await elapse(tester, const Duration(hours: 1, minutes: 1));
    expect([continued('a'), continued('b')], [1, 0]);
    expect(listed(), ['b']);

    await elapse(tester, const Duration(hours: 2));
    expect([continued('a'), continued('b')], [1, 1]);
    expect(listed(), isEmpty);
  });

  testWidgets('stopped at the limit again as it goes on (the reset not '
      'taken yet), it goes on again a little later', (tester) async {
    await start(tester);
    final resets = now.add(const Duration(hours: 1));
    await hit(tester, 'a', resets);
    await elapse(tester, const Duration(hours: 1, minutes: 1));
    expect(continued('a'), 1);

    // The CLI still says the reset it said: past now.
    clis['a']!.push({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'rejected',
        'resetsAt': resets.millisecondsSinceEpoch ~/ 1000,
      },
    });
    clis['a']!.push({
      'type': 'result',
      'subtype': 'success',
      'is_error': true,
      'result': "You've hit your session limit",
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(resumes['a'], isNotNull);
    expect(continued('a'), 1);

    await elapse(tester, const Duration(minutes: 2));
    expect(continued('a'), 2);
    expect(listed(), isEmpty);
  });

  testWidgets('due while the app was closed: all go on as it opens, '
      'their agents not opened before', (tester) async {
    final resets = now.subtract(const Duration(minutes: 10));
    await store.write({
      'entries': [
        for (final id in ['a', 'b'])
          ResumeEntry(sessionId: id, resetsAt: resets).toJson(),
      ],
    });
    await start(tester);
    expect(listed(), unorderedEquals(['a', 'b']));
    await elapse(tester, Duration.zero);
    for (var i = 0; i < 5 && listed().isNotEmpty; i++) {
      await elapse(tester, const Duration(minutes: 1));
    }
    expect([continued('a'), continued('b'), continued('c')], [1, 1, 0]);
    expect(listed(), isEmpty);
  });
}
