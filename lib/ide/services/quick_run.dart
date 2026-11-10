import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../ide_dialog.dart';
import '../ide_menu.dart';
import '../ide_workspace.dart';
import '../workbench/contributions.dart';
import '../workbench/storage.dart';
import 'terminal_view.dart';

typedef _QuickRunConfiguration = ({String name, String command, String cwd});

class QuickRunService extends ChangeNotifier
    implements WorkbenchStorageParticipant {
  QuickRunService({
    required this.host,
    required this.storage,
    required this.terminalView,
    required this.workspace,
  });

  final WorkbenchHost host;
  final WorkbenchStorage storage;
  final TerminalViewService terminalView;
  final IdeWorkspace Function() workspace;
  final List<_QuickRunConfiguration> _quickRunConfigurations = [];
  int _quickRunSelected = 0;
  bool _configuringQuickRun = false;

  @override
  void restoreState(Map<String, Object?> kept) {
    _quickRunConfigurations.clear();
    _quickRunSelected = 0;
    _restoreQuickRun(kept['quickRun']);
  }

  @override
  void saveState(Map<String, Object?> into) {
    if (_quickRunConfigurations.isNotEmpty) into['quickRun'] = _quickRunJson;
  }

  String? get selectedDescription => switch (_selectedQuickRun) {
    final config? => '${config.name}\n${config.command}',
    null => null,
  };
  void _refresh(VoidCallback update) {
    update();
    notifyListeners();
  }

  _QuickRunConfiguration? get _selectedQuickRun =>
      _quickRunConfigurations.isEmpty
      ? null
      : _quickRunConfigurations[_quickRunSelected];

  void _restoreQuickRun(Object? value) {
    if (value is! Map) return;
    if (value['configurations'] case final List<Object?> configurations) {
      for (final config in configurations) {
        if (config case {'command': final String command}
            when command.trim().isNotEmpty) {
          final name = switch (config['name']) {
            final String name when name.trim().isNotEmpty => name.trim(),
            _ => command.trim(),
          };
          final cwd = switch (config['cwd']) {
            final String cwd => cwd.trim(),
            _ => '',
          };
          _quickRunConfigurations.add((
            name: name,
            command: command.trim(),
            cwd: cwd,
          ));
        }
      }
    }
    if (value['selected'] case final int selected
        when selected >= 0 && selected < _quickRunConfigurations.length) {
      _quickRunSelected = selected;
    }
  }

  Map<String, Object?> get _quickRunJson => {
    'configurations': [
      for (final config in _quickRunConfigurations)
        {'name': config.name, 'command': config.command, 'cwd': config.cwd},
    ],
    'selected': _quickRunSelected,
  };

  /// A fresh shell for each invocation: never type into an existing job.
  void run() {
    final terminals = terminalView.terminals;
    if (terminals == null || !this.workspace().hasFolder) return;
    final config = _selectedQuickRun;
    if (config == null) {
      unawaited(_configureQuickRun());
      return;
    }
    final workspace = this.workspace();
    final root = workspace.roots.firstOrNull ?? workspace.root;
    final cwd = config.cwd.isEmpty
        ? root
        : workspace.paths.normalize(workspace.paths.join(root, config.cwd));
    terminals.create(cwd: cwd)
      ..rename(config.name)
      ..sendText(config.command, shouldExecute: true);
    terminalView.show();
  }

  void showMenu(Rect anchor) {
    final context = host.context;
    if (context == null) return;
    final l10n = context.l10n;
    unawaited(
      showIdeMenu(
        context,
        anchor: anchor,
        entries: [
          for (var i = 0; i < _quickRunConfigurations.length; i++)
            IdeMenuAction(
              _quickRunConfigurations[i].name,
              checked: i == _quickRunSelected,
              onSelected: () {
                _refresh(() => _quickRunSelected = i);
                storage.changed();
              },
            ),
          if (_quickRunConfigurations.isNotEmpty) const IdeMenuSeparator(),
          IdeMenuAction(
            l10n.quickRunAdd,
            onSelected: () => unawaited(_configureQuickRun()),
          ),
          if (_selectedQuickRun != null) ...[
            IdeMenuAction(
              l10n.quickRunEdit,
              onSelected: () => unawaited(_configureQuickRun(edit: true)),
            ),
            IdeMenuAction(l10n.quickRunDelete, onSelected: _deleteQuickRun),
          ],
        ],
      ),
    );
  }

  void _deleteQuickRun() {
    if (_selectedQuickRun == null) return;
    _refresh(() {
      _quickRunConfigurations.removeAt(_quickRunSelected);
      _quickRunSelected = math.max(
        0,
        math.min(_quickRunSelected, _quickRunConfigurations.length - 1),
      );
    });
    storage.changed();
  }

  Future<void> _configureQuickRun({bool edit = false}) async {
    if (_configuringQuickRun) return;
    _configuringQuickRun = true;
    try {
      final context = host.context;
      if (context == null) return;
      final l10n = context.l10n;
      final config = edit ? _selectedQuickRun : null;
      final result = await showIdeInputDialog(
        context,
        message: l10n.quickRunConfigure,
        detail: l10n.quickRunDescription,
        type: IdeDialogType.info,
        buttons: [l10n.quickRunSaveAndRun, l10n.commonSave],
        inputs: [
          IdeDialogInput(
            placeholder: l10n.quickRunName,
            value: config?.name ?? '',
          ),
          IdeDialogInput(
            placeholder: l10n.quickRunCommand,
            value: config?.command ?? '',
          ),
          IdeDialogInput(
            placeholder: l10n.quickRunWorkingDirectory,
            value: config?.cwd ?? '',
          ),
        ],
      );
      if (!context.mounted || result == null) return;
      final command = result.values[1].trim();
      if (command.isEmpty) {
        host.report(l10n.quickRunCommandRequired);
        return;
      }
      final name = result.values[0].trim();
      final updated = (
        name: name.isEmpty ? command : name,
        command: command,
        cwd: result.values[2].trim(),
      );
      _refresh(() {
        if (config != null) {
          _quickRunConfigurations[_quickRunSelected] = updated;
        } else {
          _quickRunConfigurations.add(updated);
          _quickRunSelected = _quickRunConfigurations.length - 1;
        }
      });
      storage.changed();
      if (result.button == 0) run();
    } finally {
      _configuringQuickRun = false;
    }
  }
}
