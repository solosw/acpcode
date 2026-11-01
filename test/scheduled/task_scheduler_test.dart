import 'dart:async';
import 'dart:convert';

import 'package:baocode/scheduled/scheduled_task.dart';
import 'package:baocode/scheduled/task_scheduler.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

ScheduledTask task({String id = 'task', bool enabled = true}) => ScheduledTask(
  id: id,
  name: 'Audit',
  prompt: 'Run audit',
  kernel: 'claude-code',
  project: 'ssh://dev/home/project',
  enabled: enabled,
  schedule: TaskSchedule(hour: 9, minute: 0, days: {1, 2, 3, 4, 5}),
);

void main() {
  test(
    'calendar schedules skip weekends, exact occurrences and year boundaries',
    () {
      final schedule = task().schedule;
      expect(
        schedule.nextAfter(DateTime(2026, 1, 2, 8)),
        DateTime(2026, 1, 2, 9),
      );
      expect(
        schedule.nextAfter(DateTime(2026, 1, 2, 9)),
        DateTime(2026, 1, 5, 9),
      );
      final weekly = TaskSchedule(hour: 23, minute: 30, days: {4});
      expect(
        weekly.nextAfter(DateTime(2026, 12, 31, 23, 30)),
        DateTime(2027, 1, 7, 23, 30),
      );
      expect(
        () => TaskSchedule(hour: 24, minute: 0, days: {1}),
        throwsArgumentError,
      );
      expect(
        TaskSchedule.fromJson({'hour': 9, 'minute': 0, 'days': []}),
        isNull,
      );
    },
  );

  test(
    'round trip retains remote locations, settings, session and runtime state',
    () {
      final original = ScheduledTask(
        id: 'one',
        name: 'Audit',
        prompt: '/audit',
        kernel: 'custom-acp',
        project: 'ssh://dev/home/project',
        worktree: 'ssh://dev/home/tree',
        schedule: task().schedule,
        settings: {'model': 'agent-model', 'mode': 'code', 'effort': 'high'},
        reuse: true,
        sessionId: 'kept',
        sessionLocation: 'ssh://dev/home/tree',
        lastRun: DateTime(2026, 1, 1),
        error: 'offline',
        enabled: false,
      );
      final decoded = ScheduledTask.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      )!;
      expect(decoded.toJson(), original.toJson());
      expect(ScheduledTask.fromJson({'id': 'bad'}), isNull);
      expect(
        ScheduledTask.fromJson({...original.toJson(), 'prompt': ''}),
        isNull,
      );
    },
  );

  test(
    'due occurrence is claimed once, persisted before dispatch, then advanced',
    () async {
      var now = DateTime(2026, 1, 5, 8, 59);
      final store = MemoryPreferenceStore();
      final release = Completer<void>();
      var calls = 0;
      late TaskScheduler scheduler;
      scheduler = TaskScheduler(
        store: store,
        clock: () => now,
        execute: (t, save) async {
          calls++;
          final data = (store.preferences['tasks'] as List).single as Map;
          expect(data['lastRun'], now.toIso8601String());
          expect(data['nextRun'], DateTime(2026, 1, 6, 9).toIso8601String());
          await release.future;
        },
      );
      addTearDown(scheduler.dispose);
      await scheduler.load(startTimer: false);
      final t = task();
      await scheduler.save(t);
      now = DateTime(2026, 1, 5, 9, 0, 15);
      await scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(scheduler.running(t.id), isTrue);
      await scheduler.tick();
      await scheduler.run(t);
      expect(calls, 1);
      now = DateTime(2026, 1, 6, 9);
      await scheduler.tick();
      expect(t.nextRun, DateTime(2026, 1, 7, 9));
      expect(calls, 1);
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(scheduler.running(t.id), isFalse);
    },
  );

  test('missed occurrences are skipped on load and after sleep', () async {
    var now = DateTime(2026, 1, 5, 9, 5);
    final t = task()..nextRun = DateTime(2026, 1, 5, 9);
    final store = MemoryPreferenceStore({
      'tasks': [
        t.toJson(),
        t.toJson(),
        {'invalid': true},
      ],
    });
    var calls = 0;
    final scheduler = TaskScheduler(
      store: store,
      clock: () => now,
      execute: (_, _) async {
        calls++;
      },
    );
    addTearDown(scheduler.dispose);
    await scheduler.load(startTimer: false);
    expect(scheduler.tasks, hasLength(1));
    expect(scheduler.tasks.single.nextRun, DateTime(2026, 1, 6, 9));
    now = DateTime(2026, 1, 8, 10);
    await scheduler.tick();
    expect(calls, 0);
    expect(scheduler.tasks.single.nextRun, DateTime(2026, 1, 9, 9));
  });

  test(
    'pause, resume, edit, remove and execution errors survive persistence',
    () async {
      final store = MemoryPreferenceStore();
      final now = DateTime(2026, 1, 5, 8);
      final scheduler = TaskScheduler(
        store: store,
        clock: () => now,
        execute: (t, checkpoint) async {
          t.sessionId = 'conversation';
          checkpoint();
          throw StateError('offline');
        },
      );
      addTearDown(scheduler.dispose);
      await scheduler.load(startTimer: false);
      final t = task();
      await scheduler.save(t);
      await scheduler.setEnabled(t, false);
      expect(t.nextRun, isNull);
      await scheduler.setEnabled(t, true);
      expect(t.nextRun, DateTime(2026, 1, 5, 9));
      await scheduler.run(t);
      expect(t.error, contains('offline'));
      expect(scheduler.running(t.id), isFalse);
      expect(
        (store.preferences['tasks'] as List).single,
        containsPair('sessionId', 'conversation'),
      );
      await scheduler.save(task(id: t.id, enabled: false));
      expect(scheduler.tasks, hasLength(1));
      await scheduler.remove(scheduler.tasks.single);
      expect(store.preferences['tasks'], isEmpty);
    },
  );
}
