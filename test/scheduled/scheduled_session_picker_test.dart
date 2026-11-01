import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/scheduled/scheduled_task.dart';
import 'package:baocode/scheduled/scheduled_tasks_view.dart';
import 'package:baocode/scheduled/task_scheduler.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_test_support.dart';

DropdownButton<String> sessionPicker(WidgetTester tester) {
  final field = find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('session-'),
  );
  return tester.widget<DropdownButton<String>>(
    find.descendant(
      of: field,
      matching: find.byWidgetPredicate(
        (widget) => widget is DropdownButton<String>,
      ),
    ),
  );
}

void main() {
  for (final selected in <String?>[null, 'archived', 'active', 'not-loaded']) {
    testWidgets(
      'task session picker filters archives with saved selection $selected',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const location = '/tmp/scheduled-project';
        final catalog = TaskTestCatalog()
          ..records.addAll([
            for (final id in ['active', 'archived'])
              SessionRecord(
                id: id,
                title: '$id conversation',
                updatedAt: DateTime(2026),
                cwd: location,
              ),
          ]);
        final workspace = Workspace(
          projects: const [Project('Project', location)],
          kernels: [taskDescriptor([], catalog: catalog)],
        );
        addTearDown(workspace.dispose);
        final active = await workspace.scheduledAgent(
          location: location,
          kernelId: 'claude-code',
          settings: const {},
          resumeId: 'active',
        );
        final archived = await workspace.scheduledAgent(
          location: location,
          kernelId: 'claude-code',
          settings: const {},
          resumeId: 'archived',
        );
        workspace.setArchived(archived, true);
        final scheduler = TaskScheduler(
          store: MemoryPreferenceStore(),
          execute: (_, _) async {},
        );
        addTearDown(scheduler.dispose);
        await scheduler.load(startTimer: false);
        await scheduler.save(
          ScheduledTask(
            id: 'task',
            name: 'Audit',
            prompt: 'Run audit',
            kernel: 'claude-code',
            project: location,
            reuse: true,
            sessionId: selected,
            sessionLocation: selected == null ? null : location,
            schedule: TaskSchedule(hour: 9, minute: 0, days: {1}),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ScheduledTasksView(
                scheduler: scheduler,
                workspace: workspace,
                onClose: () {},
                onOpenAgent: (_) {},
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Edit'));
        await tester.pumpAndSettle();
        final picker = sessionPicker(tester);
        final values = picker.items!.map((item) => item.value).toList();
        expect(values, isNot(contains('archived')));
        expect(values, contains('active'));
        expect(
          picker.value,
          selected == 'archived' || selected == null ? '' : selected,
        );
        expect(values, contains(picker.value));

        if (selected == 'active') {
          // Changes to archive state are reflected while the editor stays open.
          workspace.setArchived(active, true);
          await tester.pumpAndSettle();
          expect(sessionPicker(tester).items!.map((item) => item.value), ['']);
          expect(sessionPicker(tester).value, '');
        }
        await tester.ensureVisible(find.text('Save task'));
        await tester.tap(find.text('Save task'));
        await tester.pumpAndSettle();
        expect(
          scheduler.tasks.single.sessionId,
          selected == 'not-loaded' ? selected : null,
        );
        expect(
          scheduler.tasks.single.sessionLocation,
          selected == 'not-loaded' ? location : null,
        );
        expect(archived.archived, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
