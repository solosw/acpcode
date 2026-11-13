import 'dart:io';

Future<void> main(List<String> arguments) async {
  final guard = await File(arguments[0]).open(mode: FileMode.append);
  await guard.lock(FileLock.exclusive, 0, 1);
  final index = File(arguments[1]);
  await index.writeAsString('owned by another server');
  await index.setLastModified(
    DateTime.now().subtract(const Duration(minutes: 10)),
  );
  stdout.writeln('locked');
  await stdin.drain<void>();
  // The test kills this owner too: the OS releases the lock in either case.
  exit(0);
}
