import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/ide/ide_menu.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/terminal/terminal_instance.dart';
import 'package:baocode/ide/terminal/terminal_view.dart';
import 'package:baocode/keybindings/keybinding_service.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/workspace/workspace.dart';

import '../terminal/fake_pty.dart';
import 'fake_files.dart';

final _run = find.byKey(const ValueKey('ide-quick-run'));
final _fields = find.byType(TextField);
final _menuItems = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_MenuItem',
);

Finder _inRun(Finder finder) => find.descendant(of: _run, matching: finder);
Finder _inMenu(String label) =>
    find.descendant(of: _menuItems, matching: find.text(label));

// Menus run their action after the route closes. Use bounded pumps rather
// than pumpAndSettle: a running terminal has a blinking cursor.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _runSelected(WidgetTester tester) async {
  await tester.tap(_inRun(find.text('Run')));
  await _settle(tester);
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(_inRun(find.byIcon(Codicons.chevronDown)));
  await _settle(tester);
  expect(_menuItems, findsWidgets);
}

Future<void> _choose(WidgetTester tester, String label) async {
  await _openMenu(tester);
  await tester.tap(_inMenu(label));
  await _settle(tester);
}

List<IdeMenuAction> _actions(WidgetTester tester) => [
  for (final item in tester.widgetList(_menuItems))
    (item as dynamic).action as IdeMenuAction,
];

void _expectDialog(
  WidgetTester tester, {
  String name = '',
  String command = '',
  String cwd = '',
}) {
  expect(find.text('Configure Quick Run'), findsOneWidget);
  expect(_fields, findsNWidgets(3));
  expect(
    [
      for (final field in tester.widgetList<TextField>(_fields))
        field.controller!.text,
    ],
    [name, command, cwd],
  );
  for (final label in ['Save and Run', 'Save', 'Cancel']) {
    expect(find.widgetWithText(IdeButton, label), findsOneWidget);
  }
}

Future<void> _fill(
  WidgetTester tester, {
  required String name,
  required String command,
  String cwd = '',
}) async {
  await tester.enterText(_fields.at(0), name);
  await tester.enterText(_fields.at(1), command);
  await tester.enterText(_fields.at(2), cwd);
}

Future<void> _submit(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(IdeButton, label));
  await _settle(tester);
  expect(find.text('Configure Quick Run'), findsNothing);
}

TerminalInstance _shown(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).instance;

Map<String, Object?> _config(String name, String command, [String cwd = '']) =>
    {'name': name, 'command': command, 'cwd': cwd};

Map<String, Object?> _state(
  List<Map<String, Object?>> configurations, {
  int selected = 0,
}) => {'configurations': configurations, 'selected': selected};

