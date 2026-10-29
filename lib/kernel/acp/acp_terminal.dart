import 'acp_terminal_stub.dart'
    if (dart.library.io) 'acp_terminal_io.dart'
    as platform;
import 'acp_terminal_types.dart';

export 'acp_terminal_types.dart';

AcpTerminalHost? createAcpTerminalHost(
  List<String> roots,
  void Function(AcpTerminalSnapshot) onChanged,
) => platform.createAcpTerminalHost(roots, onChanged);
