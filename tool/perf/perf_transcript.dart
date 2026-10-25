// A real conversation for the scenarios to replay: a Claude Code session's
// transcript (~/.claude/projects/<project>/<session>.jsonl), its prompts,
// thoughts, answers and tool calls with their results, as turns of
// PerfSteps. What a synthetic history leaves out (outputs of tens of
// thousands of lines, diffs of whole files, thousands of tools in one
// session) is in it as the user had it.

import 'dart:convert';
import 'dart:io';

import 'perf_transport.dart';

/// One prompt of the transcript and the turn that answered it.
typedef PerfTranscriptTurn = ({String prompt, PerfTurn turn});

/// The turns of the transcript at [path], at most [limit] of them (the
/// first ones), each written at once.
List<PerfTranscriptTurn> readTranscript(String path, {int? limit}) {
  final records = <Map<String, Object?>>[];
  for (final line in File(path).readAsLinesSync()) {
    if (line.isEmpty) continue;
    try {
      final record = jsonDecode(line);
      if (record is Map<String, Object?> && record['isSidechain'] != true) {
        records.add(record);
      }
    } on FormatException {
      continue;
    }
  }

  // The tools' results, by the call they answer.
  final results = <String, String>{};
  for (final record in records) {
    if (record['type'] != 'user') continue;
    for (final block in _blocks(record)) {
      if (block['type'] == 'tool_result') {
        results[block['tool_use_id']! as String] = _text(block['content']);
      }
    }
  }

  final turns = <PerfTranscriptTurn>[];
  String? prompt;
  var steps = <PerfStep>[];
  void end() {
    if (prompt != null && steps.isNotEmpty) {
      turns.add((
        prompt: prompt!,
        turn: PerfTurn(steps, pace: PerfPace.instant),
      ));
    }
    prompt = null;
    steps = <PerfStep>[];
  }

  for (final record in records) {
    final message = record['message'];
    if (message is! Map<String, Object?>) continue;
    switch (record['type']) {
      case 'user':
        // A prompt (text, not a tool's result) starts a turn.
        final text = switch (message['content']) {
          final String s => s,
          final List<Object?> blocks => [
            for (final b in blocks.whereType<Map<String, Object?>>())
              if (b['type'] == 'text') b['text']! as String,
          ].join('\n'),
          _ => '',
        };
        if (text.trim().isEmpty) continue;
        end();
        if (limit != null && turns.length >= limit) return turns;
        prompt = text;
      case 'assistant' when prompt != null:
        for (final block in _blocks(record)) {
          switch (block['type']) {
            case 'thinking':
              final text = block['thinking'] as String? ?? '';
              if (text.isNotEmpty) steps.add(PerfThink(text));
            case 'text':
              final text = block['text'] as String? ?? '';
              if (text.isNotEmpty) steps.add(PerfSay(text));
            case 'tool_use':
              steps.add(
                PerfTool(
                  block['name']! as String,
                  (block['input'] as Map<String, Object?>?) ?? const {},
                  result: results[block['id']] ?? '',
                  took: Duration.zero,
                ),
              );
          }
        }
    }
  }
  end();
  return turns;
}

List<Map<String, Object?>> _blocks(Map<String, Object?> record) =>
    switch ((record['message'] as Map<String, Object?>?)?['content']) {
      final List<Object?> blocks =>
        blocks.whereType<Map<String, Object?>>().toList(),
      _ => const [],
    };

/// A tool result's text: a string, or the text of its blocks (images
/// left out).
String _text(Object? content) => switch (content) {
  final String s => s,
  final List<Object?> blocks => [
    for (final b in blocks.whereType<Map<String, Object?>>())
      if (b['type'] == 'text') b['text'] as String? ?? '',
  ].join('\n'),
  _ => '',
};
