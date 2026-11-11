import '../../ide/file_service.dart';
import 'acp_files_stub.dart'
    if (dart.library.io) 'acp_files_io.dart'
    as platform;

/// Files on the agent's host, including paths outside its working directory.
IdeFileService? createAcpFileService(String location) =>
    platform.createAcpFileService(location);

/// Resolve an existing file link so checkpoints describe the bytes written.
Future<String> resolveAcpFilePath(String location, String path) =>
    platform.resolveAcpFilePath(location, path);
