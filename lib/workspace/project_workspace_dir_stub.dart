import 'project_workspace.dart';

/// No data directory (the web).
String? workspacesRoot() => null;

ProjectWorkspace restoreWorkspaceDirectory(
  ProjectWorkspace workspace, {
  List<String> previousPaths = const [],
}) => workspace;

void writeWorkspaceDirectory(ProjectWorkspace workspace) {}

bool isFolder(String path) => false;
