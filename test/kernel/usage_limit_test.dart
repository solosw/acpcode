import 'package:baocode/kernel/claude_code/usage_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 14:02 local, as the error below was said (06:02Z in Shanghai).
  final now = DateTime(2026, 10, 13, 14, 2);

  DateTime? parse(String text, {String? zone = 'Asia/Shanghai'}) =>
      parseUsageLimitReset(text, now: now, localZone: zone);

  test('the time Claude Code says the session limit resets at', () {
    expect(
      parse("You've hit your session limit · resets 4:30pm (Asia/Shanghai)"),
      DateTime(2026, 10, 13, 16, 30),
    );
    expect(
      parse("You've hit your session limit · resets 6pm (Asia/Shanghai)"),
      DateTime(2026, 10, 13, 18),
    );
  });

  test('a time already past today is tomorrow\'s', () {
    expect(
      parse("You've hit your session limit · resets 3:50am (Asia/Shanghai)"),
      DateTime(2026, 10, 14, 3, 50),
    );
    expect(
      parse("You've hit your session limit · resets 12pm (Asia/Shanghai)"),
      DateTime(2026, 10, 14, 12),
    );
  });

  test('a date said is taken', () {
    expect(
      parse(
        "You've hit your weekly limit · resets Oct 16, 9am (Asia/Shanghai)",
      ),
      DateTime(2026, 10, 16, 9),
    );
    // In December, January's is next year's.
    expect(
      parseUsageLimitReset(
        'resets Jan 2, 9am',
        now: DateTime(2026, 12, 30, 10),
      ),
      DateTime(2027, 1, 2, 9),
    );
  });

  test('a time in another zone than this machine\'s is not known', () {
    expect(
      parse("You've hit your session limit · resets 4:30pm (America/New_York)"),
      isNull,
    );
    // This machine's zone not known: taken as its own.
    expect(
      parse('resets 4:30pm (America/New_York)', zone: null),
      DateTime(2026, 10, 13, 16, 30),
    );
    // None said: this machine's.
    expect(parse('resets 4:30pm'), DateTime(2026, 10, 13, 16, 30));
  });

  test('the older form, with the time it resets at in seconds', () {
    expect(
      parse('Claude AI usage limit reached|1760000000'),
      DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
    );
  });

  test('other errors say no reset', () {
    expect(
      parse(
        'API Error: Request rejected (429) · WorkBuddy AI: usage exceeds '
        "frequency limit, but don't worry, your usage will reset at "
        '2026-10-21 11:50:34 UTC+8',
      ),
      isNull,
    );
    expect(parse('API Error: 500 Internal Server Error'), isNull);
    expect(parse(''), isNull);
  });
}
