// Whether scrolling follows the hand (perf_follow.dart), in every view the
// user scrolls: the chat, the sidebar's agents, the stashes' cards and a
// stash's text, a file in the side panel, the IDE's editor. Each is scrolled
// the same ways: a wheel's notches slow and fast, a wheel that scrolls
// smoothly, fingers on the trackpad dragging, flicking, flicking again and
// turning back. A hand's own scrolling can be recorded (`record.hands`) and
// played back (`follow.replay`), the same on every build.
//
// What following is, checked (`c.check`) as the user would feel it:
// - fingers on the trackpad move the view as far as they move, no
//   further, within two frames;
// - the same flick again goes about as far again, not further and further;
// - a wheel's notch has the view most of its way within 80ms, a smooth
//   wheel's within two frames;
// - an input the other way turns the view within two frames.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/chat/side_panel/file_preview.dart';
import 'package:baocode/chat/side_panel/side_panel_view.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/stash/stash_controller.dart';
import 'package:baocode/stash/stash_editor.dart';
import 'package:baocode/stash/stash_view.dart';

import 'perf_follow.dart';
import 'perf_probe.dart';
import 'perf_scenarios.dart';

/// A view the hand scrolls: where its offset is, where to put the pointer,
/// and how to bring it back to its middle (room to go either way).
class _View {
  _View({
    required this.pixels,
    required this.at,
    required this.middle,
    this.reversed = false,
    this.atEnd,
  });

  /// [view]'s, a scroll view's.
  factory _View.scrollable(PerfContext c, ScrollableState view, Offset at) =>
      _View(
        pixels: () => view.position.pixels,
        at: at,
        reversed:
            view.axisDirection == AxisDirection.up ||
            view.axisDirection == AxisDirection.left,
        atEnd: () {
          final p = view.position;
          return p.pixels <= p.minScrollExtent + 0.5 ||
              p.pixels >= p.maxScrollExtent - 0.5;
        },
        middle: () async {
          final p = view.position;
          p.jumpTo((p.minScrollExtent + p.maxScrollExtent) / 2);
          await c.settle(const Duration(milliseconds: 400));
        },
      );

  final double Function() pixels;
  final Offset at;
  final Future<void> Function() middle;
  final bool reversed;
  final bool Function()? atEnd;

  PerfFollow follow() => PerfFollow(pixels, reversed: reversed, atEnd: atEnd);
}

typedef _ViewSetUp = Future<_View?> Function(PerfContext c);

/// The views, by the name their scenario has (`follow.<name>`).
final Map<String, (String, _ViewSetUp)> _views = {
  'chat': ('a 40-turn conversation', _chat),
  'sidebar': ('a sidebar of 200 agents', _sidebar),
  'stash_cards': ('the stashes\' page, 64 cards', _stashCards),
  'stash_note': ('a stash of 40,000 characters', _stashNote),
  'side_panel': ('a 9,000-line file in the side panel\'s editor', _sidePanel),
  'ide': ('a 9,000-line file in the IDE\'s editor', _ide),
};

Future<_View?> _chat(PerfContext c) async {
  await c.history(c.agent, 40);
  await c.settle(const Duration(seconds: 1));
  final history = c.find<ChatHistoryView>();
  c.check(history != null, 'the conversation shows');
  if (history == null) return null;
  return _View.scrollable(
    c,
    c.scrollableIn(history)!,
    c.rectOf(history).center,
  );
}

Future<_View?> _sidebar(PerfContext c) async {
  await c.agents(200);
  await c.settle(const Duration(seconds: 1));
  // The project lists its latest five: all of them, by Show More.
  final more = c.findNamed('_MoreRow');
  if (more.isNotEmpty) await c.input.click(c.rectOf(more.first).center);
  await c.settle();
  final sidebar = c.find<Sidebar>();
  c.check(sidebar != null, 'the sidebar shows');
  if (sidebar == null) return null;
  return _View.scrollable(
    c,
    c.scrollableIn(sidebar)!,
    c.rectOf(sidebar).center,
  );
}

StashController get _stash => StashController.current!;

Future<_View?> _stashCards(PerfContext c) async {
  for (var i = 0; i < 40; i++) {
    await _stash.store.create(
      body: '# ${c.content.identifier()}\n\n${c.content.reply(600)}',
    );
  }
  _stash.showPage!(_stash.store.notes.first.id);
  await c.settle(const Duration(seconds: 1));
  final page = c.find<StashView>();
  c.check(page != null, 'the stashes\' page shows');
  if (page == null) return null;
  final rect = c.rectOf(page);
  return _View.scrollable(
    c,
    c.scrollableIn(page)!,
    Offset(rect.left + rect.width * .25, rect.center.dy),
  );
}

