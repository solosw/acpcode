/// Validated, immutable process arguments shown to the user before execution.
class AcpTerminalCommand {
  AcpTerminalCommand(
    this.command,
    List<String> args,
    this.cwd,
    Map<String, String> env,
    this.outputByteLimit, {
    this.host,
  }) : args = List.unmodifiable(args),
       env = Map.unmodifiable(env);

  final String command;
  final List<String> args;
  final String cwd;
  final Map<String, String> env;
  final int outputByteLimit;

  /// The execution host shown in approvals; null for this computer.
  final String? host;

  Map<String, Object?> get input => {
    'host': ?host,
    'command': command,
    'args': args,
    'cwd': cwd,
    'env': [
      for (final e in env.entries) {'name': e.key, 'value': e.value},
    ],
    'outputByteLimit': outputByteLimit,
  };
}

class AcpTerminalSnapshot {
  const AcpTerminalSnapshot({
    required this.id,
    required this.sessionId,
    required this.command,
    required this.startedAt,
    required this.output,
    this.truncated = false,
    this.exitStatus,
    this.released = false,
  });

  final String id;
  final String sessionId;
  final AcpTerminalCommand command;
  final DateTime startedAt;

  /// Plain output: terminal control sequences are neutralized at capture time.
  final String output;
  final bool truncated;
  final Map<String, Object?>? exitStatus;
  final bool released;

  Map<String, Object?> get result => {
    'output': output,
    'truncated': truncated,
    'exitStatus': ?exitStatus,
  };
}

class AcpTerminalError implements Exception {
  const AcpTerminalError(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => message;
}

abstract interface class AcpTerminalHost {
  bool get hasRunning;
  Future<AcpTerminalCommand> validate(Map<String, Object?> params);
  Future<String> create(
    String sessionId,
    AcpTerminalCommand command, {
    required bool Function() canStart,
  });
  AcpTerminalSnapshot lookup(String sessionId, String id);
  Future<Map<String, Object?>> wait(String sessionId, String id);
  Future<void> kill(String sessionId, String id);
  Future<void> release(String sessionId, String id);
  Future<void> close();
}
