import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/resume_after_reset.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

const _gateway = ModelProvider(
  id: 'gw',
  name: 'Gateway',
  protocol: ProviderProtocol.openaiChat,
  baseUrl: 'https://gw.example.com/v1',
  models: [ProviderModel(id: 'gpt-5', contextWindow: 400000)],
);

class _Catalog implements SessionCatalog {
  static final kept = SessionRecord(
    id: 'session-1',
    title: 'Fix the tests',
    updatedAt: DateTime(2026, 10, 13, 14),
    cwd: '/tmp/project',
    path: '/tmp/project/session-1.jsonl',
  );

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: '/tmp/project', sessions: [kept]),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}

void main() {
  late ResumeAfterReset resumes;
  late List<FakeCli> clis;
  late Workspace workspace;
  late DateTime now;

  setUp(() {
    now = DateTime.now();
    resumes = ResumeAfterReset(enabled: () => true, clock: () => now);
    clis = [];
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
        start: (_) async {
          final cli = FakeCli();
          clis.add(cli);
          return cli;
        },
        readHistory: (_) async => const [],
        providers: ModelProviders.memory(providers: [_gateway]),
      ),
    );
    workspace = Workspace(kernels: [descriptor], resumes: resumes);
    addTearDown(() {
      workspace.dispose();
      resumes.dispose();
    });
  });

  AgentThread kept() =>
      workspace.threads.firstWhere((thread) => thread.id == 'session-1');

  /// The kept session opened, and stopped at the limit an hour from now.
  Future<void> hitLimit(WidgetTester tester) async {
    await tester.runAsync(workspace.load);
    final session = kept().session..attach();
    addTearDown(session.detach);
    await tester.pump(const Duration(milliseconds: 100));
    final resets = now.add(const Duration(hours: 1));
    clis.last.push({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'rejected',
        'resetsAt': resets.millisecondsSinceEpoch ~/ 1000,
      },
    });
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('usage limit: the workspace lists an agent stopped at it, '
      'and continues it once it resets', (tester) async {
    await hitLimit(tester);
    expect(resumes['session-1'], isNotNull);

    final sent = clis.last.users.length;
    // An hour and a minute on.
    now = now.add(const Duration(hours: 1, minutes: 1));
    await tester.pump(const Duration(hours: 1, minutes: 1));
    await tester.pump(const Duration(milliseconds: 100));
    final users = clis.last.users.skip(sent).toList();
    expect(users, hasLength(1));
    expect(
      '${users.single['message']}',
      contains('The usage limit has reset. Continue where you left off.'),
    );
    expect(resumes['session-1'], isNull);
  });

  testWidgets('usage limit: a turn that goes through takes the agent off', (
    tester,
  ) async {
    await hitLimit(tester);
    kept().session.send(const ComposerMessage(text: 'go on'));
    await tester.pump(const Duration(milliseconds: 100));
    clis.last.push({'type': 'result', 'subtype': 'success', 'is_error': false});
    await tester.pump(const Duration(milliseconds: 100));
    expect(resumes['session-1'], isNull);
  });

  testWidgets('usage limit: switched to another provider while waiting, it '
      'is no longer to go on', (tester) async {
    await hitLimit(tester);
    final sent = clis.last.users.length;
    final models = kept().session.models!;
    models.onSelected(
      models.options.firstWhere((option) => option.id == '@gw/gpt-5'),
    );
    await tester.pump();
    expect(resumes['session-1'], isNull);

    now = now.add(const Duration(hours: 1, minutes: 1));
    await tester.pump(const Duration(hours: 1, minutes: 1));
    expect(clis.last.users.length, sent);
  });

  testWidgets('usage limit: deleted, it is forgotten', (tester) async {
    await hitLimit(tester);
    workspace.delete(kept());
    expect(resumes['session-1'], isNull);
    await tester.pump(const Duration(milliseconds: 100));
  });
}