Future<_View?> _stashNote(PerfContext c) async {
  final note = await _stash.store.create(
    body: '# ${c.content.identifier()}\n\n${c.content.reply(40000)}',
  );
  // The page first: what shows a stash is built with it.
  _stash.showPage!(note.id);
  await c.settle();
  _stash.showPage!(note.id);
  await c.settle(const Duration(seconds: 1));
  final editor = c.find<StashEditor>();
  c.check(editor != null, 'the stash\'s editor shows');
  if (editor == null) return null;
  return _View.scrollable(c, c.scrollableIn(editor)!, c.rectOf(editor).center);
}

Future<_View?> _sidePanel(PerfContext c) async {
  await c.history(c.agent, 2);
  final area = c.find<AgentSidePanelArea>();
  c.check(area != null, 'the side panel is there');
  if (area == null) return null;
  final panel = (area.widget as AgentSidePanelArea).panel..show();
  panel.open(c.agent.session, FileOpenRequest(c.project.bigFile));
  await c.settle(const Duration(seconds: 2));
  // Editable, as files open there: the editor the IDE has.
  final preview = c.find<FilePreview>();
  final element = preview == null ? null : c.findIn<EditorSurface>(preview);
  c.check(element != null, 'the file shows in the side panel\'s editor');
  if (element == null) return null;
  final editor = (element as StatefulElement).state as EditorSurfaceView;
  final text = (element.widget as EditorSurface).controller.value.text;
  return _View(
    pixels: () => editor.scrollOffset.dy,
    at: c.rectOf(element).center,
    middle: () async {
      editor.revealRange(text.length ~/ 2, text.length ~/ 2, center: true);
      await c.settle(const Duration(milliseconds: 400));
    },
  );
}

Future<_View?> _ide(PerfContext c) async {
  final workbench = await c.openIde();
  await c.openFile(workbench, c.project.bigFile);
  await c.settle(const Duration(seconds: 1));
  return _View(
    pixels: () => c.editorView.scrollOffset.dy,
    at: c.editorRect.center,
    middle: () async {
      c.jumpTo(4500);
      await c.settle(const Duration(milliseconds: 400));
    },
  );
}

/// A frame of the display, in ms.
double get _frameMs {
  final rate = WidgetsBinding
      .instance
      .platformDispatcher
      .implicitView
      ?.display
      .refreshRate;
  return rate == null || rate < 24 ? 16.7 : 1000 / rate;
}

num? _figure(PerfRecording r, String path) {
  Object? value = r.extra['follow'];
  for (final key in path.split('.')) {
    value = value is Map ? value[key] : null;
  }
  return value is num ? value : null;
}

const _rest = Duration(milliseconds: 1500);

