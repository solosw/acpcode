import 'dart:io';

import 'package:baocode/forge/forge_accounts.dart';
import 'package:baocode/forge/forge_api.dart';
import 'package:baocode/forge/forge_io.dart';
import 'package:baocode/forge/forge_ref.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/settings/pages/accounts_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'forge_test.dart' show FakeForgeHttp;

class _NativeHttpOverrides extends HttpOverrides {}

const origin = 'http://git.example:3000';
const repo = ForgeRepo(kind: ForgeKind.gitea, host: origin, path: 'o/r');
const ref = ForgeRef(repo: repo, kind: ForgeItemKind.issue, number: 3);
Map<String, Object?> issue(int n, {String state = 'open'}) => {
  'id': n,
  'number': n,
  'title': 'Issue $n',
  'body': 'Description',
  'state': state,
  'user': {'login': 'leo'},
  'labels': [
    {'name': 'bug', 'color': 'ff0000'},
  ],
  'assignees': [
    {'login': 'leo'},
  ],
  'comments': 2,
};

void main() {
  late FakeForgeHttp http;
  late MemorySecretStore secrets;
  late ForgeAccounts accounts;
  late GiteaApi api;
  Object? kept;

  setUp(() {
    kept = null;
    http = FakeForgeHttp()
      ..on(
        'GET',
        '$origin/api/v1/user',
        (r) => r.headers['Authorization'] == 'token good'
            ? {'login': 'leo', 'full_name': 'Leo'}
            : const ForgeResponse(401, '{"message":"Invalid token"}'),
      );
    secrets = MemorySecretStore();
    accounts = ForgeAccounts(
      http: http,
      secrets: secrets,
      read: () => kept,
      write: (json) async => kept = json,
    );
    api = GiteaApi(host: origin, http: http, token: () async => 'good');
    addTearDown(accounts.dispose);
  });

  test(
    'HTTP origin, port and credentials survive account reload and logout',
    () async {
      final account = await accounts.signInWithToken(
        ForgeKind.gitea,
        'HTTP://GIT.EXAMPLE:3000/',
        ' good ',
      );
      expect(account.host, origin);
      expect(account.name, 'Leo');
      expect('$kept', isNot(contains('good')));
      expect(await secrets.read('forge.$origin'), contains('good'));
      final restored = ForgeAccounts(
        http: http,
        secrets: secrets,
        read: () => kept,
      );
      addTearDown(restored.dispose);
      expect((await restored.apiFor(origin)!.me()).login, 'leo');
      expect(restored.originOf('git.example'), origin);
      expect(
        forgeNewTokenPage(ForgeKind.gitea, origin).toString(),
        '$origin/user/settings/applications',
      );
      expect(forgeRevokePage(account).scheme, 'http');
      await accounts.signOut(origin);
      expect(accounts.accounts, isEmpty);
      expect(await secrets.read('forge.$origin'), isNull);
    },
  );

  test('instances on the same host never share credentials', () async {
    const other = 'https://git.example:3443';
    http.on('GET', '$other/api/v1/user', (r) {
      expect(r.headers['Authorization'], 'token other');
      return {'login': 'other'};
    });
    await accounts.signInWithToken(ForgeKind.gitea, origin, 'good');
    await accounts.signInWithToken(ForgeKind.gitea, other, 'other');
    expect(accounts.accounts, hasLength(2));
    expect(accounts.accountFor('git.example'), isNull);
    expect(accounts.originOf('git.example'), isNull);
    expect(accounts.apiFor('http://git.example:3443'), isNull);
    expect(accounts.apiFor('https://git.example:3000'), isNull);
    expect(await secrets.read('forge.$origin'), contains('good'));
    await accounts.signOut(other);
    expect(accounts.accountFor(origin)?.login, 'leo');
    expect(await secrets.read('forge.$other'), isNull);
  });

  test(
    'rejected token leaves the existing account and secret intact',
    () async {
      await accounts.signInWithToken(ForgeKind.gitea, origin, 'good');
      await expectLater(
        accounts.signInWithToken(ForgeKind.gitea, origin, 'bad'),
        throwsA(isA<ForgeException>().having((e) => e.status, 'status', 401)),
      );
      expect(accounts.accountFor(origin)?.login, 'leo');
      expect(await secrets.read('forge.$origin'), contains('good'));
    },
  );

  test('Gitea is token-only and invalid endpoints make no request', () async {
    expect(accounts.canSignInFromBrowser(ForgeKind.gitea, ''), isFalse);
    await expectLater(
      accounts.startDeviceFlow(ForgeKind.gitea),
      throwsA(isA<ForgeException>()),
    );
    for (final address in [
      '',
      'ftp://git.example',
      '$origin/subpath',
      'http://user:pass@git.example',
      '$origin?token=x',
      '$origin#fragment',
    ]) {
      expect(() => giteaOrigin(address), throwsFormatException);
    }
    expect(http.requests, isEmpty);
    expect(giteaOrigin('git.example'), 'https://git.example');
  });

  test('HTTP and SSH remotes resolve to the configured Web instance', () async {
    await accounts.signInWithToken(ForgeKind.gitea, origin, 'good');
    for (final remote in [
      '$origin/o/r.git',
      'git@git.example:o/r.git',
      'ssh://git@git.example:2222/o/r.git',
    ]) {
      final found = ForgeRepo.fromRemote(
        remote,
        kindOf: accounts.kindOf,
        originOf: accounts.originOf,
      );
      expect(found, repo);
      expect(found!.url.toString(), '$origin/o/r');
    }
    expect(
      ForgeRepo.fromRemote(
        'https://git.example:3000/o/r.git',
        kindOf: accounts.kindOf,
        originOf: accounts.originOf,
      ),
      isNull,
    );
    expect(
      ForgeRepo.fromRemote('$origin/group/sub/r.git', kindOf: accounts.kindOf),
      isNull,
    );
  });

  test(
    'issue and PR links keep their scheme and port without GitLab guessing',
    () async {
      await accounts.signInWithToken(ForgeKind.gitea, origin, 'good');
      expect(
        ForgeRef.parse('$origin/o/r/issues/3#comment', kindOf: accounts.kindOf),
        ref,
      );
      final pr = ForgeRef.parse(
        '$origin/o/r/pulls/7/files',
        kindOf: accounts.kindOf,
      )!;
      expect(pr.kind, ForgeItemKind.pull);
      expect(pr.url.toString(), '$origin/o/r/pulls/7');
      expect(
        ForgeRef.parse('$origin/o/r/pull/7', kindOf: accounts.kindOf),
        isNull,
      );
      expect(
        ForgeRef.parse('$origin/o/r/-/issues/7', kindOf: accounts.kindOf),
        isNull,
      );
      expect(
        ForgeRef.parse(
          'https://git.example:3000/o/r/issues/3',
          kindOf: accounts.kindOf,
        ),
        isNull,
      );
    },
  );

  for (final filter in ForgeIssueFilter.values) {
    test('issues use Gitea filters ($filter)', () async {
      http.on('GET', '$origin/api/v1/repos/o/r/issues', (r) {
        final q = r.url.queryParameters;
        expect(q['type'], 'issues');
        expect(q['state'], 'open');
        expect(q['q'], 'fix');
        expect(
          q['assigned_by'],
          filter == ForgeIssueFilter.assigned ? 'leo' : null,
        );
        expect(
          q['created_by'],
          filter == ForgeIssueFilter.created ? 'leo' : null,
        );
        return q['page'] == '1'
            ? [
                issue(3),
                {...issue(7), 'pull_request': {}},
              ]
            : [];
      });
      final items = await api.issues(repo, filter: filter, query: ' fix ');
      expect(items.single.ref, ref);
      expect(items.single.labels.single.name, 'bug');
      expect(items.single.assignees, ['leo']);
    });
  }

  test(
    'incremental issues handle server page-size caps and closed issues',
    () async {
      final since = DateTime.utc(2026, 10, 1);
      http.on('GET', '$origin/api/v1/repos/o/r/issues', (r) {
        expect(r.url.queryParameters['state'], 'all');
        expect(r.url.queryParameters['since'], since.toIso8601String());
        return switch (r.url.queryParameters['page']) {
          '1' => [issue(3)],
          '2' => [issue(4, state: 'closed')],
          _ => [],
        };
      });
      final items = await api.allIssues(repo, since: since);
      expect(items.map((i) => i.ref.number), [3, 4]);
      expect(items.last.state, ForgeState.closed);
      expect(http.requests, hasLength(3));
      expect(await api.allIssues(repo, since: since, most: 0), isEmpty);
    },
  );

  test(
    'issue lists are ordered by last update rather than creation number',
    () async {
      http.on(
        'GET',
        '$origin/api/v1/repos/o/r/issues',
        (r) => r.url.queryParameters['page'] == '1'
            ? [
                {...issue(9), 'updated_at': '2026-10-01T00:00:00Z'},
                {...issue(3), 'updated_at': '2026-10-02T00:00:00Z'},
              ]
            : [],
      );
      expect((await api.allIssues(repo)).map((i) => i.ref.number), [3, 9]);
      expect(
        (await api.issues(
          repo,
          filter: ForgeIssueFilter.all,
        )).map((i) => i.ref.number),
        [3, 9],
      );
    },
  );

  test('repeated server pages terminate without duplicate issues', () async {
    http.on('GET', '$origin/api/v1/repos/o/r/issues', (_) => [issue(3)]);
    expect(await api.allIssues(repo), hasLength(1));
    expect(http.requests, hasLength(2));
  });

  test('issue writes use expected paths and bodies', () async {
    http.on('POST', '$origin/api/v1/repos/o/r/issues', (r) {
      expect(r.json, {'title': 'New', 'body': 'Body'});
      return issue(3);
    });
    http.on('PATCH', '$origin/api/v1/repos/o/r/issues/3', (_) => issue(3));
    http.on('POST', '$origin/api/v1/repos/o/r/issues/3/comments', (_) => {});
    expect((await api.createIssue(repo, title: 'New', body: 'Body')).ref, ref);
    await api.editIssue(ref, title: 'Edit', body: 'Changed');
    await api.comment(ref, 'Comment');
    await api.close(ref, duplicate: true);
    expect(http.requests[1].json, {'title': 'Edit', 'body': 'Changed'});
    expect(http.requests[2].json, {'body': 'Comment'});
    expect(http.requests[3].json, {'state': 'closed'});
  });

  test(
    'latest comments are returned oldest first across capped pages',
    () async {
      http.on('GET', '$origin/api/v1/repos/o/r/issues/3/comments', (r) {
        final page = int.parse(r.url.queryParameters['page']!);
        return page <= 3
            ? [
                {
                  'id': page,
                  'body': 'Comment $page',
                  'user': {'login': 'leo'},
                },
              ]
            : [];
      });
      final comments = await api.comments(ref, total: 3, most: 2);
      expect(comments.map((c) => c.body), ['Comment 2', 'Comment 3']);
    },
  );

  test(
    'pulls report merged state, commit checks and latest reviewer decisions',
    () async {
      http.on(
        'GET',
        '$origin/api/v1/repos/o/r/issues/3',
        (_) => {...issue(3), 'pull_request': {}},
      );
      http.on(
        'GET',
        '$origin/api/v1/repos/o/r/pulls/3',
        (_) => {
          ...issue(3),
          'merged': true,
          'head': {'sha': 'abc', 'ref': 'fix'},
        },
      );
      http.on(
        'GET',
        '$origin/api/v1/repos/o/r/commits/abc/status',
        (_) => {'state': 'failure', 'total_count': 1},
      );
      http.on(
        'GET',
        '$origin/api/v1/repos/o/r/pulls/3/reviews',
        (r) => r.url.queryParameters['page'] == '1'
            ? [
                {
                  'id': 1,
                  'state': 'REQUEST_CHANGES',
                  'user': {'login': 'a'},
                },
                {
                  'id': 2,
                  'state': 'APPROVED',
                  'user': {'login': 'a'},
                },
                {
                  'id': 3,
                  'state': 'REQUEST_CHANGES',
                  'user': {'login': 'b'},
                },
              ]
            : [],
      );
      final item = await api.item(ref);
      expect(item.ref.kind, ForgeItemKind.pull);
      expect(item.ref.url.toString(), '$origin/o/r/pulls/3');
      expect(item.state, ForgeState.merged);
      expect(item.checks, ForgeChecks.failure);
      expect(item.review, ForgeReview.changesRequested);
      expect(item.branch, 'fix');
    },
  );

  test('unavailable checks and reviews remain unknown', () async {
    http.on(
      'GET',
      '$origin/api/v1/repos/o/r/pulls/3',
      (_) => {
        ...issue(3),
        'head': {'sha': 'abc'},
      },
    );
    http.fallback = (_) => const ForgeResponse(403, '{"message":"Forbidden"}');
    final item = await api.item(
      const ForgeRef(repo: repo, kind: ForgeItemKind.pull, number: 3),
    );
    expect(item.checks, isNull);
    expect(item.review, isNull);
    expect(item.state, ForgeState.open);
  });

  test(
    'API errors propagate and image upload is explicit without HTTP',
    () async {
      http.on(
        'POST',
        '$origin/api/v1/repos/o/r/issues',
        (_) => const ForgeResponse(403, '{"message":"Insufficient scope"}'),
      );
      await expectLater(
        api.createIssue(repo, title: 'x', body: ''),
        throwsA(
          isA<ForgeException>().having(
            (e) => e.message,
            'message',
            'Insufficient scope',
          ),
        ),
      );
      http.requests.clear();
      await expectLater(
        api.uploadImage(repo, 'x.png', [1]),
        throwsA(isA<ForgeException>()),
      );
      expect(http.requests, isEmpty);
    },
  );

  test('dismissed reviews and absent checks do not report success', () async {
    http.on(
      'GET',
      '$origin/api/v1/repos/o/r/pulls/3',
      (_) => {
        ...issue(3),
        'draft': true,
        'head': {'sha': 'abc'},
      },
    );
    http.on(
      'GET',
      '$origin/api/v1/repos/o/r/commits/abc/status',
      (_) => {'state': 'success', 'total_count': 0},
    );
    http.on(
      'GET',
      '$origin/api/v1/repos/o/r/pulls/3/reviews',
      (r) => r.url.queryParameters['page'] == '1'
          ? [
              {
                'id': 1,
                'state': 'REQUEST_CHANGES',
                'user': {'login': 'a'},
              },
              {
                'id': 2,
                'state': 'APPROVED',
                'dismissed': true,
                'user': {'login': 'a'},
              },
            ]
          : [],
    );
    final item = await api.item(
      const ForgeRef(repo: repo, kind: ForgeItemKind.pull, number: 3),
    );
    expect(item.state, ForgeState.draft);
    expect(item.review, isNull);
    expect(item.checks, isNull);
  });

  test('non-JSON responses become a recoverable forge error', () async {
    http.on(
      'GET',
      '$origin/api/v1/user',
      (_) => const ForgeResponse(200, '<html>proxy error</html>'),
    );
    await expectLater(api.me(), throwsA(isA<ForgeException>()));
    expect(accounts.accounts, isEmpty);
  });

  test('HTTP transport does not follow credential-bearing redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var redirected = false;
    server.listen((r) async {
      if (r.uri.path == '/redirected') redirected = true;
      r.response.statusCode = 302;
      r.response.headers.set('location', '/redirected');
      await r.response.close();
    });
    final response = await HttpOverrides.runWithHttpOverrides(
      () => IoForgeHttp().send(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/user'),
        headers: {'Authorization': 'token test'},
      ),
      _NativeHttpOverrides(),
    );
    expect(response.status, 302);
    expect(redirected, isFalse);
  });
}
