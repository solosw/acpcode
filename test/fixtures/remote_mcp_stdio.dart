import 'dart:io';

import 'package:bao_remote/server.dart';

Future<void> main() async {
  exit(
    await ServerMcp.runStdio(drainTimeout: const Duration(milliseconds: 200)),
  );
}
