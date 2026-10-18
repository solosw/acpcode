import 'package:baocode/ide/ide_quick_input.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/remote/open_remote.dart';
import 'package:baocode/remote/remote_files.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:baocode/remote/ssh_host_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final openFile in [false, true]) {
    group(
      openFile ? 'Open Remote File hosts' : 'Open Remote Project hosts',
      () {
        late SshHostSettings saved;
        late SshHosts hosts;
        late SshHostSettings previous;
        late Future<List<String>> Function() previousConfigHosts;

        setUp(() {
          previous = SshHostSettings.instance;
          previousConfigHosts = OpenRemoteFlow.defaultConfigHosts;
          saved = SshHostSettings(secrets: MemorySecretStore());
          SshHostSettings.instance = saved;
          hosts = SshHosts();
        });
        tearDown(() async {
          SshHostSettings.instance = previous;
          OpenRemoteFlow.defaultConfigHosts = previousConfigHosts;
          saved.dispose();
          await hosts.closeAll();
        });

        Future<IdeQuickPick> pick({
          List<String> added = const [],
          Future<List<String>> Function()? configHosts,
        }) async {
          final shown = <IdeQuickPick>[];
          if (openFile) {
            await OpenRemoteFileFlow(
              show: shown.add,
              l10n: englishLocalizations,
              onOpen: (_) {},
              added: added,
              hosts: hosts,
              configHosts: configHosts,
            ).start();
          } else {
            await OpenRemoteFlow(
              show: shown.add,
              l10n: englishLocalizations,
              onOpen: (_) {},
              added: added,
              hosts: hosts,
              configHosts: configHosts,
            ).start();
          }
          return shown.single;
        }

        List<String> labels(IdeQuickPick pick, [String value = '']) => [
          for (final item
              in pick.itemsFor!(value).whereType<IdeQuickPickItem>())
            item.label,
        ];

        test('saved hosts precede config hosts, without duplicates', () async {
          await saved.save(const [
            SshSavedHost(host: 'saved'),
            SshSavedHost(host: 'shared'),
            SshSavedHost(host: 'saved'),
            SshSavedHost(host: 'workspace'),
          ]);
          final shown = await pick(
            added: ['workspace'],
            configHosts: () async => [
              'config',
              'shared',
              'workspace',
              'config',
            ],
          );
          expect(labels(shown), ['workspace', 'saved', 'shared', 'config']);
          expect(
            labels(shown, 'saved'),
            isNot(contains(englishLocalizations.remoteConnectTo('saved'))),
          );
        });

        test('saved hosts remain when SSH config cannot be read', () async {
          await saved.save(const [
            SshSavedHost(host: 'saved'),
            SshSavedHost(host: 'saved'),
          ]);
          final shown = await pick(
            configHosts: () async => throw StateError('unreadable SSH config'),
          );
          expect(labels(shown), ['saved']);
          expect(
            labels(shown, 'me@box:2222').first,
            englishLocalizations.remoteConnectTo('me@box:2222'),
          );
        });

        test(
          'the shared default config loader also includes saved hosts',
          () async {
            await saved.save(const [SshSavedHost(host: 'saved')]);
            OpenRemoteFlow.defaultConfigHosts = () async => ['config', 'saved'];
            expect(labels(await pick()), ['saved', 'config']);
          },
        );

        test(
          'no saved hosts and unreadable config still allow a typed host',
          () async {
            final shown = await pick(
              configHosts: () async =>
                  throw StateError('unreadable SSH config'),
            );
            expect(labels(shown), [englishLocalizations.remoteNoHosts]);
            final item =
                shown.itemsFor!('me@box:2222').first as IdeQuickPickItem;
            expect(
              item.label,
              englishLocalizations.remoteConnectTo('me@box:2222'),
            );
            expect(item.onAccept, isNotNull);
          },
        );
      },
    );
  }
}
