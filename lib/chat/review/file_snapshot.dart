import '../../kernel/kernel_event.dart';
import 'file_snapshot_stub.dart'
    if (dart.library.io) 'file_snapshot_io.dart'
    as platform;

/// Called synchronously at event delivery, never when replaying a queue.
FileSnapshot snapshotFile(String path) => platform.snapshotFile(path);
