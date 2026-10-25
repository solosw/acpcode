import 'package:path/path.dart' as p;

import 'customization_disk_stub.dart'
    if (dart.library.io) 'customization_disk_io.dart'
    as platform;

/// The files Claude Code's customizations are kept in: this machine's, or
/// those of a remote host, where its agents run.
abstract interface class CustomizationDisk {
  /// This machine's; null where there are no files (the web).
  static CustomizationDisk? get local => platform.localCustomizationDisk();

  /// Whether these are this machine's files (shown in its file manager,
  /// opened in its IDE).
  bool get isLocal;

  /// How paths are spelled there.
  p.Context get paths;

  /// Claude Code's config folder there (`~/.claude` unless moved).
  Future<String> configDir();

  /// The user's home there; null where none is known.
  Future<String?> homeDir();

  /// [path]'s text; null for none, or one that cannot be read.
  Future<String?> read(String path);

  /// The files and folders in [directory], links followed; none for no
  /// such folder.
  Future<List<({String path, bool directory})>> children(String directory);

  /// Whether [path] is a folder (true) or a file (false); null where
  /// nothing is.
  Future<bool?> isDirectory(String path);

  /// Writes [text] to [path], making its folders.
  Future<void> write(String path, String text);

  /// Deletes [path], a folder with its contents.
  Future<void> delete(String path);
}

/// File information for copying without following symbolic links.
enum CustomizationFileType { file, directory, link, other }

typedef CustomizationFileInfo = ({CustomizationFileType type, bool executable});

/// Optional strict, binary-safe operations for managed directory copies.
/// Unlike the browsing API, errors must not be treated as missing files.
abstract interface class CustomizationCopyDisk implements CustomizationDisk {
  Future<CustomizationFileInfo?> inspect(String path);
  Future<List<String>> copyEntries(String directory);

  /// Resolves existing ancestors too, when the final path does not exist yet.
  Future<String> resolveCopyPath(String path);
  Future<List<int>> readCopyBytes(String path);
  Future<void> createCopyDirectory(String path);

  /// Replaces a file atomically, with owner-only read/write and, if needed,
  /// execute permissions. Callers check conflicts immediately before writing.
  Future<void> writeCopyBytes(
    String path,
    List<int> bytes, {
    required bool executable,
  });
}

/// Disks which can replace a configuration without exposing partial writes.
abstract interface class AtomicCustomizationDisk implements CustomizationDisk {
  Future<void> writeAtomically(String path, String text);
}
