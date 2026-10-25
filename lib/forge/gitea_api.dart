part of 'forge_api.dart';

/// Gitea's REST API. [host] is an explicit HTTP(S) origin, including its
/// Web port; it must never be inferred from an SSH port.
class GiteaApi extends ForgeApi {
  GiteaApi({required super.host, required super.http, required super.token});

  @override
  ForgeKind get kind => ForgeKind.gitea;

  @override
  Uri get _base => Uri.parse(giteaOrigin(host)).replace(path: '/api/v1');

  @override
  Map<String, String> _headers(String token) => {
    'Authorization': 'token $token',
    'Accept': 'application/json',
  };

  @override
  Future<ForgeUser> me() async {
    final json = await _call('GET', '/user') as Map;
    return ForgeUser(
      login: json['login'] as String,
      name: json['full_name'] as String?,
    );
  }

  // Do not assume the instance's page-size cap equals our requested limit.
  Future<List<Map>> _pages(
    String path, {
    Map<String, String> query = const {},
    int most = 1000,
  }) async {
    final items = <Map>[];
    final seen = <Object?>{};
    for (var page = 1; items.length < most; page++) {
      final json = await _call(
        'GET',
        path,
        query: {...query, 'limit': '50', 'page': '$page'},
      ) as List;
      var added = false;
      for (final item in json.whereType<Map>()) {
        if (seen.add(item['id'] ?? item['number'])) {
          items.add(item);
          added = true;
        }
      }
      if (!added) break;
    }
    return items.take(most).toList();
  }

  @override
  Future<ForgeItem> item(ForgeRef ref) async {
    final repo = '/repos/${ref.repo.path}';
    if (ref.kind == ForgeItemKind.issue) {
      final json = await _call('GET', '$repo/issues/${ref.number}') as Map;
      if (json['pull_request'] != null) {
        return item(
          ForgeRef(
            repo: ref.repo,
            kind: ForgeItemKind.pull,
            number: ref.number,
          ),
        );
      }
      return _item(ref.repo, json);
    }
    final json = await _call('GET', '$repo/pulls/${ref.number}') as Map;
    final sha = (json['head'] as Map?)?['sha'] as String?;
    return _item(
      ref.repo,
      json,
      pull: true,
      checks: sha == null ? null : await _checks(repo, sha),
      review: await _review(repo, ref.number),
    );
  }

  Future<ForgeChecks?> _checks(String repo, String sha) async {
    try {
      final json = await _call('GET', '$repo/commits/$sha/status') as Map;
      if ((json['total_count'] as num? ?? 0) == 0) return null;
      return switch (json['state']) {
        'success' => ForgeChecks.success,
        'failure' || 'error' => ForgeChecks.failure,
        'pending' => ForgeChecks.pending,
        _ => null,
      };
    } on ForgeException {
      return null;
    }
  }

  Future<ForgeReview?> _review(String repo, int number) async {
    try {
      final reviews = await _pages('$repo/pulls/$number/reviews');
      reviews.sort(
        (a, b) => ((a['id'] as num?) ?? 0).compareTo((b['id'] as num?) ?? 0),
      );
      final latest = <String, String>{};
      for (final review in reviews) {
        final login = (review['user'] as Map?)?['login'] as String?;
        final state = review['state'] as String?;
        if (login == null) continue;
        if (review['dismissed'] == true || state == 'DISMISSED') {
          latest.remove(login);
        } else if (state == 'APPROVED' || state == 'REQUEST_CHANGES') {
          latest[login] = state!;
        }
      }
      if (latest.values.contains('REQUEST_CHANGES')) {
        return ForgeReview.changesRequested;
      }
      return latest.values.contains('APPROVED') ? ForgeReview.approved : null;
    } on ForgeException {
      return null;
    }
  }

