// The web: no agents' processes to serve the app's tools to.
bool runsToolsStdio(List<String> arguments) => false;

Future<void> runToolsStdio(List<String> arguments) async {}

Future<void> startToolsBridge() async {}
