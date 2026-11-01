/// A local-time recurring schedule. Calendar arithmetic keeps the chosen
/// wall-clock time across daylight-saving changes.
class TaskSchedule {
  TaskSchedule({
    required this.hour,
    required this.minute,
    required Set<int> days,
  }) : days = Set.unmodifiable(days) {
    if (hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        days.isEmpty ||
        days.any((day) => day < 1 || day > 7)) {
      throw ArgumentError('Invalid schedule');
    }
  }

  final int hour;
  final int minute;
  final Set<int> days;

  DateTime nextAfter(DateTime now) {
    for (var offset = 0; offset <= 7; offset++) {
      final next = DateTime(
        now.year,
        now.month,
        now.day + offset,
        hour,
        minute,
      );
      if (days.contains(next.weekday) && next.isAfter(now)) return next;
    }
    throw StateError('No next occurrence');
  }

  Map<String, Object?> toJson() => {
    'hour': hour,
    'minute': minute,
    'days': days.toList()..sort(),
  };

  static TaskSchedule? fromJson(Object? json) {
    if (json case {
      'hour': final int hour,
      'minute': final int minute,
      'days': final List<Object?> days,
    }) {
      try {
        return TaskSchedule(
          hour: hour,
          minute: minute,
          days: days.whereType<int>().toSet(),
        );
      } on ArgumentError {
        return null;
      }
    }
    return null;
  }
}

/// The host is part of each project/worktree location (ssh://...), never
/// stripped before handing it to Workspace or a kernel.
class ScheduledTask {
  ScheduledTask({
    required this.id,
    required this.name,
    required this.prompt,
    required this.kernel,
    required this.project,
    required this.schedule,
    this.settings = const {},
    this.worktree,
    this.newWorktree = false,
    this.reuse = false,
    this.enabled = true,
    this.sessionId,
    this.sessionLocation,
    this.nextRun,
    this.lastRun,
    this.error,
  });

  final String id;
  final String name;
  final String prompt;
  final String kernel;
  final String project;
  final String? worktree;
  final bool newWorktree;
  final bool reuse;
  final Map<String, String> settings;
  final TaskSchedule schedule;
  bool enabled;
  String? sessionId;
  String? sessionLocation;
  DateTime? nextRun;
  DateTime? lastRun;
  String? error;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'kernel': kernel,
    'project': project,
    'settings': settings,
    'schedule': schedule.toJson(),
    'worktree': worktree,
    'newWorktree': newWorktree,
    'reuse': reuse,
    'enabled': enabled,
    'sessionId': sessionId,
    'sessionLocation': sessionLocation,
    'nextRun': nextRun?.toIso8601String(),
    'lastRun': lastRun?.toIso8601String(),
    'error': error,
  };

  static ScheduledTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final schedule = TaskSchedule.fromJson(raw['schedule']);
    if (raw['id'] is! String ||
        raw['name'] is! String ||
        raw['prompt'] is! String ||
        raw['kernel'] is! String ||
        raw['project'] is! String ||
        schedule == null) {
      return null;
    }
    final project = raw['project'] as String;
    final prompt = raw['prompt'] as String;
    if (project.isEmpty || prompt.trim().isEmpty) return null;
    String? text(String key) => raw[key] is String ? raw[key] as String : null;
    DateTime? time(String key) => DateTime.tryParse(text(key) ?? '');
    return ScheduledTask(
      id: raw['id'] as String,
      name: raw['name'] as String,
      prompt: prompt,
      kernel: raw['kernel'] as String,
      project: project,
      schedule: schedule,
      settings: {
        if (raw['settings'] case final Map settings)
          for (final entry in settings.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
      },
      worktree: text('worktree'),
      newWorktree: raw['newWorktree'] == true,
      reuse: raw['reuse'] == true,
      enabled: raw['enabled'] != false,
      sessionId: text('sessionId'),
      sessionLocation: text('sessionLocation'),
      nextRun: time('nextRun'),
      lastRun: time('lastRun'),
      error: text('error'),
    );
  }
}
