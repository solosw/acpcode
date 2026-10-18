import 'dart:io' show exit;

import 'package:flutter/foundation.dart' show debugPrint;

import '../customize/customization_store.dart';
import '../platform/data_dir.dart';
import 'tools_bridge.dart';
import 'tools_registration.dart';
import 'tools_stdio.dart' as stdio;

export 'tools_stdio.dart' show runsToolsStdio;

Future<Never> runToolsStdio(List<String> arguments) async {
  // Returning from Dart main leaves AppKit's loop running.
  exit(await stdio.runToolsStdio(arguments));
}

/// Start after the data directory is resolved, before an agent can open.
Future<void> startToolsBridge() async {
  await ToolsBridge.instance.start();
  if (ToolsBridge.instance.address == null) return;
  try {
    await registerBaocodeTools(
      store: CustomizationStore(),
      command: stdio.toolsServerCommand,
      dataDirectory: DataDirectory.current.path,
    );
  } on Object catch (error) {
    // Invalid or unreadable user configuration is never overwritten.
    debugPrint('Could not register the user-level BaoCode MCP: $error');
  }
}
