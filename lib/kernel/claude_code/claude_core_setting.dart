/// Settings → General → Claude Code: what runs a Claude Code session
/// (`claudeCode.core` in settings.json).
enum ClaudeCore {
  /// BaoCode's own core, written in Dart (package:bao_agent): the same
  /// protocol, files and settings as the CLI, in the app itself.
  builtin,

  /// The Claude Code CLI, as a process.
  cli;

  static const settingKey = 'claudeCode.core';

  /// When the setting is unset, or not one of these.
  static const fallback = builtin;

  static ClaudeCore parse(Object? setting) =>
      values.where((value) => value.name == setting).firstOrNull ?? fallback;

  /// The setting as it is now, read as each session starts; main() points
  /// it at settings.json.
  static ClaudeCore Function() current = () => fallback;
}
