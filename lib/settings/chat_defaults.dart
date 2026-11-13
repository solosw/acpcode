import 'user_settings.dart';

/// Explicit defaults for new conversations, over the last choices made.
abstract final class ChatDefaults {
  static const agentKey = 'chat.defaultAgent';
  static const modesKey = 'chat.defaultModes';

  static String? agent(UserSettings? settings) => switch (settings?[agentKey]) {
    final String id when id.isNotEmpty => id,
    _ => null,
  };

  /// Modes belong to their agent: ACP agents can offer different mode ids.
  static Map<String, String> modes(UserSettings? settings) => {
    if (settings?[modesKey] case final Map values)
      for (final MapEntry(:key, :value) in values.entries)
        if (key is String && value is String && value.isNotEmpty) key: value,
  };
}
