// Where code is hosted ("forges": GitHub, GitLab, Gitee, theirs or one of
// their own), told from links and Git remotes: a repository, and an issue or a
// pull (merge) request in it. Nothing here asks the network.

import 'package:flutter/foundation.dart';

import 'forge_address.dart';

enum ForgeKind {
  github,
  gitlab,
  gitee,
  // Last: an account of one is an instance's own, its whole address typed,
  // where the others are a service's (they are listed in this order too).
  gitea;

  static ForgeKind? parse(Object? value) =>
      values.where((kind) => kind.name == value).firstOrNull;

  /// What it is called, for the user.
  String get label => switch (this) {
    github => 'GitHub',
    gitlab => 'GitLab',
    gitea => 'Gitea',
    gitee => 'Gitee',
  };

  /// Its hosted service's host: the one a token or a sign-in is for when
  /// none is said.
  String get publicHost => switch (this) {
    github => 'github.com',
    gitlab => 'gitlab.com',
    gitea => '',
    gitee => 'gitee.com',
  };
}

/// What a host is: [ForgeKind.github] for github.com, [ForgeKind.gitlab]
/// for gitlab.com, [ForgeKind.gitee] for gitee.com, else as [kindOf] says
/// (an account's on it); null when it cannot be told.
// Gitea lookup accepts a full Web origin, or a bare host for SSH remotes.
typedef ForgeKindOf = ForgeKind? Function(String host);

ForgeKind? publicForgeKind(String host) => switch (host.toLowerCase()) {
  'github.com' || 'www.github.com' => ForgeKind.github,
  'gitlab.com' || 'www.gitlab.com' => ForgeKind.gitlab,
  'gitee.com' || 'www.gitee.com' => ForgeKind.gitee,
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
  // A Gitea instance's account is named by its whole origin.
  final exact = kindOf?.call(uri.origin);
  if (exact != null) return exact;
  // A self-hosted forge's is named by its authority, port and all.
  final authority = kindOf?.call(forgeAuthority(uri));
  if (authority != null) return authority;
  final bare = kindOf?.call(uri.host);
  // Never borrow a Gitea token from another protocol or Web port.
  return bare == ForgeKind.gitea ? null : bare ?? publicForgeKind(uri.host);
}

/// A repository: its forge, host and path (`owner/name`; a GitLab one's
/// groups before its name, `group/sub/name`).
@immutable
class ForgeRepo {
  const ForgeRepo({
    required this.kind,
    required this.host,
    required this.path,
    this.scheme = 'https',
  });

  final ForgeKind kind;

  /// The server's authority: its host, with the port when not [scheme]'s
  /// default (`gitlab.corp:8080`); a Gitea instance's whole origin instead
  /// (`http://git.example:3000`).
  final String host;

  final String path;

  /// `http`, for a self-hosted forge served so; `https` otherwise.
  final String scheme;

  /// Its page.
  Uri get url => kind == ForgeKind.gitea
      ? Uri.parse(host).replace(path: '/$path')
      : forgeUri(scheme, host, '/$path');

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
    final String scheme;
    final String host;
    String? origin;
    String path;
    // scp-like: user@host:path.
    final scp = RegExp(r'^(?:[^@/\s]+@)?([^:/\s]+):(?!//)(.+)$')
        .firstMatch(text);
    if (scp != null && !text.contains('://')) {
      // Git over SSH; its pages are https unless its account says otherwise.
      scheme = 'https';
      host = scp[1]!;
      path = scp[2]!;
    } else {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) return null;
      // The web (and API) scheme the remote is served with; a remote over
      // SSH's pages are https, and its port is not the web's.
      final web = uri.scheme == 'http' || uri.scheme == 'https';
      scheme = uri.scheme == 'http' ? 'http' : 'https';
      host = web ? forgeAuthority(uri) : uri.host;
      if (web) origin = uri.origin;
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
    // GitHub's, Gitea's and Gitee's are owner/name, no more.
    if (kind != ForgeKind.gitlab && path.split('/').length != 2) return null;
    if (kind == ForgeKind.gitea) {
      // An instance's pages are its whole origin; a remote over SSH names
      // its host only, so its account says the rest.
      origin ??= originOf?.call(host);
      if (origin == null) return null;
    }
    return ForgeRepo(
      kind: kind,
      host: kind == ForgeKind.gitea ? origin! : host.toLowerCase(),
      path: path,
      scheme: scheme,
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
    this.number = 0,
    this.code,
  });

  final ForgeRepo repo;
  final ForgeItemKind kind;
  final int number;

  /// A Gitee issue's number, which is not one: `I8ABCD` (its case matters).
  final String? code;

  /// Its number as the forge's paths and links write it.
  String get key => code ?? '$number';

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
    (ForgeKind.gitee, ForgeItemKind.issue) => repo.url.replace(
      path: '/${repo.path}/issues/$key',
    ),
    (ForgeKind.gitee, ForgeItemKind.pull) => repo.url.replace(
      path: '/${repo.path}/pulls/$number',
    ),
  };

  /// `#12`; a merge request's `!12`, as GitLab writes it; a Gitee issue's
  /// `#I8ABCD`.
  String get tag => repo.kind == ForgeKind.gitlab && kind == ForgeItemKind.pull
      ? '!$number'
      : '#$key';

  /// `owner/name#12`.
  String get fullTag => '${repo.path}$tag';

  @override
  String toString() => fullTag;

  @override
  bool operator ==(Object other) =>
      other is ForgeRef &&
      other.repo == repo &&
      other.kind == kind &&
      other.key == key;

  @override
  int get hashCode => Object.hash(repo, kind, key);

  /// The issue or pull request [url] is the page of (its comments', its
  /// files' too), on a host [kindOf] (or [publicForgeKind]) knows; a
  /// GitLab one (`/-/issues/`) on any host. Null for none.
  static ForgeRef? parse(String url, {ForgeKindOf? kindOf}) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isScheme('https') && !uri.isScheme('http')) {
      return null;
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    final host = forgeAuthority(uri);
    final scheme = uri.isScheme('http') ? 'http' : 'https';
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final known = _webKind(uri, kindOf);
    // GitLab: <path>/-/(issues|merge_requests)/<n>, on any host but
    // GitHub's and Gitee's.
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
            scheme: scheme,
          ),
          kind: kind,
          number: number,
        );
      }
      return null;
    }
    // Gitee: <owner>/<name>/issues/<I8ABCD>, <owner>/<name>/pulls/<n>.
    if (parts.length >= 4 && known == ForgeKind.gitee) {
      final repo = ForgeRepo(
        kind: ForgeKind.gitee,
        host: host,
        path: '${parts[0]}/${parts[1]}',
        scheme: scheme,
      );
      final key = parts[3];
      if (parts[2] == 'issues' && RegExp(r'^[0-9A-Za-z]+$').hasMatch(key)) {
        return ForgeRef(repo: repo, kind: ForgeItemKind.issue, code: key);
      }
      final number = int.tryParse(key);
      if (parts[2] == 'pulls' && number != null) {
        return ForgeRef(repo: repo, kind: ForgeItemKind.pull, number: number);
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
            scheme: scheme,
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
