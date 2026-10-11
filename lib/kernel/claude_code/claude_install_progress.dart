import 'package:flutter/foundation.dart';

/// How far installing Claude Code is: [received] bytes of [size];
/// [uploading] once it is sent from here to a host unable to download it.
class ClaudeInstallProgress {
  const ClaudeInstallProgress(
    this.received,
    this.size, {
    this.uploading = false,
  });

  final int received;
  final int? size;
  final bool uploading;

  /// From 0 to 1; null while the size is not known.
  double? get fraction => switch (size) {
    final size? when size > 0 => (received / size).clamp(0, 1).toDouble(),
    _ => null,
  };
}

/// Claude Code being downloaded for this machine, the user having none
/// that runs (see LocalClaude): its progress, null otherwise.
class LocalClaudeInstall extends ChangeNotifier {
  LocalClaudeInstall._();

  static final instance = LocalClaudeInstall._();

  ClaudeInstallProgress? get progress => _progress;
  ClaudeInstallProgress? _progress;

  /// Told only as the whole percent changes, not for every piece.
  set progress(ClaudeInstallProgress? progress) {
    final before = _percent(_progress);
    _progress = progress;
    if ((progress == null) != (before == null) ||
        _percent(progress) != before) {
      notifyListeners();
    }
  }

  static int? _percent(ClaudeInstallProgress? progress) => switch (progress) {
    null => null,
    _ => ((progress.fraction ?? 0) * 100).floor(),
  };
}
