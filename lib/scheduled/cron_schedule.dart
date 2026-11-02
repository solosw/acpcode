/// Five numeric cron fields in local time: minute hour day month weekday.
/// Sunday is 0 or 7. Restricted day-of-month and weekday fields are ORed.
class CronSchedule {
  CronSchedule(String expression) {
    if (expression.length > 256) {
      throw const FormatException('Cron is too long');
    }
    final fields = expression.trim().split(RegExp(r'\s+'));
    if (fields.length != 5) {
      throw const FormatException('Cron requires five fields');
    }
    minutes = _field(fields[0], 0, 59);
    hours = _field(fields[1], 0, 23);
    days = _field(fields[2], 1, 31);
    months = _field(fields[3], 1, 12);
    weekdays = _field(fields[4], 0, 7).map((day) => day % 7).toSet();
    anyDay = fields[2] == '*';
    anyWeekday = fields[4] == '*';
    // Reject impossible dates before they can enter the persistent scheduler.
    nextAfter(DateTime(2000));
  }

  late final Set<int> minutes;
  late final Set<int> hours;
  late final Set<int> days;
  late final Set<int> months;
  late final Set<int> weekdays;
  late final bool anyDay;
  late final bool anyWeekday;

  static Set<int> _field(String field, int min, int max) {
    final values = <int>{};
    int number(String text) {
      final value = RegExp(r'^\d+$').hasMatch(text) ? int.tryParse(text) : null;
      if (value == null || value < min || value > max) {
        throw const FormatException('Cron value out of range');
      }
      return value;
    }

    for (final part in field.split(',')) {
      final pieces = part.split('/');
      if (pieces.length > 2 || pieces.any((piece) => piece.isEmpty)) {
        throw const FormatException('Invalid cron step');
      }
      var step = 1;
      if (pieces.length == 2) {
        final parsed = int.tryParse(pieces[1]);
        if (parsed == null ||
            parsed < 1 ||
            !RegExp(r'^\d+$').hasMatch(pieces[1])) {
          throw const FormatException('Invalid cron step');
        }
        step = parsed;
      }
      final range = pieces[0].split('-');
      final int start;
      final int end;
      if (pieces[0] == '*') {
        start = min;
        end = max;
      } else if (range.length == 2) {
        start = number(range[0]);
        end = number(range[1]);
      } else if (range.length == 1) {
        start = number(range[0]);
        end = pieces.length == 2 ? max : start;
      } else {
        throw const FormatException('Invalid cron range');
      }
      if (start > end) throw const FormatException('Reversed cron range');
      for (var value = start; value <= end; value++) {
        if ((value - start) % step == 0) values.add(value);
      }
    }
    return Set.unmodifiable(values.toList()..sort());
  }

  DateTime nextAfter(DateTime now) {
    // Gregorian dates and weekdays repeat every 400 years. Iterate by date,
    // not by minute, so leap-day schedules and impossible dates stay bounded.
    for (var year = now.year; year <= now.year + 400; year++) {
      for (final month in months) {
        if (year == now.year && month < now.month) continue;
        final lastDay = DateTime.utc(year, month + 1, 0).day;
        for (var day = 1; day <= lastDay; day++) {
          if (year == now.year && month == now.month && day < now.day) continue;
          final weekday = DateTime.utc(year, month, day).weekday % 7;
          final matchesDay = anyDay
              ? weekdays.contains(weekday)
              : anyWeekday
              ? days.contains(day)
              : days.contains(day) || weekdays.contains(weekday);
          if (!matchesDay) continue;
          for (final hour in hours) {
            for (final minute in minutes) {
              final next = DateTime(year, month, day, hour, minute);
              // Do not normalize a nonexistent DST wall time to another hour.
              if (next.year == year &&
                  next.month == month &&
                  next.day == day &&
                  next.hour == hour &&
                  next.minute == minute &&
                  next.isAfter(now)) {
                return next;
              }
            }
          }
        }
      }
    }
    throw const FormatException('Cron has no possible occurrence');
  }
}
