// A Claude Code CLI that answers with what a scenario wrote for it, at the
// pace it set: the lines a real one prints (`stream_event` deltas,
// `assistant` and `user` messages, `result`), each decoded from JSON as
// the app decodes the process's output, on the UI isolate. A UI isolate
// that is busy gets them in bursts afterwards, as from a pipe.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';

import 'perf_probe.dart';

/// How fast an agent writes: [charsPerSecond] in deltas of [chunk]
/// characters. [instant] writes a turn at once (to make a history).
class PerfPace {
  const PerfPace(this.charsPerSecond, this.chunk);

  final double charsPerSecond;
  final int chunk;

  static const instant = PerfPace(double.infinity, 4000);

  /// As Opus writes: about 100 tokens a second.
  static const typical = PerfPace(400, 6);

  /// As a fast model writes.
  static const fast = PerfPace(1500, 12);

  /// More than any model writes: what a UI isolate that fell behind gets.
  static const flood = PerfPace(6000, 24);

  /// Twice that, in bigger deltas: the limit, for the stress scenarios.
  static const torrent = PerfPace(12000, 40);

  Duration get interval => charsPerSecond.isInfinite
      ? Duration.zero
      : Duration(microseconds: (chunk / charsPerSecond * 1e6).round());
}

sealed class PerfStep {
  const PerfStep();
}

final class PerfThink extends PerfStep {
  const PerfThink(this.text);
  final String text;
}

final class PerfSay extends PerfStep {
  const PerfSay(this.text);
  final String text;
}

/// A tool call, its result [took] later.
final class PerfTool extends PerfStep {
  const PerfTool(
    this.name,
    this.input, {
    this.result = '',
    this.structured,
    this.took = const Duration(milliseconds: 40),
  });

  final String name;
  final Map<String, Object?> input;
  final String result;
  final Object? structured;
  final Duration took;
}

final class PerfPause extends PerfStep {
  const PerfPause(this.duration);
  final Duration duration;
}

/// One turn of an agent: what it does, at [pace].
class PerfTurn {
  PerfTurn(this.steps, {this.pace = PerfPace.typical});

  final List<PerfStep> steps;
  final PerfPace pace;

  /// The characters it streams, thoughts and text.
  int get streamedChars => [
    for (final step in steps)
      switch (step) {
        PerfThink(:final text) || PerfSay(:final text) => text.length,
        _ => 0,
      },
  ].fold(0, (a, b) => a + b);
}

/// A line the CLI prints, due [due] into the turn; [chars], the text a
/// delta adds.
typedef _Line = ({Duration due, String json, int chars});

/// What the scenarios have their agents answer: a turn for each prompt,
/// compiled to the lines the CLI prints before the turn starts, so that
/// what is measured is the app reading them, not this making them.
abstract final class PerfTurns {
  static final Map<String, List<_Line>> _turns = {};
  static int _count = 0;

  /// Has an agent sent [prompt] answer with [turn].
  static void register(String prompt, PerfTurn turn) =>
      _turns[prompt] = _compile(turn, 't${++_count}');

  static List<_Line> _take(String prompt) =>
      _turns[prompt] ?? _compile(PerfTurn([const PerfSay('OK.')]), 'x');

  static List<_Line> _compile(PerfTurn turn, String key) {
    final lines = <_Line>[];
    var at = Duration.zero;
    var messages = 0;
    var tools = 0;
    void add(Map<String, Object?> message, {int chars = 0}) =>
        lines.add((due: at, json: jsonEncode(message), chars: chars));
    Map<String, Object?> event(Map<String, Object?> event) => {
      'type': 'stream_event',
      'event': event,
      'parent_tool_use_id': null,
    };
    const usage = {
      'input_tokens': 3,
      'cache_read_input_tokens': 21000,
      'cache_creation_input_tokens': 400,
      'output_tokens': 60,
    };
    Map<String, Object?> assistant(String id, List<Object?> content) => {
      'type': 'assistant',
      'message': {
        'id': id,
        'role': 'assistant',
        'model': 'claude-opus-5-5',
        'content': content,
        'usage': usage,
      },
      'parent_tool_use_id': null,
    };
    void stream(String kind, String text) {
      final id = 'msg_${key}_${++messages}';
      add({'type': 'system', 'subtype': 'status', 'status': 'requesting'});
      add(
        event({
          'type': 'message_start',
          'message': {'id': id, 'role': 'assistant'},
        }),
      );
      add(
        event({
          'type': 'content_block_start',
          'index': 0,
          'content_block': kind == 'thinking'
              ? {'type': 'thinking', 'thinking': ''}
              : {'type': 'text', 'text': ''},
        }),
      );
      for (var start = 0; start < text.length;) {
        var end = (start + turn.pace.chunk).clamp(0, text.length);
        // Never between a surrogate pair.
        if (end < text.length &&
            text.codeUnitAt(end - 1) >= 0xD800 &&
            text.codeUnitAt(end - 1) <= 0xDBFF) {
          end++;
        }
        at += turn.pace.interval;
        add(
          event({
            'type': 'content_block_delta',
            'index': 0,
            'delta': kind == 'thinking'
                ? {
                    'type': 'thinking_delta',
                    'thinking': text.substring(start, end),
                  }
                : {'type': 'text_delta', 'text': text.substring(start, end)},
          }),
          chars: end - start,
        );
        start = end;
      }
      add(event({'type': 'content_block_stop', 'index': 0}));
      add(
        assistant(id, [
          kind == 'thinking'
              ? {'type': 'thinking', 'thinking': text, 'signature': 'perf'}
              : {'type': 'text', 'text': text},
        ]),
      );
    }

    for (final step in turn.steps) {
      switch (step) {
        case PerfThink(:final text):
          stream('thinking', text);
        case PerfSay(:final text):
          stream('text', text);
        case PerfPause(:final duration):
          if (!turn.pace.charsPerSecond.isInfinite) at += duration;
        case PerfTool():
          final id = 'toolu_${key}_${++tools}';
          add(
            assistant('msg_${key}_${++messages}', [
              {
                'type': 'tool_use',
                'id': id,
                'name': step.name,
                'input': step.input,
              },
            ]),
          );
          if (!turn.pace.charsPerSecond.isInfinite) at += step.took;
          add({
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'content': step.result,
                  'is_error': false,
                },
              ],
            },
            'parent_tool_use_id': null,
            'tool_use_result': ?step.structured,
          });
      }
    }
    return lines;
  }
}

