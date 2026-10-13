import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Where a stash stands. It moves on by what is done with it, never by
/// hand but for [done] (see docs/stash.md).
enum StashStatus {
  /// Just jotted down: what every stash starts as.
  collected,

  /// A "需求" section was written after it ([StashNote.requirementHeading]).
  requirement,

  /// A conversation was started on it, its first message sent.
  implementing,

  /// The work is over: the agent said so ([stash_complete]), or the user.
  done;

  static StashStatus parse(Object? value) =>
      values.where((status) => status.name == value).firstOrNull ?? collected;
}

/// Where in BaoCode a stash was jotted down (its shortcut pressed there,
/// or an agent writing it): the project, its branch and the conversation.
@immutable
class StashSource {
  const StashSource({this.project, this.branch, this.thread});

  final String? project;
  final String? branch;
  final String? thread;

  static const none = StashSource();

  bool get isEmpty => project == null && branch == null && thread == null;

  Map<String, Object?> toJson() => {
    'project': ?project,
    'branch': ?branch,
    'thread': ?thread,
  };

  static StashSource fromJson(Object? json) {
    if (json is! Map) return none;
    String? string(String key) => switch (json[key]) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };
    return StashSource(
      project: string('project'),
      branch: string('branch'),
      thread: string('thread'),
    );
  }

  StashSource copyWith({String? project, String? branch, String? thread}) =>
      StashSource(
        project: project ?? this.project,
        branch: branch ?? this.branch,
        thread: thread ?? this.thread,
      );

  @override
  bool operator ==(Object other) =>
      other is StashSource &&
      other.project == project &&
      other.branch == branch &&
      other.thread == thread;

  @override
  int get hashCode => Object.hash(project, branch, thread);
}

/// The conversation a stash is being (or was) carried out in.
@immutable
class StashThreadLink {
  const StashThreadLink({required this.project, this.session, this.title});

  /// The project's path it runs in.
  final String project;

  /// Its session's id, once it has one (the first message sent).
  final String? session;

  /// As it was titled when last seen.
  final String? title;

  Map<String, Object?> toJson() => {
    'project': project,
    'session': ?session,
    'title': ?title,
  };

  static StashThreadLink? fromJson(Object? json) => switch (json) {
    {'project': final String project} => StashThreadLink(
      project: project,
      session: json['session'] as String?,
      title: json['title'] as String?,
    ),
    _ => null,
  };

  StashThreadLink copyWith({String? session, String? title}) => StashThreadLink(
    project: project,
    session: session ?? this.session,
    title: title ?? this.title,
  );

  @override
  bool operator ==(Object other) =>
      other is StashThreadLink &&
      other.project == project &&
      other.session == session &&
      other.title == title;

  @override
  int get hashCode => Object.hash(project, session, title);
}

/// One stash: a markdown file, `<id>.md`, its pictures and files in the
/// folder `<id>/` beside it. What is not its text is kept at its top, as
/// front matter whose values are JSON (which YAML reads as well).
class StashNote {
  StashNote({
    required this.id,
    required this.created,
    DateTime? updated,
    this.title = '',
    this.body = '',
    this.status = StashStatus.collected,
    this.pinned = false,
    this.project,
    this.thread,
    this.source = StashSource.none,
    this.suggestedProject,
  }) : updated = updated ?? created;

  /// Its number, `#12`: never given to another, even once it is gone.
  final int id;
  final DateTime created;
  DateTime updated;

  /// A title the model gave it (or none yet): the cards show its first
  /// line without one.
  String title;

  /// What was written, as markdown.
  String body;
  StashStatus status;
  bool pinned;

  /// The project (its path) it is about, if it was said.
  String? project;

  /// Where it is carried out.
  StashThreadLink? thread;

  final StashSource source;

  /// A project the model thinks it is about, for the user to confirm.
  String? suggestedProject;

  /// `#12`.
  String get tag => '#$id';

  /// The heading [StashStatus.requirement] adds its requirement under.
  static const requirementHeading = '## 需求';

  /// Its text before the requirement, if one was written.
  String get original {
    final at = _requirementStart(body);
    return at == null ? body : body.substring(0, at).trimRight();
  }

  /// The requirement written after it, without its heading; null for none.
  String? get requirement {
    final at = _requirementStart(body);
    if (at == null) return null;
    return body.substring(at + requirementHeading.length).trim();
  }

  static int? _requirementStart(String body) {
    final match = RegExp(
      '^${RegExp.escape(requirementHeading)}[ \t]*\$',
      multiLine: true,
    ).allMatches(body).lastOrNull;
    return match?.start;
  }

  /// Its text with [requirement] put after it (in place of the one it
  /// had).
  String withRequirement(String requirement) =>
      '${original.trimRight()}\n\n$requirementHeading\n\n${requirement.trim()}\n';

