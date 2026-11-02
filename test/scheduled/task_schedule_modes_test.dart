import 'dart:async';
import 'dart:convert';

import 'package:baocode/scheduled/scheduled_task.dart';
import 'package:baocode/scheduled/task_scheduler.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

ScheduledTask scheduled(TaskSchedule schedule) => ScheduledTask(
  id: 'task',
  name: 'Audit',
  prompt: 'Audit',
  kernel: 'claude-code',
  project: '/project',
  schedule: schedule,
);

void main() {
  test('interval bounds, full delay and anchored cadence', () {
    final now = DateTime(2026, 1, 1, 10, 7, 23, 456);
    final schedule = TaskSchedule.interval(minutes: 30);
    expect(schedule.nextAfter(now), now.add(const Duration(minutes: 30)));
    expect(
      schedule.nextAfter(now, anchor: DateTime(2026, 1, 1, 10)),
      DateTime(2026, 1, 1, 10, 30),
    );
    expect(
      schedule.nextAfter(
        DateTime(2026, 1, 1, 11),
        anchor: DateTime(2026, 1, 1, 10),
      ),
      DateTime(2026, 1, 1, 11, 30),
    );
    expect(
      schedule.nextAfter(now, anchor: DateTime(2026, 1, 1, 12)),
      DateTime(2026, 1, 1, 12),
    );
    for (final minutes in [0, -1, 525601]) {
      expect(
        () => TaskSchedule.interval(minutes: minutes),
        throwsArgumentError,
      );
    }
    expect(
      TaskSchedule.interval(minutes: 525600).nextAfter(now),
      now.add(const Duration(days: 365)),
    );
  });

  test('Cron keeps wall time across DST while intervals keep elapsed time', () {
    for (final before in [DateTime(2026, 3, 7, 9), DateTime(2026, 10, 31, 9)]) {
      final wall = TaskSchedule.cron('0 9 * * *').nextAfter(before);
      expect(wall, DateTime(before.year, before.month, before.day + 1, 9));
      expect(
        TaskSchedule.interval(minutes: 1440)
            .nextAfter(before)
            .difference(before),
        const Duration(hours: 24),
      );
    }
    final normalized = DateTime(2026, 3, 8, 2, 30);
    final expected = normalized.hour == 2
        ? normalized
        : DateTime(2026, 3, 9, 2, 30);
    expect(
      TaskSchedule.cron('30 2 * * *').nextAfter(DateTime(2026, 3, 7, 2, 30)),
      expected,
    );
  });

  final cronCases = <(String, DateTime, DateTime)>[
    (
      '*/30 * * * *',
      DateTime(2026, 1, 1, 10, 7, 1),
      DateTime(2026, 1, 1, 10, 30),
    ),
    ('*/30 * * * *', DateTime(2026, 1, 1, 10, 30), DateTime(2026, 1, 1, 11)),
    ('0 9 * * 1-5', DateTime(2026, 1, 2, 9), DateTime(2026, 1, 5, 9)),
    (
      '5,20,40 8-10/2 * * *',
      DateTime(2026, 1, 1, 8, 40),
      DateTime(2026, 1, 1, 10, 5),
    ),
    (
      '5/20 * * * *',
      DateTime(2026, 1, 1, 10, 25),
      DateTime(2026, 1, 1, 10, 45),
    ),
    ('0 0 1 12,1 *', DateTime(2026, 1, 1), DateTime(2026, 12, 1)),
    ('0 0 * * 0', DateTime(2026, 1, 3), DateTime(2026, 1, 4)),
    ('0 0 * * 7', DateTime(2026, 1, 3), DateTime(2026, 1, 4)),
    ('0 0 * * 6-7', DateTime(2026, 1, 3), DateTime(2026, 1, 4)),
    ('0 9 13 * 1', DateTime(2026, 1, 11, 12), DateTime(2026, 1, 12, 9)),
    ('0 9 13 * 1', DateTime(2026, 1, 12, 9), DateTime(2026, 1, 13, 9)),
    ('0 0 29 2 *', DateTime(2026, 1, 1), DateTime(2028, 2, 29)),
    ('0 0 29 2 *', DateTime(2096, 2, 29), DateTime(2104, 2, 29)),
    ('0 0 31 * *', DateTime(2026, 4, 1), DateTime(2026, 5, 31)),
    ('0 0 1 1 *', DateTime(2026, 12, 31, 23, 59), DateTime(2027, 1, 1)),
    (
      '*/9223372036854775807 * * * *',
      DateTime(2026, 1, 1, 10),
      DateTime(2026, 1, 1, 11),
    ),
  ];
  for (final (expression, after, expected) in cronCases) {
    test('Cron $expression after $after', () {
      expect(TaskSchedule.cron(expression).nextAfter(after), expected);
    });
  }

  for (final expression in [
    '',
    '* * * *',
    '* * * * * *',
    '@daily',
    '60 * * * *',
    '* 24 * * *',
    '0 0 0 * *',
    '0 0 * 13 *',
    '0 0 * * 8',
    '0 0 31 2 *',
    '0 0 31 4,6,9,11 *',
    '*/0 * * * *',
    '*/-2 * * * *',
    '*/+2 * * * *',
    '1-0 * * * *',
    '1--2 * * * *',
    '1-2-3 * * * *',
    '*, * * * *',
    '1//2 * * * *',
    '1/2/3 * * * *',
    'a * * * *',
    '0 0 * * MON',
    '0.5 * * * *',
    '0 0 ? * *',
    '0 0 L * *',
    '0 0 * * 1#2',
  ]) {
    test('reject invalid or impossible Cron: $expression', () {
      expect(() => TaskSchedule.cron(expression), throwsFormatException);
      expect(
        TaskSchedule.fromJson({'type': 'cron', 'expression': expression}),
        isNull,
      );
    });
  }

  test(
    'schedule serialization retains legacy data and rejects invalid types',
    () {
      for (final schedule in [
        TaskSchedule(hour: 9, minute: 15, days: {1, 5}),
        TaskSchedule.interval(minutes: 120),
        TaskSchedule.cron('  */15   9-17  * * 1-5  '),
      ]) {
        final original = scheduled(schedule);
        final decoded = ScheduledTask.fromJson(
          jsonDecode(jsonEncode(original.toJson())),
        )!;
        expect(decoded.toJson(), original.toJson());
        expect(decoded.schedule.kind, schedule.kind);
      }
      expect(
        TaskSchedule.cron('  */15   9-17  * * 1-5  ').cronExpression,
        '*/15 9-17 * * 1-5',
      );
      expect(
        TaskSchedule.fromJson({
          'hour': 9,
          'minute': 0,
          'days': [1, 2, 3, 4, 5],
        })!.kind,
        TaskScheduleKind.calendar,
      );
      for (final raw in [
        {
          'type': 'unknown',
          'hour': 9,
          'minute': 0,
          'days': [1],
        },
        {'type': 'interval', 'minutes': 0},
        {'type': 'interval', 'minutes': '30'},
        {'type': 'cron', 'expression': 123},
        {
          'hour': 9,
          'minute': 0,
          'days': [1, '2'],
        },
      ]) {
        expect(TaskSchedule.fromJson(raw), isNull);
      }
    },
  );

  test('interval ticks remain anchored, skip busy/missed runs, survive restart and reset on re-enable', () async {
    var now = DateTime(2026, 1, 1, 10);
    final store = MemoryPreferenceStore();
    final release = Completer<void>();
    var calls = 0;
    final scheduler = TaskScheduler(
      store: store,
      clock: () => now,
      execute: (_, _) async {
        calls++;
        await release.future;
      },
    );
    addTearDown(scheduler.dispose);
    await scheduler.load(startTimer: false);
    final task = scheduled(TaskSchedule.interval(minutes: 5));
    await scheduler.save(task);
    expect(task.nextRun, DateTime(2026, 1, 1, 10, 5));
    now = DateTime(2026, 1, 1, 10, 5, 15);
    await scheduler.tick();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(task.nextRun, DateTime(2026, 1, 1, 10, 10));
    now = DateTime(2026, 1, 1, 10, 10, 15);
    await scheduler.tick();
    expect(calls, 1);
    expect(task.nextRun, DateTime(2026, 1, 1, 10, 15));
    release.complete();
    await Future<void>.delayed(Duration.zero);
    now = DateTime(2026, 1, 1, 11, 3);
    await scheduler.tick();
    expect(calls, 1);
    expect(task.nextRun, DateTime(2026, 1, 1, 11, 5));
    final restored = TaskScheduler(
      store: store,
      clock: () => now,
      execute: (_, _) async {},
    );
    addTearDown(restored.dispose);
    await restored.load(startTimer: false);
    final loaded = restored.tasks.single;
    expect(loaded.nextRun, DateTime(2026, 1, 1, 11, 5));
    await restored.setEnabled(loaded, false);
    expect(loaded.nextRun, isNull);
    now = DateTime(2026, 1, 1, 11, 4);
    await restored.setEnabled(loaded, true);
    expect(loaded.nextRun, DateTime(2026, 1, 1, 11, 9));
  });

  test(
    'load skips stale interval and Cron occurrences, retains other valid tasks',
    () async {
      final now = DateTime(2026, 1, 1, 11, 3);
      final interval = scheduled(TaskSchedule.interval(minutes: 5))
        ..nextRun = DateTime(2026, 1, 1, 10);
      final cron = scheduled(TaskSchedule.cron('*/10 * * * *'));
      final store = MemoryPreferenceStore({
        'tasks': [
          {...interval.toJson(), 'id': 'interval'},
          {...cron.toJson(), 'id': 'cron'},
          {
            ...cron.toJson(),
            'id': 'bad',
            'schedule': {'type': 'cron', 'expression': 'invalid'},
          },
        ],
      });
      final scheduler = TaskScheduler(
        store: store,
        clock: () => now,
        execute: (_, _) async => fail('Must not catch up'),
      );
      addTearDown(scheduler.dispose);
      await scheduler.load(startTimer: false);
      expect(scheduler.tasks, hasLength(2));
      expect(scheduler.tasks[0].nextRun, DateTime(2026, 1, 1, 11, 5));
      expect(scheduler.tasks[1].nextRun, DateTime(2026, 1, 1, 11, 10));
      await scheduler.tick();
    },
  );

  test(
    'Cron claims due runs only once and advances on wall-clock boundaries',
    () async {
      var now = DateTime(2026, 1, 1, 10, 7);
      var calls = 0;
      final scheduler = TaskScheduler(
        store: MemoryPreferenceStore(),
        clock: () => now,
        execute: (_, _) async {
          calls++;
        },
      );
      addTearDown(scheduler.dispose);
      await scheduler.load(startTimer: false);
      final task = scheduled(TaskSchedule.cron('*/10 * * * *'));
      await scheduler.save(task);
      expect(task.nextRun, DateTime(2026, 1, 1, 10, 10));
      now = DateTime(2026, 1, 1, 10, 10, 15);
      await scheduler.tick();
      await scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(task.nextRun, DateTime(2026, 1, 1, 10, 20));
      now = DateTime(2026, 1, 1, 11, 7);
      await scheduler.tick();
      expect(calls, 1);
      expect(task.nextRun, DateTime(2026, 1, 1, 11, 10));
    },
  );
}