/// The ways a hand scrolls [view], each a phase, each checked.
Future<void> _scrolled(PerfContext c, _View view) async {
  final at = view.at;

  Future<void> phase(
    String name,
    Future<void> Function() body,
    void Function(PerfRecording r) check,
  ) async {
    await view.middle();
    await c.phase(name, (r) async {
      final follow = view.follow();
      await followed(r, follow, body);
      // At an end the view stops whatever the hand does: not following
      // there is not the view's fault.
      c.check(!follow.hitEnd, '$name: the view had room, not at an end');
      if (!follow.hitEnd) check(r);
    });
  }

  void within(PerfRecording r, String path, double most, String what) {
    final value = _figure(r, path);
    c.check(value != null && value <= most, '$what: $value (at most $most)');
  }

  void fingers(PerfRecording r, String what) {
    final ratio = _figure(r, 'ratio');
    c.check(
      ratio != null && (ratio - 1).abs() <= 0.05,
      '$what: the view goes as far as the fingers, $ratio of it',
    );
    within(
      r,
      'lagMs.p90',
      2 * _frameMs + 1,
      '$what: ms the view is behind the fingers (p90)',
    );
    // The same lag in pixels at every frame is the fingers' start lost:
    // a dead zone before the view moves.
    within(r, 'lagPx.max', 1, '$what: px of the fingers the view never goes');
  }

  await phase(
    'wheel_slow',
    () async {
      await c.input.spin(at, 80, 6, every: const Duration(milliseconds: 150));
      await c.input.spin(at, -80, 6, every: const Duration(milliseconds: 150));
      await c.settle(const Duration(milliseconds: 500));
    },
    (r) => within(
      r,
      'catchUpMs.p90',
      80,
      'slow notches: ms the view takes to go most of a notch\'s way (p90)',
    ),
  );
  await phase(
    'wheel_fast',
    () async {
      await c.input.spin(at, 80, 20, every: const Duration(milliseconds: 30));
      await c.settle(const Duration(milliseconds: 300));
      await c.input.spin(at, -80, 20, every: const Duration(milliseconds: 30));
      await c.settle(const Duration(milliseconds: 500));
    },
    (r) {
      final ratio = _figure(r, 'ratio');
      // Notches still gliding when the last comes are not yet all gone:
      // the view may be short of them then, never past them.
      c.check(
        ratio != null && ratio <= 1.05,
        'fast notches: the view goes no further than they ask, $ratio of it',
      );
    },
  );
  await phase(
    'wheel_smooth',
    () async {
      await c.input.smoothWheel(at, 600, const Duration(milliseconds: 500));
      await c.settle(const Duration(milliseconds: 300));
      await c.input.smoothWheel(at, -600, const Duration(milliseconds: 500));
      await c.settle(const Duration(milliseconds: 500));
    },
    (r) => within(
      r,
      'catchUpMs.p90',
      2 * _frameMs + 1,
      'a smooth wheel: ms the view takes to be where it asked (p90)',
    ),
  );
  await phase(
    'drag',
    () async {
      await c.input.stroke(at, -300, const Duration(milliseconds: 450));
      await c.settle(const Duration(milliseconds: 600));
      await c.input.stroke(at, 300, const Duration(milliseconds: 450));
      await c.settle(const Duration(milliseconds: 600));
    },
    (r) {
      fingers(r, 'a drag');
      within(
        r,
        'tailPx.max',
        20,
        'a drag stopped before lifting: px the view goes on after',
      );
    },
  );
  await phase('flick', () async {
    await c.input.stroke(
      at,
      -150,
      const Duration(milliseconds: 120),
      flick: true,
    );
    await c.settle(_rest);
  }, (r) => fingers(r, 'a flick'));
  await phase(
    'flicks',
    () async {
      for (var i = 0; i < 4; i++) {
        await c.input.stroke(
          at,
          -150,
          const Duration(milliseconds: 120),
          flick: true,
        );
        await c.settle(const Duration(milliseconds: 250));
      }
      await c.settle(_rest);
    },
    (r) {
      fingers(r, 'flicks');
      // Each flick's fling is cut short by the next: the last one's, with
      // nothing after it, against how far one flick alone went.
      final gestures = ((r.extra['follow'] as Map?)?['gestures'] as List?)
          ?.cast<Map>();
      final alone =
          ((c.results['flick'] as Map?)?['follow'] as Map?)?['tailPx'];
      final single = (alone as Map?)?['max'] as num?;
      final last = (gestures?.last['tailPx'] as num?)?.abs();
      r.extra['lastTailOverSingle'] = single == null || last == null
          ? -1
          : PerfFollow.round(last / single);
      c.check(
        single != null && last != null && last <= single * 1.3,
        'the same flick again goes about as far: ${last}px after the '
        'fourth, ${single}px after one alone',
      );
    },
  );
  await phase(
    'reverse',
    () async {
      await c.input.swipe(at, [
        for (var i = 0; i < 30; i++) i < 15 ? -10.0 : 10.0,
      ]);
      await c.settle(const Duration(milliseconds: 600));
    },
    (r) => within(
      r,
      'reverseMs.p90',
      2 * _frameMs + 1,
      'fingers turning back: ms the view takes to turn',
    ),
  );
}

Future<void> _follow(_ViewSetUp setUp, PerfContext c) async {
  final view = await setUp(c);
  if (view != null) await _scrolled(c, view);
}

