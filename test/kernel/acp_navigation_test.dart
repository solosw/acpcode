import 'dart:async';

import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/customize/customize_view.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/keybindings/keybinding_service.dart';
import 'package:baocode/main.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deliberately never answers one startup request. Navigation must not wait.
class _StalledTransport implements AcpTransport {
  _StalledTransport(this.stalledMethod);

  final String stalledMethod;
  final written = <Map<String, Object?>>[];
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    if (message['method'] == stalledMethod) return;
    _messages.add({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': switch (message['method']) {
        'initialize' => {'protocolVersion': 1},
        'session/new' => {'sessionId': 'new-acp'},
        _ => <String, Object?>{},
      },
    });
  }

  @override
  void close() => _messages.close();
}

class _Catalog implements SessionCatalog {
  final record = SessionRecord(
    id: 'saved-acp',
    title: 'Saved ACP conversation',
    updatedAt: DateTime.utc(2026, 10, 12),
    cwd: '/tmp/acp-navigation',
  );

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: record.cwd, sessions: [record]),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [record];

  @override
  Future<void> delete(String id) async {}
}

class _SkillsStore implements CustomizationStore {
  @override
  String get configDir => '/c';
  @override
  String? get homeDir => null;
  @override
  bool get supported => true;
  @override
  bool get isLocal => true;
  @override
  Future<String> config() async => '/c';
  @override
  Future<List<Customization>> list(
    CustomizationKind kind, {
    String? project,
  }) async => [
    if (kind == CustomizationKind.skills)
      const Customization(
        kind: CustomizationKind.skills,
        scope: CustomizationScope.user,
        name: 'navigation-test-skill',
        description: 'Skills remain reachable during ACP startup',
        path: '/c/skills/navigation-test-skill/SKILL.md',
      ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder _inSidebar(String label) =>
    find.descendant(of: find.byType(Sidebar), matching: find.text(label));

Finder _picker(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ComposerPicker));

Future<Workspace> _pumpApp(
  WidgetTester tester,
  _StalledTransport transport,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  KeybindingService.instance = KeybindingService();
  addTearDown(() => KeybindingService.instance = KeybindingService());
  late final KernelDescriptor acp;
  acp = KernelDescriptor(
    id: 'navigation-acp',
    label: 'Navigation ACP',
    icon: Icons.hub,
    description: 'Test ACP agent',
    catalog: _Catalog(),
    create: (context) => AcpKernel(acp, context, (_) async => transport),
  );
  final workspace = Workspace(kernels: [MockKernels.codex, acp]);
  await workspace.load();
  workspace.rename(workspace.selected, 'Local navigation conversation');
  await tester.pumpWidget(
    BaoCodeApp(workspace: workspace, customizations: _SkillsStore()),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return workspace;
}

Future<void> _openSkills(WidgetTester tester) async {
  await tester.tap(_inSidebar('Skills'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  expect(find.byType(CustomizeView), findsOneWidget);
  expect(find.byType(ChatScreen), findsNothing);
  expect(find.text('navigation-test-skill'), findsOneWidget);
  expect(tester.takeException(), isNull);
}

final _desktop = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

void main() {
  for (final stalledMethod in ['initialize', 'session/load']) {
    testWidgets('can leave saved ACP while $stalledMethod is stalled', (
      tester,
    ) async {
      final transport = _StalledTransport(stalledMethod);
      final workspace = await _pumpApp(tester, transport);
      final local = workspace.selected;
      await tester.tap(_inSidebar('Saved ACP conversation'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(workspace.selected.kernel.id, 'navigation-acp');
      expect(
        workspace.selected.session.health.status,
        KernelHealthStatus.starting,
      );
      expect(
        transport.written.map((message) => message['method']),
        contains(stalledMethod),
      );
      expect(tester.takeException(), isNull);

      // Navigate away and back through the real sidebar, not direct API calls.
      await tester.tap(_inSidebar(local.title));
      await tester.pump(const Duration(milliseconds: 100));
      expect(workspace.selected, same(local));
      expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).session,
        same(local.session),
      );
      await tester.tap(_inSidebar('Saved ACP conversation'));
      await tester.pump(const Duration(milliseconds: 100));
      await _openSkills(tester);
    }, variant: _desktop);
  }

  testWidgets('composer ACP selection does not block navigation', (
    tester,
  ) async {
    final transport = _StalledTransport('initialize');
    final workspace = await _pumpApp(tester, transport);
    await tester.tap(_picker('Codex'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Navigation ACP').last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(workspace.selected.kernel.id, 'navigation-acp');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_picker('Navigation ACP'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _openSkills(tester);

    // Return to the same conversation and change the agent back. Neither the
    // dismissed picker nor an unfinished ACP request may trap clicks/focus.
    await tester.tap(_inSidebar(workspace.selected.title));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ChatScreen), findsOneWidget);
    await tester.tap(_picker('Navigation ACP'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Codex').last);
    await tester.pumpAndSettle();
    expect(workspace.selected.kernel, same(MockKernels.codex));
    expect(_picker('Codex'), findsOneWidget);
    await _openSkills(tester);
  }, variant: _desktop);
}