  /// Whether nothing was written in it.
  bool get isBlank => body.trim().isEmpty;

  /// Made for writing in and never written in: what the panel goes on
  /// with rather than making another. One written and emptied is not.
  bool get isDraft => isBlank && !updated.isAfter(created);

  /// What the cards and pickers call it: its title, else the first line of
  /// its text with the markdown marks taken off; empty for a blank one.
  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    for (final line in plainText(body).split('\n')) {
      final text = line.trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  /// Its text without its first line (when that is its title), for the
  /// cards' summaries.
  String get summary {
    final lines = plainText(original)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (title.trim().isEmpty && lines.isNotEmpty) lines.removeAt(0);
    return lines.join(' ');
  }

  /// The pictures it shows, by the paths its text gives them (relative to
  /// the stash folder, or absolute).
  List<String> get images => [
    for (final match in _imagePattern.allMatches(body))
      match[1] ?? match[2] ?? '',
  ].where((path) => path.isNotEmpty).toList();

  static final _imagePattern = RegExp(
    r'''!\[[^\]]*\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)|<img[^>]*\ssrc="([^"]+)"''',
  );

  StashNote copy() => StashNote(
    id: id,
    created: created,
    updated: updated,
    title: title,
    body: body,
    status: status,
    pinned: pinned,
    project: project,
    thread: thread,
    source: source,
    suggestedProject: suggestedProject,
  );

  // --- The file ---------------------------------------------------------------

  /// As it is written to its file.
  String encode() {
    final meta = <String, Object?>{
      'id': id,
      'created': created.toIso8601String(),
      'updated': updated.toIso8601String(),
      if (title.isNotEmpty) 'title': title,
      'status': status.name,
      if (pinned) 'pinned': true,
      'project': ?project,
      if (thread case final thread?) 'thread': thread.toJson(),
      if (!source.isEmpty) 'source': source.toJson(),
      'suggestedProject': ?suggestedProject,
    };
    final buffer = StringBuffer('---\n');
    for (final MapEntry(:key, :value) in meta.entries) {
      buffer.writeln('$key: ${jsonEncode(value)}');
    }
    buffer.write('---\n\n');
    buffer.write(body.trimRight());
    buffer.write('\n');
    return buffer.toString();
  }

  /// The stash file [text] is, numbered [id] (its name's); front matter
  /// that cannot be read leaves it all text.
  static StashNote decode(int id, String text, {DateTime? modified}) {
    final now = modified ?? DateTime.now();
    final (meta, body) = splitFrontMatter(text);
    DateTime? date(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;
    final created = date(meta['created']) ?? now;
    return StashNote(
      id: id,
      created: created,
      updated: date(meta['updated']) ?? created,
      title: meta['title'] as String? ?? '',
      body: body,
      status: StashStatus.parse(meta['status']),
      pinned: meta['pinned'] == true,
      project: meta['project'] as String?,
      thread: StashThreadLink.fromJson(meta['thread']),
      source: StashSource.fromJson(meta['source']),
      suggestedProject: meta['suggestedProject'] as String?,
    );
  }

  /// [text]'s front matter (each line `key: value`, the value JSON or a
  /// bare word) and what follows it.
  static (Map<String, Object?>, String) splitFrontMatter(String text) {
    text = text.replaceAll('\r\n', '\n');
    if (!text.startsWith('---\n')) return (const {}, text.trim());
    final end = text.indexOf('\n---', 4);
    if (end < 0) return (const {}, text.trim());
    final meta = <String, Object?>{};
    for (final line in text.substring(4, end).split('\n')) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim();
      final raw = line.substring(colon + 1).trim();
      Object? value;
      try {
        value = jsonDecode(raw);
      } on FormatException {
        value = raw;
      }
      meta[key] = value;
    }
    var rest = text.substring(end + 4);
    final newline = rest.indexOf('\n');
    rest = newline < 0 ? '' : rest.substring(newline + 1);
    return (meta, rest.trim());
  }
}

/// [markdown]'s words without its marks: what search and the cards read.
String plainText(String markdown) {
  var text = markdown.replaceAll('\r\n', '\n');
  text = text
      // Pictures and HTML tags.
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAll(RegExp(r'<img[^>]*>'), '')
      .replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '')
      // Links: their text.
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      // Fences, headings, quotes, list marks and task boxes.
      .replaceAll(RegExp(r'^\s*(```+|~~~+).*$', multiLine: true), '')
      .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '')
      .replaceAll(
        RegExp(r'^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?', multiLine: true),
        '',
      )
      // Emphasis, code and math marks.
      .replaceAll(RegExp(r'(\*\*|__|~~|`|\$\$?)'), '')
      .replaceAll(RegExp(r'(?<![\w*])\*(?!\s)|(?<!\s)\*(?![\w*])'), '');
  return text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}