// Each written out: run.dart reads the scenarios' names from the source.
final List<PerfScenario> handScenarios = [
  PerfScenario(
    'follow.chat',
    'How closely a 40-turn conversation follows the hand: wheel notches slow and fast, a smooth wheel, fingers dragging, flicking, flicking again, turning back.',
    (c) => _follow(_chat, c),
  ),
  PerfScenario(
    'follow.sidebar',
    'How closely a sidebar of 200 agents follows the hand: wheel notches slow and fast, a smooth wheel, fingers dragging, flicking, flicking again, turning back.',
    (c) => _follow(_sidebar, c),
  ),
  PerfScenario(
    'follow.stash_cards',
    'How closely the stashes\' page, 64 cards follows the hand: wheel notches slow and fast, a smooth wheel, fingers dragging, flicking, flicking again, turning back.',
    (c) => _follow(_stashCards, c),
  ),
  PerfScenario(
    'follow.stash_note',
    'How closely a stash of 40,000 characters follows the hand: wheel notches slow and fast, a smooth wheel, fingers dragging, flicking, flicking again, turning back.',
    (c) => _follow(_stashNote, c),
  ),
  PerfScenario(
    'follow.side_panel',
    'How closely a 9,000-line file in the side panel follows the hand: wheel notches slow and fast, a smooth wheel, fingers dragging, flicking, flicking again, turning back.',
    (c) => _follow(_sidePanel, c),
  ),
  PerfScenario(
    'follow.ide',
    'How closely a 9,000-line file in the IDE\'s editor follows the hand: wheel notches slow and fast, a smooth wheel, fingers dragging, flicking, flicking again, turning back.',
    (c) => _follow(_ide, c),
  ),
  PerfScenario(
    'follow.replay',
    'A hand\'s own scrolling, recorded by record.hands (--hands FILE), '
        'played back in the view it was recorded in, as it came.',
    (c) async {
      final file = Platform.environment['BAOCODE_PERF_HANDS'];
      c.check(file != null, 'a recording to play (--hands FILE)');
      if (file == null) return;
      final recorded = jsonDecode(File(file).readAsStringSync()) as Map;
      final events = (recorded['events'] as List).cast<Map<String, Object?>>();
      final setUp = _views[recorded['view']]?.$2 ?? _chat;
      final view = await setUp(c);
      if (view == null) return;
      await view.middle();
      await c.phase('hands', (r) async {
        await followed(r, view.follow(), () async {
          await c.input.replay(view.at, events);
          await c.settle(_rest);
        });
      });
    },
  ),
  PerfScenario(
    'record.hands',
    'Records a hand scrolling one view (BAOCODE_PERF_RECORD_VIEW: chat, '
        'sidebar, stash_cards, stash_note, side_panel, ide; chat by default) '
        'for 40 seconds (BAOCODE_PERF_RECORD_SECONDS), with the real mouse '
        'and trackpad: how closely it followed, and the events, for '
        'follow.replay. --record FILE says where they go.',
    (c) async {
      final env = Platform.environment;
      final out = env['BAOCODE_PERF_RECORD'];
      c.check(out != null, 'where the recording goes (--record FILE)');
      if (out == null) return;
      final seconds = int.tryParse(env['BAOCODE_PERF_RECORD_SECONDS'] ?? '');
      final name = env['BAOCODE_PERF_RECORD_VIEW'] ?? 'chat';
      final view = await (_views[name]?.$2 ?? _chat)(c);
      if (view == null) return;
      await view.middle();
      final events = <Map<String, Object?>>[];
      final clock = Stopwatch();
      void see(PointerEvent event) {
        final t = clock.elapsedMicroseconds;
        switch (event) {
          case PointerScrollEvent(:final scrollDelta, :final kind):
            PerfFollow.input(scrollDelta.dy);
            events.add({
              't': t,
              'type': 'wheel',
              'kind': kind.name,
              'dx': scrollDelta.dx,
              'dy': scrollDelta.dy,
            });
          case PointerPanZoomStartEvent():
            events.add({'t': t, 'type': 'start'});
          case PointerPanZoomUpdateEvent(:final panDelta):
            PerfFollow.input(-panDelta.dy);
            events.add({
              't': t,
              'type': 'update',
              'dx': panDelta.dx,
              'dy': panDelta.dy,
            });
          case PointerPanZoomEndEvent():
            events.add({'t': t, 'type': 'end'});
          default:
        }
      }

      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      final isolated = dispatcher.onPointerDataPacket;
      dispatcher.onPointerDataPacket = PerfContext.desktopPointers;
      GestureBinding.instance.pointerRouter.addGlobalRoute(see);
      PerfContext.log(
        'RECORDING: scroll the $name with your mouse or trackpad for '
        '${seconds ?? 40} seconds',
      );
      try {
        await c.phase('hands', (r) async {
          await followed(r, view.follow(), () async {
            clock.start();
            await Future<void>.delayed(Duration(seconds: seconds ?? 40));
          });
          r.extra['events'] = events.length;
        });
      } finally {
        GestureBinding.instance.pointerRouter.removeGlobalRoute(see);
        dispatcher.onPointerDataPacket = isolated;
      }
      File(out)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'view': name,
            'refreshRate': dispatcher.implicitView?.display.refreshRate,
            'events': events,
            'follow': (c.results['hands'] as Map?)?['follow'],
          }),
        );
      PerfContext.log('recorded ${events.length} events to $out');
    },
  ),
];
