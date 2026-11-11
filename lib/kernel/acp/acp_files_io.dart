import 'dart:io';

import '../../ide/file_service.dart';
import '../../remote/remote_location.dart';
import '../../remote/remote_services.dart';
import '../../remote/ssh_host.dart';

IdeFileService? createAcpFileService(String location) {
  final root = RemoteLocation.pathOf(location);
  if (!RemoteLocation.pathsOf(location).isAbsolute(root)) return null;
  final host = RemoteLocation.hostOf(location);
  return host == null
      ? IdeFileService(root)
      : RemoteIdeFileService(SshHosts.instance[host], root);
}

Future<String> resolveAcpFilePath(String location, String path) async {
  final host = RemoteLocation.hostOf(location);
  try {
    return host == null
        ? await File(path).resolveSymbolicLinks()
        : await (await SshHosts.instance[host].ready).realPath(path);
  } on PathNotFoundException {
    // New files still resolve existing parent links, keeping their key stable.
  } on IdeFileNotFoundException {
    // The remote host has no file there yet.
  }
  final paths = RemoteLocation.pathsOf(location);
  final parent = paths.dirname(path);
  if (paths.equals(parent, path)) return path;
  return paths.join(
    await resolveAcpFilePath(location, parent),
    paths.basename(path),
  );
}
