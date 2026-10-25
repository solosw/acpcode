// Where code is hosted ("forges": GitHub, GitLab, theirs or one of their
// own), told from links and Git remotes: a repository, and an issue or a
// pull (merge) request in it. Nothing here asks the network.

import 'package:flutter/foundation.dart';

enum ForgeKind {
  github,
  gitlab,
  gitea;

  static ForgeKind? parse(Object? value) =>
      values.where((kind) => kind.name == value).firstOrNull;

  /// What it is called, for the user.
  String get label => switch (this) {
    github => 'GitHub',
    gitlab => 'GitLab',
    gitea => 'Gitea',
  };

  /// Its hosted service's host: the one a token or a sign-in is for when
  /// none is said.
  String get publicHost => switch (this) {
    github => 'github.com',
    gitlab => 'gitlab.com',
    gitea => '',
  };
}

/// What a host is: [ForgeKind.github] for github.com, [ForgeKind.gitlab]
/// for gitlab.com, else as [known] says (an account's on it); null when
/// it cannot be told.
// Gitea lookup accepts a full Web origin, or a bare host for SSH remotes.
typedef ForgeKindOf = ForgeKind? Function(String host);

ForgeKind? publicForgeKind(String host) => switch (host.toLowerCase()) {
  'github.com' || 'www.github.com' => ForgeKind.github,
  'gitlab.com' || 'www.gitlab.com' => ForgeKind.gitlab,
  _ => null,
};

/// Validate a root-deployed Gitea instance, retaining protocol and port.
String giteaOrigin(String typed) {
  final text = typed.trim();
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  if (uri == null ||
      !(uri.isScheme('http') || uri.isScheme('https')) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Enter an HTTP or HTTPS instance address without a subpath, credentials, query or fragment.',
    );
  }
  return uri.replace(host: uri.host.toLowerCase(), path: '').origin;
}

ForgeKind? _webKind(Uri uri, ForgeKindOf? kindOf) {
  final exact = kindOf?.call(uri.origin);
  if (exact != null) return exact;
  final bare = kindOf?.call(uri.host);
  // Never borrow a Gitea token from another protocol or Web port.
  return bare == ForgeKind.gitea ? null : bare ?? publicForgeKind(uri.host);
}

/// A repository: its forge, host and path (`owner/name`; a GitLab one's
/// groups before its name, `group/sub/name`).
@immutable
class ForgeRepo {
  const ForgeRepo({required this.kind, required this.host, required this.path});

  final ForgeKind kind;

  /// A hostname for GitHub/GitLab; a full origin for a Gitea instance.
  final String host;
  final String path;

  /// Its page.
  Uri get url => kind == ForgeKind.gitea
      ? Uri.parse(host).replace(path: '/$path')
      : Uri.https(host, '/$path');

  @override
  String toString() => path;

  @override
  bool operator ==(Object other) =>
      other is ForgeRepo &&
      other.kind == kind &&
      other.host.toLowerCase() == host.toLowerCase() &&
      other.path.toLowerCase() == path.toLowerCase();

  @override
  int get hashCode => Object.hash(kind, host.toLowerCase(), path.toLowerCase());

  /// The repository a Git remote's URL is of (`git@github.com:o/r.git`,
  /// `https://gitlab.com/g/s/r.git`, `ssh://git@host:22/o/r`), on a host
  /// [kindOf] (or [publicForgeKind]) knows; null for none.
  static ForgeRepo? fromRemote(
    String remote, {
    ForgeKindOf? kindOf,
    String? Function(String host)? originOf,
  }) {
    final text = remote.trim();
    final String host;
    String? origin;
    String path;
    // scp-like: user@host:path.
    final scp = RegExp(r'^(?:[^@/\s]+@)?([^:/\s]+):(?!//)(.+)$')
        .firstMatch(text);
    if (scp != null && !text.contains('://')) {
      host = scp[1]!;
      path = scp[2]!;
    } else {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) return null;
      host = uri.host;
      if (uri.isScheme('http') || uri.isScheme('https')) origin = uri.origin;
      path = uri.path;
    }
    path = path.replaceAll(RegExp(r'^/+|/+$'), '');
    if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
    if (path.split('/').where((part) => part.isNotEmpty).length < 2) {
      return null;
    }
    final kind = origin == null
        ? kindOf?.call(host) ?? publicForgeKind(host)
        : _webKind(Uri.parse(origin), kindOf);
    if (kind == null) return null;
    // GitHub and Gitea repositories are owner/name, no more.
    if (kind != ForgeKind.gitlab && path.split('/').length != 2) return null;
    if (kind == ForgeKind.gitea) {
      origin ??= originOf?.call(host);
      if (origin == null) return null;
    }
    return ForgeRepo(
      kind: kind,
      host: kind == ForgeKind.gitea ? origin! : host.toLowerCase(),
      path: path,
    );
  }
}

