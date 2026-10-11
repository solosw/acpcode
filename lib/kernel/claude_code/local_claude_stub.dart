import 'claude_path_setting.dart';

/// No Claude Code on the web.
abstract final class LocalClaude {
  static Future<LocalClaudeStatus?> status() async => null;
}
