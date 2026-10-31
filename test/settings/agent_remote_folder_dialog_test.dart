import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/settings/pages/agent_remote_folder_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

void main() {
  testWidgets(
    'browses remote directories, navigates parent and selects current folder',
    (tester) async {
      final harness = await tester.runAsync(RemoteHarness.start);
      final server = harness!;
      addTearDown(() async {
        await server.close();
      });
      final root = server.dataDir.resolveSymbolicLinksSync();
      await tester.runAsync(() async {
        await Directory(p.join(root, 'skills')).create();
        await File(p.join(root, 'not-a-directory')).writeAsString('file');
      });
      final hello = server.client.hello!;
      server.client.hello = RemoteHello(
        protocol: hello.protocol,
        version: hello.version,
        platform: hello.platform,
        pid: hello.pid,
        home: root,
        dataDir: hello.dataDir,
      );
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: IdeButton(
                label: 'Browse',
                onPressed: () async {
                  selected = await showDialog<String>(
                    context: context,
                    builder: (_) => AgentRemoteFolderDialog(
                      host: 'dev',
                      connect: () async => server.client,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      Future<void> waitFor(String text) async {
        await tester.runAsync(() async {
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump(const Duration(milliseconds: 20));
            if (find.text(text).evaluate().isNotEmpty &&
                find.byType(LinearProgressIndicator).evaluate().isEmpty) {
              return;
            }
          }
          fail('Remote folder did not load: $text');
        });
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Browse'));
      await waitFor('skills');
      expect(find.text('not-a-directory'), findsNothing);
      await tester.tap(find.text('skills'));
      await waitFor(p.join(root, 'skills'));
      await tester.tap(find.text('..'));
      await waitFor('skills');
      await tester.tap(find.text('skills'));
      await waitFor(p.join(root, 'skills'));
      await tester.tap(find.text('Select this folder'));
      await tester.pumpAndSettle();
      expect(selected, p.join(root, 'skills'));
    },
  );

  testWidgets(
    'connection errors can retry and never select an unloaded directory',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AgentRemoteFolderDialog(
            host: 'dev',
            connect: () async {
              attempts++;
              throw StateError('Connection lost');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Connection lost'), findsOneWidget);
      expect(
        tester
            .widget<IdeButton>(
              find.widgetWithText(IdeButton, 'Select this folder'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
    },
  );
}