void main() {
  setUp(() => KeybindingService.instance = KeybindingService());
  tearDown(() => KeybindingService.instance = KeybindingService());

  testWidgets('Run is a split button; the first Save keeps a command '
      'without running, then Run uses the workspace root', (tester) async {
    final ptys = <FakePty>[];
    Map<String, Object?>? kept;
    await pumpWorkbench(
      tester,
      {},
      startPty: FakePty.starter(ptys),
      onViewState: (state) => kept = state,
    );
    final button = tester.widget<IdeButton>(_run);
    expect(button.label, 'Run');
    expect(button.icon, Codicons.play);
    expect(button.onDropdown, isNotNull);

    await _openMenu(tester);
    expect(_actions(tester).map((action) => action.label), [
      'Add Run Command...',
    ]);
    await tester.tap(_inMenu('Add Run Command...'));
    await _settle(tester);
    _expectDialog(tester);
    await _submit(tester, 'Cancel');

    await _runSelected(tester);
    _expectDialog(tester);
    await _fill(tester, name: 'Frontend', command: 'npm run dev');
    await _submit(tester, 'Save');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([_config('Frontend', 'npm run dev')]));
    expect(ptys, isEmpty);

    await _runSelected(tester);
    expect(_fields, findsNothing);
    expect(ptys, hasLength(1));
    expect(ptys.single.launch!.workingDirectory, testRoot);
    expect(ptys.single.written, 'npm run dev\r');
    expect(_shown(tester).title, 'Frontend');
  });

  testWidgets('multiple commands keep independent cwd; selecting a checked '
      'menu entry only selects, and Run executes that command', (tester) async {
    final ptys = <FakePty>[];
    Map<String, Object?>? kept;
    final frontend = _config('Frontend', 'npm run dev', 'tmp/../web');
    final backend = _config('Backend', 'dart run server', inRoot('api'));
    await pumpWorkbench(
      tester,
      {},
      roots: ['app', 'other'],
      startPty: FakePty.starter(ptys),
      onViewState: (state) => kept = state,
    );
    await _runSelected(tester);
    await _fill(
      tester,
      name: 'Frontend',
      command: 'npm run dev',
      cwd: 'tmp/../web',
    );
    await _submit(tester, 'Save');
    await _choose(tester, 'Add Run Command...');
    _expectDialog(tester);
    await _fill(
      tester,
      name: 'Backend',
      command: 'dart run server',
      cwd: inRoot('api'),
    );
    await _submit(tester, 'Save');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([frontend, backend], selected: 1));
    expect(ptys, isEmpty);

    await _runSelected(tester);
    expect(ptys, hasLength(1));
    expect(ptys.single.launch!.workingDirectory, inRoot('api'));
    expect(ptys.single.written, 'dart run server\r');
    expect(_shown(tester).title, 'Backend');

    await _openMenu(tester);
    final actions = _actions(tester);
    expect(actions.map((action) => action.label), [
      'Frontend',
      'Backend',
      'Add Run Command...',
      'Edit Run Command...',
      'Delete Run Command',
    ]);
    expect(actions.take(2).map((action) => action.isChecked), [false, true]);
    await tester.tap(_inMenu('Frontend'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([frontend, backend]));
    expect(ptys, hasLength(1));
    expect(ptys.single.written, 'dart run server\r');

    await _openMenu(tester);
    expect(_actions(tester).take(2).map((action) => action.isChecked), [
      true,
      false,
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    await _runSelected(tester);
    expect(ptys, hasLength(2));
    expect(ptys.last.launch!.workingDirectory, inRoot('app/web'));
    expect(ptys.last.written, 'npm run dev\r');
    expect(_shown(tester).title, 'Frontend');
  });

  testWidgets('restoring selected does not run; each Run creates a new '
      'terminal rather than reusing an existing one', (tester) async {
    final ptys = <FakePty>[];
    await pumpWorkbench(
      tester,
      {},
      roots: ['first', 'second'],
      viewState: {
        'quickRun': _state([
          _config('Frontend', 'npm run dev', 'web'),
          _config('Backend', 'dart run server'),
        ], selected: 1),
      },
      startPty: FakePty.starter(ptys),
    );
    await _settle(tester);
    expect(ptys, isEmpty);
    expect(find.text('Configure Quick Run'), findsNothing);

    await chord(
      tester,
      LogicalKeyboardKey.backquote,
      control: true,
      shift: true,
    );
    expect(ptys, hasLength(1));
    final ordinary = _shown(tester);
    expect(ptys.single.written, isEmpty);
    await _runSelected(tester);
    expect(ptys, hasLength(2));
    final firstRun = _shown(tester);
    expect(firstRun, isNot(same(ordinary)));
    expect(firstRun.title, 'Backend');
    expect(ptys[1].launch!.workingDirectory, inRoot('first'));
    expect(ptys[1].written, 'dart run server\r');

    await _runSelected(tester);
    expect(ptys, hasLength(3));
    expect(_shown(tester), isNot(same(firstRun)));
    expect(_shown(tester).title, 'Backend');
    expect(ptys[2].launch!.workingDirectory, inRoot('first'));
    expect(ptys[2].written, 'dart run server\r');
    expect(ptys[0].written, isEmpty);
    expect(ptys[1].written, 'dart run server\r');
    expect(ptys.every((pty) => pty.kills.isEmpty), isTrue);
  });

  testWidgets('editing only replaces the selected command; cancelling an '
      'edit preserves both commands and the selection', (tester) async {
    final ptys = <FakePty>[];
    Map<String, Object?>? kept;
    final frontend = _config('Frontend', 'npm run dev', 'web');
    final backend = _config('Backend', 'dart run server', 'api');
    final edited = _config('API tests', 'dart test', 'api/test/..');
    await pumpWorkbench(
      tester,
      {},
      viewState: {
        'quickRun': _state([frontend, backend], selected: 1),
      },
      onViewState: (state) => kept = state,
      startPty: FakePty.starter(ptys),
    );
    await _choose(tester, 'Edit Run Command...');
    _expectDialog(
      tester,
      name: 'Backend',
      command: 'dart run server',
      cwd: 'api',
    );
    await _fill(
      tester,
      name: 'API tests',
      command: 'dart test',
      cwd: 'api/test/..',
    );
    await _submit(tester, 'Save');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([frontend, edited], selected: 1));
    expect(ptys, isEmpty);

    await _choose(tester, 'Edit Run Command...');
    _expectDialog(
      tester,
      name: 'API tests',
      command: 'dart test',
      cwd: 'api/test/..',
    );
    await _fill(tester, name: 'Discarded', command: 'echo discarded');
    await _submit(tester, 'Cancel');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([frontend, edited], selected: 1));
    expect(ptys, isEmpty);
    await _runSelected(tester);
    expect(ptys.single.written, 'dart test\r');
    expect(ptys.single.launch!.workingDirectory, inRoot('api'));
    expect(_shown(tester).title, 'API tests');
  });

  testWidgets('deleting the selection is immediate, clamps selection, and '
      'does not kill an already running command', (tester) async {
    final ptys = <FakePty>[];
    Map<String, Object?>? kept;
    final first = _config('First', 'echo first');
    final middle = _config('Middle', 'echo middle');
    final last = _config('Last', 'echo last');
    await pumpWorkbench(
      tester,
      {},
      viewState: {
        'quickRun': _state([first, middle, last], selected: 1),
      },
      onViewState: (state) => kept = state,
      startPty: FakePty.starter(ptys),
    );
    await _runSelected(tester);
    final running = _shown(tester);
    expect(ptys.single.written, 'echo middle\r');

    await _choose(tester, 'Delete Run Command');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([first, last], selected: 1));
    expect(ptys, hasLength(1));
    expect(ptys.single.kills, isEmpty);
    expect(_shown(tester), same(running));
    await _openMenu(tester);
    expect(_inMenu('Middle'), findsNothing);
    expect(_actions(tester).take(2).map((action) => action.isChecked), [
      false,
      true,
    ]);
    await tester.tap(_inMenu('Delete Run Command'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([first]));

    await _choose(tester, 'Delete Run Command');
    await _openMenu(tester);
    expect(_actions(tester).map((action) => action.label), [
      'Add Run Command...',
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    await _runSelected(tester);
    _expectDialog(tester);
    await _submit(tester, 'Cancel');
    expect(ptys, hasLength(1));
    expect(ptys.single.written, 'echo middle\r');
    expect(ptys.single.kills, isEmpty);
  });

  testWidgets('Save and Run saves, selects and executes immediately; an '
      'empty name uses the command as its name', (tester) async {
    final ptys = <FakePty>[];
    Map<String, Object?>? kept;
    final first = _config('Frontend', 'npm run dev');
    await pumpWorkbench(
      tester,
      {},
      viewState: {
        'quickRun': _state([first]),
      },
      onViewState: (state) => kept = state,
      startPty: FakePty.starter(ptys),
    );
    await _choose(tester, 'Add Run Command...');
    _expectDialog(tester);
    await _fill(tester, name: '', command: 'dart test', cwd: 'tests/..');
    await _submit(tester, 'Save and Run');
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      kept?['quickRun'],
      _state([
        first,
        _config('dart test', 'dart test', 'tests/..'),
      ], selected: 1),
    );
    expect(ptys, hasLength(1));
    expect(ptys.single.written, 'dart test\r');
    expect(ptys.single.launch!.workingDirectory, testRoot);
    expect(_shown(tester).title, 'dart test');
  });

  testWidgets('cancelling the first command or an addition neither saves '
      'nor runs', (tester) async {
    final ptys = <FakePty>[];
    Map<String, Object?>? kept;
    await pumpWorkbench(
      tester,
      {},
      onViewState: (state) => kept = state,
      startPty: FakePty.starter(ptys),
    );
    await _runSelected(tester);
    await _fill(
      tester,
      name: 'Discarded',
      command: 'echo discarded',
      cwd: 'tmp',
    );
    await _submit(tester, 'Cancel');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], isNull);
    expect(ptys, isEmpty);
    await _runSelected(tester);
    _expectDialog(tester);
    await _fill(tester, name: 'Kept', command: 'echo kept');
    await _submit(tester, 'Save');
    await _choose(tester, 'Add Run Command...');
    _expectDialog(tester);
    await _fill(tester, name: 'Discarded', command: 'echo discarded');
    await _submit(tester, 'Cancel');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kept?['quickRun'], _state([_config('Kept', 'echo kept')]));
    expect(ptys, isEmpty);
  });

  testWidgets('Run is hidden when terminals are unsupported, even with '
      'restored commands', (tester) async {
    final ptys = <FakePty>[];
    await pumpWorkbench(
      tester,
      {},
      terminals: false,
      viewState: {
        'quickRun': _state([_config('Test', 'dart test')]),
      },
      startPty: FakePty.starter(ptys),
    );
    await _settle(tester);
    expect(_run, findsNothing);
    expect(ptys, isEmpty);
  });

  testWidgets('Run is hidden without an open folder even when terminals '
      'are supported', (tester) async {
    final ptys = <FakePty>[];
    await pumpWorkbench(tester, {}, startPty: FakePty.starter(ptys));
    final backend = tester
        .widget<IdeWorkbench>(find.byType(IdeWorkbench))
        .terminalBackend;
    final workspace = IdeWorkspace(
      testRoot,
      hasFolder: false,
      files: TreeFiles({}),
    );
    addTearDown(workspace.dispose);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: IdeWorkbench(
          workspace: workspace,
          project: Project.at(testRoot),
          visible: true,
          chat: const SizedBox.expand(key: chatKey),
          onBack: () {},
          terminalBackend: backend,
          viewState: {
            'quickRun': _state([_config('Test', 'dart test')]),
          },
        ),
      ),
    );
    await _settle(tester);
    expect(_run, findsNothing);
    expect(ptys, isEmpty);
  });
}
