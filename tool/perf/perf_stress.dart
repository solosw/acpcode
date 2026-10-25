// The stress scenarios: the app at the limits of what users put it
// through, where it is most sensitive. Agents that think and write faster
// than any model, answers and conversations far longer than usual, a file
// of 90,000 lines and one of very long lines, jumps and scrolling as fast
// as the input comes, files switched as fast as they show, sixteen agents
// at once.

import 'dart:math';

import 'package:flutter/widgets.dart' show CustomPaint, Offset;

import 'package:baocode/chat/widgets/chat_minimap.dart';
import 'package:baocode/workspace/chat_grid.dart';

import 'perf_probe.dart';
import 'perf_scenarios.dart';
import 'perf_transport.dart';

const _fast = Duration(milliseconds: 16);

final List<PerfScenario> stressScenarios = [
  // --- The chat ----------------------------------------------------------------
  PerfScenario(
    'stress.thinking',
    'A thought of 60k characters streamed at 12,000 chars/s (40-char '
        'deltas), then a short answer.',
    (c) async {
      await c.history(c.agent, 1);
      await c.settle();
      final turn = PerfTurn([
        PerfThink(c.content.thought(60000)),
        PerfSay(c.content.reply(1500)),
      ], pace: PerfPace.torrent);
      await c.phase('think', (r) async {
        await c.run(c.agent, turn);
        r.extra['streamedChars'] = turn.streamedChars;
      });
    },
  ),
  PerfScenario(
    'stress.huge_reply',
    'One answer of 240k characters of markdown and code at 12,000 chars/s, '
        'measured by thirds: whether a delta costs more as the message grows.',
    (c) async {
      await c.history(c.agent, 1);
      await c.settle();
      final turn = PerfTurn([
        PerfSay(c.content.reply(240000, heavy: true)),
      ], pace: PerfPace.torrent);
      final total = turn.streamedChars;
      final session = c.agent.session;
      final ended = session.lastTurnEndSeq;
      final since = PerfTransport.streamed;
      await c.start(c.agent, turn);
      await c.phase('first_third', (r) => c.untilStreamed(since, total ~/ 3));
      await c.phase(
        'second_third',
        (r) => c.untilStreamed(since, total * 2 ~/ 3),
      );
      await c.phase(
        'last_third',
        (r) => c.until(
          () => session.lastTurnEndSeq > ended && !session.isStreaming,
          'the answer',
        ),
      );
    },
  ),
  PerfScenario(
    'stress.huge_history',
    'A 150-turn conversation: loaded at once, the wheel spun fast through '
        'it, jumps by its minimap, then an answer streamed below it.',
    (c) async {
      await c.settle();
      await c.phase('load', (r) async {
        await c.history(c.agent, 150);
        await c.settle();
      });
      final at = c.chatCenter;
      await c.phase('spin', (r) async {
        await c.input.spin(at, -200, 200, every: _fast);
        await c.settle(const Duration(milliseconds: 500));
        await c.input.spin(at, 200, 200, every: _fast);
        await c.settle(const Duration(milliseconds: 500));
      });
      // Its track: the minimap's own box is the history's.
      if (c.find<ChatMinimap>() case final minimap?) {
        final rect = c.rectOf(c.findIn<CustomPaint>(minimap)!);
        final random = Random(3);
        await c.phase('jumps', (r) async {
          for (var i = 0; i < 40; i++) {
            PerfProbe.instance.mark(PerfMark.action);
            await c.input.click(
              Offset(
                rect.center.dx,
                rect.top + rect.height * random.nextDouble(),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 120));
          }
          await c.settle(const Duration(milliseconds: 500));
        });
        // Its glass dragged from end to end and back as fast as a hand
        // goes: a quarter of a second a way.
        await c.phase('scrub', (r) async {
          final x = rect.center.dx;
          final top = rect.top + 4;
          final bottom = rect.bottom - 4;
          final points = [
            for (var trip = 0; trip < 3; trip++) ...[
              for (var i = 0; i <= 30; i++)
                Offset(x, top + (bottom - top) * i / 30),
              for (var i = 29; i >= 0; i--)
                Offset(x, top + (bottom - top) * i / 30),
            ],
          ];
          await c.input.dragAlong(points);
          await c.settle(const Duration(milliseconds: 500));
        });
      }
      await c.phase('stream', (r) async {
        await c.run(c.agent, c.reply(6000, PerfPace.fast, heavy: true));
      });
    },
  ),
  PerfScenario(
    'stress.agents',
    'Sixteen agents answering at once, fast, with long thoughts: four side '
        'by side (2×2), twelve out of sight.',
    (c) async {
      final agents = await c.agents(16);
      final [a, b, d, e, ...] = agents;
      c.workspace
        ..select(a)
        ..openBeside(b, a, PaneSide.right)
        ..openBeside(d, a, PaneSide.bottom)
        ..openBeside(e, b, PaneSide.bottom);
      await c.settle();
      await c.phase('stream', (r) async {
        final ends = [for (final t in agents) t.session.lastTurnEndSeq];
        for (final thread in agents) {
          await c.start(
            thread,
            PerfTurn([
              PerfThink(c.content.thought(6000)),
              c.read(200),
              c.bash(120),
              PerfSay(c.content.reply(12000, heavy: true)),
            ], pace: PerfPace.fast),
          );
        }
        await c.until(
          () => [
            for (final (i, t) in agents.indexed)
              t.session.lastTurnEndSeq > ends[i] && !t.session.isStreaming,
          ].every((ended) => ended),
          'the sixteen turns',
          timeout: const Duration(minutes: 3),
        );
      });
    },
  ),

  // --- Fast Ide ----------------------------------------------------------------
  PerfScenario(
    'stress.huge_file',
    'A 90,000-line TypeScript file: opened, 60 jumps across it (as to '
        'definitions), the wheel spun fast, trackpad flings, typing near its '
        'end.',
    (c) async {
      final workbench = await c.openIde();
      await c.phase('open', (r) async {
        final took = await c.openFile(workbench, c.project.hugeFile);
        r.extra['coloredMs'] = took.inMilliseconds;
        await c.settle();
      });
      await c.settle(const Duration(seconds: 2));
      final lines = '\n'.allMatches(c.editor!.controller.value.text).length + 1;
      final random = Random(1);
      await c.phase('jumps', (r) async {
        for (var i = 0; i < 60; i++) {
          PerfProbe.instance.mark(PerfMark.action);
          c.jumpTo(1 + random.nextInt(lines));
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        await c.settle(const Duration(milliseconds: 500));
      });
      final at = c.editorRect.center;
      await c.phase('spin', (r) async {
        await c.input.spin(at, 200, 150, every: _fast);
        await c.settle(const Duration(milliseconds: 300));
        await c.input.spin(at, -200, 150, every: _fast);
        await c.settle(const Duration(milliseconds: 500));
      });
      await c.phase('fling', (r) async {
        for (var i = 0; i < 4; i++) {
          await c.input.swipe(at, List.filled(30, i.isEven ? -80 : 80));
          await c.settle(const Duration(milliseconds: 900));
        }
      });
      await c.focusEditor(lines - 500);
      await c.phase('type', (r) async {
        await c.input.type(typedCode * 2);
        await c.settle(const Duration(milliseconds: 500));
      });
    },
  ),
  PerfScenario(
    'stress.long_lines',
    '600 lines of over 2,000 characters each (bundled code): scrolled down '
        'and across, typed into the middle of a line.',
    (c) async {
      final workbench = await c.openIde();
      await c.phase('open', (r) async {
        final took = await c.openFile(workbench, c.project.longLinesFile);
        r.extra['coloredMs'] = took.inMilliseconds;
        await c.settle();
      });
      await c.settle(const Duration(seconds: 1));
      final at = c.editorRect.center;
      await c.phase('scroll', (r) async {
        await c.input.spin(at, 120, 80, every: _fast);
        await c.settle(const Duration(milliseconds: 300));
        await c.input.spin(at, 0, 60, dx: 200, every: _fast);
        await c.settle(const Duration(milliseconds: 300));
        await c.input.spin(at, -120, 40, every: _fast);
        await c.settle(const Duration(milliseconds: 500));
      });
      await c.focusEditor(300, column: 1200);
      await c.phase('type', (r) async {
        await c.input.type(typedCode);
        await c.settle(const Duration(milliseconds: 500));
      });
    },
  ),
  PerfScenario(
    'stress.file_churn',
    'Forty files of 1,200 lines open, gone through as fast as the editor '
        'shows each, three times over.',
    (c) async {
      final workbench = await c.openIde();
      for (final path in c.project.manyFiles) {
        await c.openFile(workbench, path);
      }
      await c.settle(const Duration(seconds: 1));
      await c.phase('switch', (r) async {
        final took = <double>[];
        for (var round = 0; round < 3; round++) {
          for (final path in c.project.manyFiles.reversed) {
            took.add((await c.openFile(workbench, path)).inMicroseconds / 1000);
          }
        }
        r.extra['switchMs'] = stats(took);
        await c.settle(const Duration(milliseconds: 500));
      });
    },
  ),

  // --- All of it ---------------------------------------------------------------
  PerfScenario(
    'stress.everything',
    'Typing in the 90,000-line file while the IDE\'s agent thinks and '
        'answers at 12,000 chars/s beside it, and eight more agents answer '
        'out of sight.',
    (c) async {
      final workbench = await c.openIde();
      await c.openFile(workbench, c.project.hugeFile);
      final chat = c.workspace.ideChat(c.project.root)!;
      await c.history(chat, 2);
      final others = await c.agents(8);
      await c.settle(const Duration(seconds: 2));
      await c.focusEditor(45000);
      await c.phase('type', (r) async {
        await c.start(
          chat,
          PerfTurn([
            // Outlasting the typing (about 13s): 15s at this pace.
            PerfThink(c.content.thought(60000)),
            PerfSay(c.content.reply(120000, heavy: true)),
          ], pace: PerfPace.torrent),
        );
        for (final thread in others) {
          await c.start(thread, c.reply(20000, PerfPace.fast, heavy: true));
        }
        await c.input.type(typedCode * 2);
        await c.settle(const Duration(milliseconds: 500));
        r.extra['agentStillStreaming'] = chat.session.isStreaming;
      });
    },
  ),
];