/// An issue, or a pull request (GitLab's merge request).
enum ForgeItemKind { issue, pull }

/// An issue or a pull request: its repository, its kind and number.
@immutable
class ForgeRef {
  const ForgeRef({
    required this.repo,
    required this.kind,
    required this.number,
  });

  final ForgeRepo repo;
  final ForgeItemKind kind;
  final int number;

  /// Its page.
  Uri get url => switch ((repo.kind, kind)) {
    (ForgeKind.github, ForgeItemKind.issue) => repo.url.replace(
      path: '/${repo.path}/issues/$number',
    ),
    (ForgeKind.github, ForgeItemKind.pull) => repo.url.replace(
      path: '/${repo.path}/pull/$number',
    ),
    (ForgeKind.gitea, ForgeItemKind.issue) => repo.url.replace(
      path: '/${repo.path}/issues/$number',
    ),
    (ForgeKind.gitea, ForgeItemKind.pull) => repo.url.replace(
      path: '/${repo.path}/pulls/$number',
    ),
    (ForgeKind.gitlab, ForgeItemKind.issue) => repo.url.replace(
      path: '/${repo.path}/-/issues/$number',
    ),
    (ForgeKind.gitlab, ForgeItemKind.pull) => repo.url.replace(
      path: '/${repo.path}/-/merge_requests/$number',
    ),
  };

  /// `#12`; a merge request's `!12`, as GitLab writes it.
  String get tag => repo.kind == ForgeKind.gitlab && kind == ForgeItemKind.pull
      ? '!$number'
      : '#$number';

  /// `owner/name#12`.
  String get fullTag => '${repo.path}$tag';

  @override
  String toString() => fullTag;

  @override
  bool operator ==(Object other) =>
      other is ForgeRef &&
      other.repo == repo &&
      other.kind == kind &&
      other.number == number;

  @override
  int get hashCode => Object.hash(repo, kind, number);

  /// The issue or pull request [url] is the page of (its comments', its
  /// files' too), on a host [kindOf] (or [publicForgeKind]) knows; a
  /// GitLab one (`/-/issues/`) on any host. Null for none.
  static ForgeRef? parse(String url, {ForgeKindOf? kindOf}) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isScheme('https') && !uri.isScheme('http')) {
      return null;
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    final host = uri.host.toLowerCase();
    final known = _webKind(uri, kindOf);
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    // GitLab: <path>/-/(issues|merge_requests)/<n>, on any host.
    final dash = parts.indexOf('-');
    if (dash >= 2 && parts.length > dash + 2) {
      final kind = switch (parts[dash + 1]) {
        'issues' || 'work_items' => ForgeItemKind.issue,
        'merge_requests' => ForgeItemKind.pull,
        _ => null,
      };
      final number = int.tryParse(parts[dash + 2]);
      if (kind != null &&
          number != null &&
          (known == null || known == ForgeKind.gitlab)) {
        return ForgeRef(
          repo: ForgeRepo(
            kind: ForgeKind.gitlab,
            host: host,
            path: parts.sublist(0, dash).join('/'),
          ),
          kind: kind,
          number: number,
        );
      }
      return null;
    }
    // GitHub uses /pull/; Gitea uses /pulls/, on registered instances.
    if (parts.length >= 4 &&
        (known == ForgeKind.github || known == ForgeKind.gitea)) {
      final kind = switch (parts[2]) {
        'issues' => ForgeItemKind.issue,
        'pull' when known == ForgeKind.github => ForgeItemKind.pull,
        'pulls' => ForgeItemKind.pull,
        _ => null,
      };
      final number = int.tryParse(parts[3]);
      if (kind != null && number != null) {
        return ForgeRef(
          repo: ForgeRepo(
            kind: known!,
            host: known == ForgeKind.gitea ? uri.origin : host,
            path: '${parts[0]}/${parts[1]}',
          ),
          kind: kind,
          number: number,
        );
      }
    }
    return null;
  }

  /// Every issue or pull request a text links to, once each, in order.
  static List<ForgeRef> allIn(String text, {ForgeKindOf? kindOf}) {
    final found = <ForgeRef>{};
    for (final match in _urlPattern.allMatches(text)) {
      final url = match[0]!.replaceAll(RegExp(r'[.,;:!?)\]>]+$'), '');
      if (parse(url, kindOf: kindOf) case final ref?) found.add(ref);
    }
    return found.toList();
  }

  static final _urlPattern = RegExp(r'''https?://[^\s<>"'`]+''');
}