  ForgeItem _item(
    ForgeRepo repo,
    Map json, {
    bool pull = false,
    ForgeChecks? checks,
    ForgeReview? review,
  }) => ForgeItem(
    ref: ForgeRef(
      repo: repo,
      kind: pull ? ForgeItemKind.pull : ForgeItemKind.issue,
      number: json['number'] as int,
    ),
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    state: pull && json['merged'] == true
        ? ForgeState.merged
        : json['state'] == 'closed'
        ? ForgeState.closed
        : pull && json['draft'] == true
        ? ForgeState.draft
        : ForgeState.open,
    author: (json['user'] as Map?)?['login'] as String?,
    labels: [
      for (final label in (json['labels'] as List?) ?? const [])
        if (label is Map)
          ForgeLabel(
            label['name'] as String? ?? '',
            color: label['color'] as String?,
          ),
    ],
    assignees: [
      for (final user in (json['assignees'] as List?) ?? const [])
        if (user is Map) ?user['login'] as String?,
    ],
    comments: json['comments'] as int? ?? 0,
    updated: ForgeApi._date(json['updated_at']),
    branch: pull ? ((json['head'] as Map?)?['ref'] as String?) : null,
    checks: checks,
    review: review,
  );

  List<ForgeItem> _issueItems(ForgeRepo repo, List<Map> json) {
    final items = [
      for (final issue in json)
        if (issue['pull_request'] == null) _item(repo, issue),
    ];
    items.sort(
      (a, b) => (b.updated?.millisecondsSinceEpoch ?? 0).compareTo(
        a.updated?.millisecondsSinceEpoch ?? 0,
      ),
    );
    return items;
  }

  @override
  Future<List<ForgeItem>> issues(
    ForgeRepo repo, {
    ForgeIssueFilter filter = ForgeIssueFilter.assigned,
    String query = '',
  }) async {
    final user = filter == ForgeIssueFilter.all ? null : (await me()).login;
    final json = await _pages(
      '/repos/${repo.path}/issues',
      query: {
        'state': 'open',
        'type': 'issues',
        if (query.trim().isNotEmpty) 'q': query.trim(),
        if (filter == ForgeIssueFilter.assigned) 'assigned_by': user!,
        if (filter == ForgeIssueFilter.created) 'created_by': user!,
      },
    );
    return _issueItems(repo, json);
  }

  @override
  Future<List<ForgeItem>> allIssues(
    ForgeRepo repo, {
    DateTime? since,
    int most = 1000,
  }) async {
    final json = await _pages(
      '/repos/${repo.path}/issues',
      most: most,
      query: {
        'state': since == null ? 'open' : 'all',
        'type': 'issues',
        'since': ?since?.toUtc().toIso8601String(),
      },
    );
    return _issueItems(repo, json);
  }

  @override
  Future<void> comment(ForgeRef ref, String body) => _call(
    'POST',
    '/repos/${ref.repo.path}/issues/${ref.number}/comments',
    json: {'body': body},
  );

  @override
  Future<void> close(ForgeRef ref, {bool duplicate = false}) => _call(
    'PATCH',
    '/repos/${ref.repo.path}/issues/${ref.number}',
    json: {'state': 'closed'},
  );

  @override
  Future<List<ForgeComment>> comments(
    ForgeRef ref, {
    int? total,
    int most = 5,
  }) async {
    if (most <= 0) return [];
    final json = await _pages(
      '/repos/${ref.repo.path}/issues/${ref.number}/comments',
      most: math.max(total ?? 1000, most),
    );
    final tail = json.skip(math.max(0, json.length - most));
    return [
      for (final comment in tail)
        ForgeComment(
          author: (comment['user'] as Map?)?['login'] as String? ?? '',
          body: comment['body'] as String? ?? '',
          created: ForgeApi._date(comment['created_at']),
          url: comment['html_url'] as String?,
        ),
    ];
  }

  @override
  Future<ForgeItem> createIssue(
    ForgeRepo repo, {
    required String title,
    required String body,
  }) async {
    final json = await _call(
      'POST',
      '/repos/${repo.path}/issues',
      json: {'title': title, 'body': body},
    ) as Map;
    return _item(repo, json);
  }

  @override
  Future<ForgeItem> editIssue(
    ForgeRef ref, {
    required String title,
    required String body,
  }) async {
    final json = await _call(
      'PATCH',
      '/repos/${ref.repo.path}/issues/${ref.number}',
      json: {'title': title, 'body': body},
    ) as Map;
    return _item(ref.repo, json);
  }

  @override
  Future<String> uploadImage(
    ForgeRepo repo,
    String name,
    List<int> bytes,
  ) async {
    throw const ForgeException(
      'Gitea image upload is not supported yet. Remove local images or use remote image links before publishing.',
    );
  }
}
