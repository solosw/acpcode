import 'dart:async';

/// Waits for the managed ACP process, escalating only after its grace period.
/// A final timeout is an error, never a claim that the process has exited.
Future<void> stopAcpProcess({
  required Future<int> exitCode,
  required void Function(bool force) kill,
  Duration grace = const Duration(seconds: 2),
  Duration forceWait = const Duration(seconds: 2),
}) async {
  kill(false);
  try {
    await exitCode.timeout(grace);
  } on TimeoutException {
    kill(true);
    await exitCode.timeout(
      forceWait,
      onTimeout: () {
        throw TimeoutException(
          'ACP process did not exit after forced termination.',
          forceWait,
        );
      },
    );
  }
}
