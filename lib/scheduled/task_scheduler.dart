import 'dart:async';

import 'package:flutter/foundation.dart';

import '../workspace/preference_store.dart';
import 'scheduled_task.dart';

/// Only the main window owns a scheduler. Missed occurrences are skipped,
/// not replayed when the app opens or the computer wakes.
class TaskScheduler extends ChangeNotifier {
  TaskScheduler({
    required this.store,
    required this.execute,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final PreferenceStore store;
  final Future<void> Function(ScheduledTask task, VoidCallback checkpoint)
  execute;
  final DateTime Function() clock;
  final List<ScheduledTask> _tasks = [];
  List<ScheduledTask> get tasks => List.unmodifiable(_tasks);
  final Set<String> _running = {};
  bool running(String id) => _running.contains(id);
  bool ready = false;
  bool _disposed = false;
  Timer? _timer;

  Future<void> load({bool startTimer = true}) async {
    final data = await store.read();
    if (_disposed) return;
    final now = clock();
    if (data['tasks'] case final List items) {
      for (final raw in items) {
        final task = ScheduledTask.fromJson(raw);
        if (task == null || _tasks.any((other) => other.id == task.id)) {
          continue;
        }
        task.nextRun = task.enabled ? task.schedule.nextAfter(now) : null;
        _tasks.add(task);
      }
    }
    ready = true;
    await _save();
    if (_disposed) return;
    if (startTimer) {
      _timer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(tick()),
      );
    }
    notifyListeners();
  }

  Future<void> _save() => store.write({
    'tasks': [for (final task in _tasks) task.toJson()],
  });

  Future<void> save(ScheduledTask task) async {
    if (_disposed || running(task.id)) return;
    final index = _tasks.indexWhere((t) => t.id == task.id);
    task.nextRun = task.enabled ? task.schedule.nextAfter(clock()) : null;
    if (index < 0) {
      _tasks.add(task);
    } else {
      _tasks[index] = task;
    }
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(ScheduledTask task, bool enabled) async {
    task.enabled = enabled;
    task.nextRun = enabled ? task.schedule.nextAfter(clock()) : null;
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> remove(ScheduledTask task) async {
    if (running(task.id)) return;
    _tasks.remove(task);
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> tick() async {
    if (!ready || _disposed) return;
    final now = clock();
    for (final task in List.of(_tasks)) {
      final due = task.nextRun;
      if (!task.enabled || due == null || due.isAfter(now)) continue;
      // Advance before dispatch, even if this task is still running.
      task.nextRun = task.schedule.nextAfter(now);
      if (now.difference(due) >= const Duration(minutes: 1) ||
          running(task.id)) {
        await _save();
        continue;
      }
      unawaited(run(task));
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> run(ScheduledTask task) async {
    if (!ready || _disposed || running(task.id) || !_tasks.contains(task)) {
      return;
    }
    _running.add(task.id);
    task.lastRun = clock();
    task.error = null;
    notifyListeners();
    try {
      // Persist the claim before starting a conversation.
      await _save();
      if (_disposed) return;
      await execute(task, () {
        if (!_disposed) {
          unawaited(_save());
          notifyListeners();
        }
      });
    } on Object catch (error) {
      task.error = error.toString();
    } finally {
      _running.remove(task.id);
      await _save();
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
