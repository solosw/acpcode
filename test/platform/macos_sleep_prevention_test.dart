@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native sleep prevention keeps system/display awake, refreshes in the '
      'background and releases on disable or failure', () async {
    final source = File('macos/Runner/MainFlutterWindow.swift')
        .readAsStringSync();
    final start = source.indexOf('final class SleepPreventionController {');
    final end = source.indexOf('\n/// The main window:', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final controller = source
        .substring(start, end)
        .replaceAll('IOPMAssertionCreateWithName(', 'createAssertion(')
        .replaceAll('IOPMAssertionRelease(', 'releaseAssertion(')
        .replaceAll('IOPMAssertionDeclareUserActivity(', 'mockDeclareActivity(')
        .replaceAll('ProcessInfo.processInfo', 'Activities.shared');
    final temp = Directory.systemTemp.createTempSync('baocode-sleep-native-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final swift = File('${temp.path}/sleep.swift')
      ..writeAsStringSync('''
import Foundation
import IOKit.pwr_mgt

var active: Set<IOPMAssertionID> = []
var nextID: IOPMAssertionID = 1
var creations = 0
var declarations = 0
var failCreate = 0
var failActivity = false
var types: [String] = []

final class Activities {
  static let shared = Activities()
  var active = 0
  func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
    precondition(options.contains(.userInitiated))
    precondition(options.contains(.idleDisplaySleepDisabled))
    active += 1
    return NSObject()
  }
  func endActivity(_ activity: NSObjectProtocol) { active -= 1 }
}

func createAssertion(_ type: CFString, _ level: IOPMAssertionLevel,
                     _ name: CFString, _ id: UnsafeMutablePointer<IOPMAssertionID>) -> IOReturn {
  creations += 1
  if creations == failCreate { return kIOReturnError }
  precondition(level == kIOPMAssertionLevelOn)
  types.append(type as String)
  id.pointee = nextID
  active.insert(nextID)
  nextID += 1
  return kIOReturnSuccess
}

func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
  precondition(active.remove(id) != nil, "assertion released twice")
  return kIOReturnSuccess
}

func mockDeclareActivity(_ name: CFString, _ type: IOPMUserActiveType,
                     _ id: UnsafeMutablePointer<IOPMAssertionID>) -> IOReturn {
  declarations += 1
  precondition(type == kIOPMUserActiveLocal)
  if failActivity { return kIOReturnError }
  if id.pointee == kIOPMNullAssertionID {
    id.pointee = nextID
    active.insert(nextID)
    nextID += 1
  } else {
    precondition(active.contains(id.pointee), "heartbeat must reuse its assertion")
  }
  return kIOReturnSuccess
}

$controller

func waitForHeartbeat() {
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
}
func checkStopped() {
  precondition(active.isEmpty)
  precondition(Activities.shared.active == 0)
  let count = declarations
  waitForHeartbeat()
  precondition(declarations == count, "disabled heartbeat must not run")
}

let sleep = SleepPreventionController(activityInterval: 0.01)
try sleep.setEnabled(false)
try sleep.setEnabled(true)
precondition(Set(types) == Set([kIOPMAssertionTypePreventUserIdleSystemSleep,
                               kIOPMAssertionTypePreventUserIdleDisplaySleep]))
precondition(active.count == 3 && declarations == 1)
try sleep.setEnabled(true)
precondition(creations == 2 && active.count == 3)
waitForHeartbeat()
precondition(declarations > 1 && active.count == 3)
try sleep.setEnabled(false)
try sleep.setEnabled(false)
checkStopped()

// A display assertion failure must roll back the system assertion too.
failCreate = creations + 2
do {
  try sleep.setEnabled(true)
  fatalError("expected assertion failure")
} catch {}
checkStopped()
failCreate = 0

// Failure of the initial user-activity declaration also releases every resource.
failActivity = true
do {
  try sleep.setEnabled(true)
  fatalError("expected activity failure")
} catch {}
checkStopped()
failActivity = false

// A later heartbeat failure retains the persistent assertions and retries.
try sleep.setEnabled(true)
failActivity = true
waitForHeartbeat()
precondition(active.count == 3 && Activities.shared.active == 1)
failActivity = false
let count = declarations
waitForHeartbeat()
precondition(declarations > count)
try sleep.setEnabled(false)
checkStopped()

var temporary: SleepPreventionController? = SleepPreventionController(activityInterval: 0.01)
try temporary!.setEnabled(true)
temporary = nil
checkStopped()
print("native sleep prevention passed")
''');
    final binary = '${temp.path}/sleep';
    final compiled = await Process.run(
      'xcrun',
      ['swiftc', swift.path, '-o', binary],
      environment: {'TMPDIR': temp.path},
    );
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
    if (compiled.exitCode != 0) return;
    final result = await Process.run(binary, []);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('native sleep prevention passed'));
  });
}
