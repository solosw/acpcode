import 'dart:io';

/// This machine's time zone by its IANA name (`Asia/Shanghai`), as Claude
/// Code names it in a reset time; null where it is not found (Windows).
String? localTimeZone() => _localZone ??= _readLocalZone();
String? _localZone;

String? _readLocalZone() {
  if (Platform.environment['TZ'] case final tz? when tz.contains('/')) {
    return tz.startsWith(':') ? tz.substring(1) : tz;
  }
  if (Platform.isWindows) return null;
  try {
    final target = Link('/etc/localtime').targetSync();
    const marker = 'zoneinfo/';
    final at = target.indexOf(marker);
    if (at >= 0) return target.substring(at + marker.length);
  } on FileSystemException {
    // Not a link: the zone is not known by name.
  }
  try {
    final zone = File('/etc/timezone').readAsStringSync().trim();
    if (zone.isNotEmpty) return zone;
  } on FileSystemException {
    // Neither.
  }
  return null;
}
