import 'package:baocode/forge/forge_accounts.dart';
import 'package:baocode/forge/forge_api.dart';
import 'package:baocode/forge/forge_ref.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_forge.dart';
import 'package:baocode/stash/stash_note.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import '../forge/forge_test.dart' show FakeForgeHttp;

const origin = 'http://git.example:3000';
const issueUrl = '$origin/o/r/issues/3';
const repo = ForgeRepo(kind: ForgeKind.gitea, host: origin, path: 'o/r');

void main() {
  late FakeForgeHttp http;
  late ForgeAccounts accounts;
  late StashStore store;
  late StashForge forge;
  late Map<String, Object?> remote;

  setUp(() async {
    remote = {
      'id': 3,
      'number': 3,
      'title': 'Issue',
      'body': 'Remote body',
      'state': 'open',
      'user': {'login': 'leo'},
    };
    http = FakeForgeHttp()
      ..on('GET', '$origin/api/v1/user', (_) => {'login': 'leo'})
      ..on(
        'GET',
        '$origin/api/v1/repos/o/r/issues',
        (r) => r.url.queryParameters['page'] == '1' ? [remote] : [],
      )
      ..on('GET', '$origin/api/v1/repos/o/r/issues/3', (_) => remote)
      ..on('GET', '$origin/api/v1/repos/o/r/issues/3/comments', (_) => [])
      ..on('POST', '$origin/api/v1/repos/o/r/issues', (r) {
        remote = {...remote, ...(r.json as Map<String, Object?>)};
        return remote;
      })
      ..on('PATCH', '$origin/api/v1/repos/o/r/issues/3', (r) {
        remote = {...remote, ...(r.json as Map<String, Object?>)};
        return remote;
      })
      ..on('POST', '$origin/api/v1/repos/o/r/issues/3/comments', (_) => {});
    accounts = ForgeAccounts(http: http, secrets: MemorySecretStore());
    await accounts.signInWithToken(ForgeKind.gitea, origin, 'token');
    store = StashStore(MemoryStashDisk());
    await store.load();
    forge = StashForge(
      store: store,
      workspace: Workspace.mock(),
      accounts: accounts,
      remotes: (folder) async => folder == '~/code/baocode'
          ? ['ssh://git@git.example:2222/o/r.git']
          : [],
    );
  });

  tearDown(() {
    forge.dispose();
    accounts.dispose();
  });

  test(
    'HTTP Gitea sync imports once and tracks remote edits and closure',
    () async {
      expect((await forge.repositories()).single.repo, repo);
      await forge.sync();
      final note = forge.stashOf(issueUrl)!;
      expect(note.body, 'Remote body');
      expect(note.project, '~/code/baocode');
      expect(http.requests.where((r) => r.method != 'GET'), isEmpty);
      remote = {...remote, 'body': 'Changed remotely', 'state': 'closed'};
      await forge.sync();
      expect(store.notes, hasLength(1));
      expect(store.byId(note.id)!.body, 'Changed remotely');
      expect(store.byId(note.id)!.status, StashStatus.done);
    },
  );

  test('publish, edit, comment and close keep the HTTP instance', () async {
    final note = await store.create(body: 'Text only');
    await forge.publish(note.id, repo);
    expect(store.byId(note.id)!.ownIssue, issueUrl);
    await store.update(note.id, (n) => n.body = 'Edited here');
    await forge.pushEdits(note.id);
    expect(remote['body'], 'Edited here');
    await forge.write(note.id, issueUrl, text: 'Done', close: true);
    expect(remote['state'], 'closed');
    final sent = http.requests.where((r) => r.method != 'GET').toList();
    expect(sent.map((r) => r.method), ['POST', 'PATCH', 'POST', 'PATCH']);
    expect(sent.every((r) => r.url.origin == origin), isTrue);
    expect(sent[2].json, {'body': 'Done'});
  });

  test('remote image links stay intact without an upload', () async {
    final note = await store.create(
      body: '![Remote](https://images.example/a.png)',
    );
    await forge.publish(note.id, repo);
    expect(remote['body'], '![Remote](https://images.example/a.png)');
    expect(http.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  test('local images fail explicitly before any remote write', () async {
    final note = await store.create(body: '![Local](assets/a.png)');
    await expectLater(
      forge.publish(note.id, repo),
      throwsA(isA<ForgeException>()),
    );
    expect(http.requests.where((r) => r.method != 'GET'), isEmpty);
    expect(store.byId(note.id)!.ownIssue, isNull);
    expect(store.byId(note.id)!.body, '![Local](assets/a.png)');
  });

  test('sign-out prevents publishing with a stale instance', () async {
    final note = await store.create(body: 'Text');
    await accounts.signOut(origin);
    await expectLater(
      forge.publish(note.id, repo),
      throwsA(isA<ForgeException>().having((e) => e.status, 'status', 401)),
    );
    expect(http.requests.where((r) => r.method != 'GET'), isEmpty);
  });
}
