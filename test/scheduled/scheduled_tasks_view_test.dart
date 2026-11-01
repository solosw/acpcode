import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/scheduled/scheduled_tasks_view.dart';
import 'package:baocode/scheduled/task_scheduler.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_test_support.dart';

void main() {
  testWidgets(
    'switching agent and host reloads live choices in the selected remote project',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const remote = 'ssh://dev/home/project';
      final created = <TaskTestKernel>[];
      final workspace = Workspace(
        projects: const [
          Project('Local', '/tmp/project'),
          Project('Remote', remote),
        ],
        kernels: [
          taskDescriptor(created),
          taskDescriptor(created, id: 'custom-acp'),
        ],
      );
      addTearDown(workspace.dispose);
      final scheduler = TaskScheduler(
        store: MemoryPreferenceStore(),
        execute: (_, _) async {},
      );
      addTearDown(scheduler.dispose);
      await scheduler.load(startTimer: false);
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
      await tester.tap(find.text('Create task'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom ACP').last);
      await tester.pumpAndSettle();
      expect(created.first.disposed, isTrue);
      expect(created.last.descriptor.id, 'custom-acp');
      await tester.tap(find.byKey(const ValueKey('host-null')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('dev').last);
      await tester.pumpAndSettle();
      expect(created.last.context.cwd, remote);
      expect(created.last.descriptor.id, 'custom-acp');
      await tester.enterText(
        find.byKey(const ValueKey('scheduled-prompt')),
        'Remote audit',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save task'));
      await tester.pumpAndSettle();
      expect(scheduler.tasks.single.project, remote);
      expect(scheduler.tasks.single.kernel, 'custom-acp');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('task entry is immediately below Stash and selected as a page', (
    tester,
  ) async {
    final workspace = Workspace(kernels: [taskDescriptor([])]);
    addTearDown(workspace.dispose);
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: Sidebar(
              workspace: workspace,
              onCollapse: () {},
              onStash: () {},
              onScheduledTasks: () => opened = true,
              scheduling: true,
            ),
          ),
        ),
      ),
    );
    final stash = find.text('Stash');
    final tasks = find.text('Scheduled Tasks');
    expect(stash, findsOneWidget);
    expect(tasks, findsOneWidget);
    expect(
      tester.getTopLeft(tasks).dy,
      greaterThan(tester.getTopLeft(stash).dy),
    );
    expect(
      tester.getTopLeft(tasks).dy - tester.getTopLeft(stash).dy,
      lessThan(45),
    );
    await tester.tap(tasks);
    expect(opened, isTrue);
  });

  for (final width in [1100.0, 500.0]) {
    testWidgets(
      'editor uses live agent choices and saves prompt at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final created = <TaskTestKernel>[];
        final workspace = Workspace(
          projects: const [Project('Project', '/tmp/scheduled-project')],
          kernels: [
            taskDescriptor(created),
            taskDescriptor(created, id: 'custom-acp'),
          ],
        );
        addTearDown(workspace.dispose);
        final scheduler = TaskScheduler(
          store: MemoryPreferenceStore(),
          execute: (_, _) async {},
        );
        addTearDown(scheduler.dispose);
        await scheduler.load(startTimer: false);
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
        await tester.tap(find.text('Create task'));
        await tester.pumpAndSettle();
        expect(created, hasLength(1));
        expect(find.byType(ComposerPicker), findsNWidgets(2));
        expect(find.text('Agent first'), findsNWidgets(2));
        if (width > 760) {
          await tester.tap(find.byType(ComposerPicker).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Agent second'));
          await tester.pumpAndSettle();
        }
        if (width > 760) {
          await tester.tap(find.text('Fast'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Fast'));
          await tester.pumpAndSettle();
        }
        final prompt = find.byKey(const ValueKey('scheduled-prompt'));
        if (width <= 760) {
          await tester.scrollUntilVisible(
            prompt,
            250,
            scrollable: find.byType(Scrollable).first,
          );
        } else {
          await tester.ensureVisible(prompt);
        }
        await tester.enterText(prompt, 'Run audit');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save task'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(scheduler.tasks.single.prompt, 'Run audit');
        expect(scheduler.tasks.single.kernel, 'claude-code');
        expect(scheduler.tasks.single.settings['fast'], 'standard');
        expect(
          scheduler.tasks.single.settings['model'],
          width > 760 ? 'second' : 'first',
        );
        expect(created.single.disposed, isTrue);
        expect(find.text('Run audit'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
