// Inspect only the MCP child under test, never other applications' titles.
import AppKit
import CoreGraphics
import Foundation

let pid = pid_t(CommandLine.arguments[1])!
var maxVisibleWindows = 0
var policies = Set<Int>()
let deadline = Date().addingTimeInterval(1.5)
repeat {
  if let app = NSRunningApplication(processIdentifier: pid) {
    policies.insert(app.activationPolicy.rawValue)
  }
  let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
  ) as? [[String: Any]] ?? []
  let count = windows.filter {
    ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
  }.count
  maxVisibleWindows = max(maxVisibleWindows, count)
  Thread.sleep(forTimeInterval: 0.05)
} while Date() < deadline
let json = try JSONSerialization.data(withJSONObject: [
  "maxVisibleWindows": maxVisibleWindows,
  "activationPolicies": policies.sorted(),
])
print(String(data: json, encoding: .utf8)!)
