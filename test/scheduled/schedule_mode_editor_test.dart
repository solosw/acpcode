import 'package:baocode/scheduled/scheduled_task.dart';
import 'package:baocode/scheduled/scheduled_tasks_view.dart';
import 'package:baocode/scheduled/task_scheduler.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_test_support.dart';

Future<void> selectKind(WidgetTester tester, String label) async {
  final field = find.byKey(const ValueKey('scheduled-schedule-kind'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

FilledButton saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save task'));

void main() {
  for (final width in [1100.0, 500.0]) {
    for (final cron in [false, true]) {
      testWidgets(
        'create, validate and edit ${cron ? 'Cron' : 'interval'} at width $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final workspace = Workspace(
            projects: const [Project('Project', '/tmp/project')],
            kernels: [taskDescriptor([])],
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
          final prompt = find.byKey(const ValueKey('scheduled-prompt'));
          await tester.ensureVisible(prompt);
          await tester.enterText(prompt, 'Run audit');
          await tester.pumpAndSettle();
          await selectKind(tester, cron ? 'Custom Cron' : 'Fixed interval');
          final input = find.byKey(
            ValueKey(cron ? 'scheduled-cron' : 'scheduled-interval'),
          );
          await tester.ensureVisible(input);
          await tester.enterText(input, cron ? '0 0 31 2 *' : '0');
          await tester.pumpAndSettle();
          expect(saveButton(tester).onPressed, isNull);
          expect(
            find.byKey(const ValueKey('scheduled-next-preview')),
            findsNothing,
          );
          expect(
            find.text(
              cron
                  ? 'Enter a valid five-field numeric Cron with a possible run date.'
                  : 'Enter a positive whole number (1 minute to 365 days).',
            ),
            findsOneWidget,
          );
          await tester.enterText(input, cron ? '*/15 9-17 * * 1-5' : '2');
          await tester.pumpAndSettle();
          if (!cron) {
            final units = find.byKey(const ValueKey('scheduled-interval-unit'));
            await tester.tap(units);
            await tester.pumpAndSettle();
            await tester.tap(find.text('Hours').last);
            await tester.pumpAndSettle();
          }
          expect(saveButton(tester).onPressed, isNotNull);
          expect(
            find.byKey(const ValueKey('scheduled-next-preview')),
            findsOneWidget,
          );
          await tester.ensureVisible(find.text('Save task'));
          await tester.tap(find.text('Save task'));
          await tester.pumpAndSettle();
          final task = scheduler.tasks.single;
          expect(
            task.schedule.kind,
            cron ? TaskScheduleKind.cron : TaskScheduleKind.interval,
          );
          expect(
            cron ? task.schedule.cronExpression : task.schedule.intervalMinutes,
            cron ? '*/15 9-17 * * 1-5' : 120,
          );
          expect(task.nextRun, isNotNull);
          await tester.tap(find.byTooltip('Edit'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(input).controller!.text,
            cron ? '*/15 9-17 * * 1-5' : '2',
          );
          if (!cron) {
            final field = find.byKey(const ValueKey('scheduled-interval-unit'));
            final unit = tester.widget<DropdownButton<int>>(
              find.descendant(
                of: field,
                matching: find.byWidgetPredicate(
                  (w) => w is DropdownButton<int>,
                ),
              ),
            );
            expect(unit.value, 60);
          }
          // Switching back must have valid calendar defaults, not the new mode's empty days.
          await selectKind(tester, 'Weekday and time');
          expect(saveButton(tester).onPressed, isNotNull);
          await tester.ensureVisible(find.text('Save task'));
          await tester.tap(find.text('Save task'));
          await tester.pumpAndSettle();
          expect(
            scheduler.tasks.single.schedule.kind,
            TaskScheduleKind.calendar,
          );
          expect(scheduler.tasks.single.schedule.days, {1, 2, 3, 4, 5});
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
