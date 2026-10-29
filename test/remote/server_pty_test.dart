@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:bao_remote/src/server/server_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory project;
  late String root;
  late RpcPeer serverPeer;
  late RemoteClient client;
  late ServerPty server;
  late Completer<void> entered;
  late Completer<String?> environmentReady;

  setUp(() {
    project = Directory.systemTemp.createTempSync('baocode-server-pty-');
    root = project.resolveSymbolicLinksSync();
    final toServer = StreamController<String>();
    final toClient = StreamController<String>();
    serverPeer = RpcPeer(toServer.stream, toClient.add);
    client = RemoteClient(RpcPeer(toClient.stream, toServer.add));
    entered = Completer<void>();
    environmentReady = Completer<String?>();
    server = ServerPty(
      serverPeer,
      claudeDirectory: () {
        entered.complete();
        return environmentReady.future;
      },
    );
    addTearDown(() async {
      if (!environmentReady.isCompleted) environmentReady.complete(null);
      await server.stopAll();
      client.peer.close();
      serverPeer.close();
      await toServer.close();
      await toClient.close();
      project.deleteSync(recursive: true);
    });
  });

  test(
    'shutdown while terminal setup awaits cannot start a late command',
    () async {
      final marker = File(p.join(root, 'late-start'));
      final launch = client.startPty(
        cwd: root,
        shell: ['/bin/sh', '-c', 'touch "${marker.path}"'],
        shellIntegration: false,
        workspaceRoots: [root],
      );
      final failed = expectLater(
        launch,
        throwsA(
          isA<RemoteException>().having(
            (error) => error.toString(),
            'message',
            contains('connection to the remote host closed'),
          ),
        ),
      );
      await entered.future;
      await server.stopAll();
      environmentReady.complete(null);
      await failed;
      expect(marker.existsSync(), isFalse);
    },
  );

  test(
    'server checks approved cwd after asynchronous terminal setup',
    () async {
      final cwd = Directory(p.join(root, 'cwd'))..createSync();
      final target = Directory(p.join(root, 'target'))..createSync();
      final marker = File(p.join(root, 'redirected'));
      final launch = client.startPty(
        cwd: cwd.path,
        shell: ['/bin/sh', '-c', 'touch "${marker.path}"'],
        shellIntegration: false,
        workspaceRoots: [root],
      );
      final failed = expectLater(
        launch,
        throwsA(
          predicate(
            (Object? error) => '$error'.contains('changed after approval'),
          ),
        ),
      );
      await entered.future;
      cwd.deleteSync();
      Link(cwd.path).createSync(target.path);
      environmentReady.complete(null);
      await failed;
      expect(marker.existsSync(), isFalse);
    },
  );
}