/// The kernel the perf app's agents run on: Claude Code's adapter, as in
/// the app, over [PerfTransport].
final KernelDescriptor perfClaudeCode = KernelDescriptor(
  id: 'claude-code',
  label: 'Claude Code',
  icon: Icons.auto_awesome_rounded,
  description: 'Anthropic’s coding agent',
  create: (context) =>
      ClaudeCodeKernel(perfClaudeCode, context, start: PerfTransport.start),
);

/// Answers each message with its [PerfTurns] turn; the control requests
/// as [MockClaudeCodeTransport] does.
class PerfTransport implements ClaudeCodeTransport {
  PerfTransport(ClaudeLaunch launch)
    : _control = MockClaudeCodeTransport(launch),
      _launch = launch {
    _control.messages.listen(
      (message) => _emit({...message, 'session_id': _sessionId}),
      onDone: _out.close,
    );
  }

  static Future<ClaudeCodeTransport> start(ClaudeLaunch launch) async =>
      PerfTransport(launch);

  /// The characters of thoughts and text all the agents have streamed:
  /// how far along a turn is.
  static int streamed = 0;

  static int _sessions = 0;

  final ClaudeLaunch _launch;
  final MockClaudeCodeTransport _control;
  final String _sessionId = 'perf-session-${++_sessions}';
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast();

  Timer? _timer;
  List<_Line> _lines = const [];
  int _next = 0;
  final Stopwatch _clock = Stopwatch();
  double _cost = 0;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  void _emit(Map<String, Object?> message) {
    if (!_out.isClosed) _out.add(message);
  }

  @override
  void write(Map<String, Object?> message) {
    switch (message['type']) {
      case 'user':
        _start(message);
      case 'control_request' when _isInterrupt(message):
        _stop(interrupted: true);
        _control.write(message);
      default:
        _control.write(message);
    }
  }

  static bool _isInterrupt(Map<String, Object?> message) =>
      (message['request'] as Map?)?['subtype'] == 'interrupt';

  void _start(Map<String, Object?> message) {
    final content = ((message['message'] as Map)['content'] as List)
        .cast<Map<Object?, Object?>>();
    final prompt = content
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'])
        .join('\n');
    final uuid = message['uuid'] as String? ?? 'u${_sessions}_$_next';
    _emit({
      'type': 'system',
      'subtype': 'init',
      'cwd': _launch.cwd,
      'model': 'claude-opus-5-5',
      'effort': 'high',
      'permissionMode': 'default',
      'session_id': _sessionId,
    });
    _emit({...message, 'isReplay': true, 'session_id': _sessionId});
    _emit({
      'type': 'command_lifecycle',
      'command_uuid': uuid,
      'state': 'started',
      'session_id': _sessionId,
    });
    _lines = PerfTurns._take(prompt.trim());
    _next = 0;
    _clock
      ..reset()
      ..start();
    _pump();
  }

  /// Prints the lines due, then waits for the next: those late come at
  /// once, as from a pipe the app did not read meanwhile.
  void _pump() {
    _timer = null;
    final now = _clock.elapsed;
    var delta = false;
    while (_next < _lines.length && _lines[_next].due <= now) {
      final line = _lines[_next++];
      delta |= line.chars > 0;
      streamed += line.chars;
      final decoded = (jsonDecode(line.json) as Map).cast<String, Object?>();
      _emit(decoded..['session_id'] = _sessionId);
    }
    if (delta) PerfProbe.instance.mark(PerfMark.delta);
    if (_next < _lines.length) {
      _timer = Timer(_lines[_next].due - now, _pump);
    } else {
      _stop();
    }
  }

  void _stop({bool interrupted = false}) {
    _timer?.cancel();
    _timer = null;
    if (_lines.isEmpty) return;
    _lines = const [];
    _cost += 0.0421;
    _emit({
      'type': 'result',
      'subtype': interrupted ? 'error_during_execution' : 'success',
      'is_error': false,
      'total_cost_usd': _cost,
      'usage': {
        'input_tokens': 120,
        'cache_read_input_tokens': 21000,
        'output_tokens': 480,
      },
      'modelUsage': {
        'claude-opus-5-5': {'contextWindow': 200000},
      },
      'session_id': _sessionId,
    });
  }

  @override
  Future<void> get exited => _out.done;

  @override
  void close() {
    _timer?.cancel();
    _control.close();
  }
}
