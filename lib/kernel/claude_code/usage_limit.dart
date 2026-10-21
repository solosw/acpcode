/// When the account's usage limit Claude Code reports in [text] resets: as
/// it says it (`You've hit your session limit · resets 4:30pm
/// (Asia/Shanghai)`, a date before the time for a later day), or as it
/// did (`Claude AI usage limit reached|1760000000`). Null for another
/// error, and for a time in a zone other than [localZone] (this machine's,
/// see `localTimeZone`), which is not known here: a remote host's.
///
/// The time is the next one after [now] said so, the day not given.
DateTime? parseUsageLimitReset(
  String text, {
  required DateTime now,
  String? localZone,
}) {
  if (_epoch.firstMatch(text) case final match?) {
    return DateTime.fromMillisecondsSinceEpoch(int.parse(match[1]!) * 1000);
  }
  final match = _resets.firstMatch(text);
  if (match == null) return null;
  final zone = match[6]?.trim();
  if (zone != null && localZone != null && zone != localZone) return null;
  var hour = int.parse(match[3]!) % 12;
  if (match[5]!.toLowerCase() == 'pm') hour += 12;
  final minute = int.parse(match[4] ?? '0');
  final month = switch (match[1]) {
    final name? => _months.indexOf(name.toLowerCase().substring(0, 3)) + 1,
    null => null,
  };
  if (month != null && month > 0) {
    final day = int.parse(match[2]!);
    var at = DateTime(now.year, month, day, hour, minute);
    // Said in December of January's.
    if (at.isBefore(now.subtract(const Duration(days: 1)))) {
      at = DateTime(now.year + 1, month, day, hour, minute);
    }
    return at;
  }
  final today = DateTime(now.year, now.month, now.day, hour, minute);
  return today.isAfter(now)
      ? today
      : DateTime(now.year, now.month, now.day + 1, hour, minute);
}

final _epoch = RegExp(r'limit reached\|(\d{10})\b', caseSensitive: false);

final _resets = RegExp(
  r'resets\s+(?:([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?'
  r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?',
  caseSensitive: false,
);

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];
