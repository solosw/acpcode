import 'dart:io';

import 'package:flutter/foundation.dart';

import 'data_dir.dart';

/// Creates the persistent working folder without touching any existing files.
/// If the volume cannot be used, opening another project remains available.
String? prepareDefaultTaskDirectory() {
  try {
    final directory = Directory(DataDirectory.current.tasksDir)
      ..createSync(recursive: true);
    return directory.path;
  } on FileSystemException catch (error) {
    debugPrint('default task directory: $error');
    return null;
  }
}
