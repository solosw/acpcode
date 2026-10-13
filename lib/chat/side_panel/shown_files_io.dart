import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';

/// [bytes] as `<data>/cache/shown/<their hash>/<name>`: written once, the
/// same again kept as it was.
String? writeShown(List<int> bytes, String name) {
  final hash = sha256.convert(bytes).toString().substring(0, 16);
  final file = File(
    p.join(DataDirectory.current.cacheDir, 'shown', hash, name),
  );
  try {
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
    }
    return file.path;
  } on FileSystemException {
    return null;
  }
}
