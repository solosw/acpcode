import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/chat_session.dart';
import '../chat/composer/composer_picker.dart';
import '../chat/composer/kernel_option_text.dart';
import '../kernel/agent_kernel.dart';
import '../kernel/kernel_types.dart';
import '../l10n/l10n.dart';
import '../remote/remote_location.dart';
import '../workspace/workspace.dart';
import 'scheduled_executor.dart';
import 'scheduled_task.dart';
import 'task_scheduler.dart';

class ScheduledTasksView extends StatefulWidget {
  const ScheduledTasksView({
    super.key,
    required this.scheduler,
    required this.workspace,
    required this.onClose,
    required this.onOpenAgent,
    this.leading,
    this.titleBarInset = 12,
  });
  final TaskScheduler scheduler;
  final Workspace workspace;
  final VoidCallback onClose;
  final ValueChanged<AgentThread> onOpenAgent;
  final Widget? leading;
  final double titleBarInset;

  @override
  State<ScheduledTasksView> createState() => _ScheduledTasksViewState();
}

class _ScheduledTasksViewState extends State<ScheduledTasksView> {
  ScheduledTask? _editing;
  bool _creating = false;

  String _date(BuildContext context, DateTime? date) => date == null
      ? '—'
      : '${MaterialLocalizations.of(context).formatShortDate(date)} ${TimeOfDay.fromDateTime(date).format(context)}';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.scheduler,
    builder: (context, _) {
      final l10n = context.l10n;
      final scheduler = widget.scheduler;
      return Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(widget.titleBarInset, 8, 12, 8),
            child: Row(
              children: [
                ?widget.leading,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.scheduledTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!_creating && _editing == null)
                  TextButton.icon(
                    onPressed: scheduler.ready
                        ? () => setState(() => _creating = true)
                        : null,
                    icon: const Icon(Icons.add),
                    label: Text(l10n.scheduledCreate),
                  ),
                IconButton(
                  onPressed: widget.onClose,
                  tooltip: l10n.scheduledClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _creating || _editing != null
                ? _TaskEditor(
                    key: ValueKey(_editing?.id ?? 'new'),
                    workspace: widget.workspace,
                    task: _editing,
                    onCancel: () => setState(() {
                      _creating = false;
                      _editing = null;
                    }),
                    onSave: (task) async {
                      await scheduler.save(task);
                      if (mounted) {
                        setState(() {
                          _creating = false;
                          _editing = null;
                        });
                      }
                    },
                  )
                : !scheduler.ready
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(l10n.scheduledRuntimeHint),
                      const SizedBox(height: 20),
                      if (scheduler.tasks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(36),
                          child: Center(child: Text(l10n.scheduledEmpty)),
                        ),
                      for (final task in scheduler.tasks)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Switch(
                                      value: task.enabled,
                                      onChanged: (v) => unawaited(
                                        scheduler.setEnabled(task, v),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        task.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                      ),
                                    ),
                                    if (scheduler.running(task.id))
                                      const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    IconButton(
                                      tooltip: l10n.scheduledRunNow,
                                      icon: const Icon(Icons.play_arrow),
                                      onPressed: scheduler.running(task.id)
                                          ? null
                                          : () =>
                                                unawaited(scheduler.run(task)),
                                    ),
                                    IconButton(
                                      tooltip: l10n.scheduledEdit,
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: scheduler.running(task.id)
                                          ? null
                                          : () =>
                                                setState(() => _editing = task),
                                    ),
                                    IconButton(
                                      tooltip: l10n.scheduledDelete,
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: scheduler.running(task.id)
                                          ? null
                                          : () async {
                                              final confirmed =
                                                  await showDialog<bool>(
                                                    context: context,
                                                    builder: (context) => AlertDialog(
                                                      title: Text(
                                                        l10n.scheduledDelete,
                                                      ),
                                                      content: Text(task.name),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                context,
                                                                false,
                                                              ),
                                                          child: Text(
                                                            l10n.scheduledCancel,
                                                          ),
                                                        ),
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                context,
                                                                true,
                                                              ),
                                                          child: Text(
                                                            l10n.scheduledDelete,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                              if (confirmed == true) {
                                                await scheduler.remove(task);
                                              }
                                            },
                                    ),
                                  ],
                                ),
                                Text(
                                  '${task.kernel} · ${task.worktree ?? task.project}',
                                ),
                                Text(
                                  task.prompt,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${l10n.scheduledNextRun}: ${_date(context, task.nextRun)} · ${l10n.scheduledLastRun}: ${_date(context, task.lastRun)}',
                                ),
                                if (task.error case final error?)
                                  SelectableText(
                                    error,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                if (task.sessionId != null)
                                  TextButton(
                                    onPressed: () async {
                                      try {
                                        final thread = await widget.workspace
                                            .scheduledAgent(
                                              location:
                                                  task.sessionLocation ??
                                                  task.worktree ??
                                                  task.project,
                                              kernelId: task.kernel,
                                              settings: task.settings,
                                              resumeId: task.sessionId,
                                            );
                                        if (mounted) widget.onOpenAgent(thread);
                                      } on Object catch (error) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(error.toString()),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    child: Text(l10n.scheduledOpenChat),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      );
    },
  );
}

class _TaskEditor extends StatefulWidget {
  const _TaskEditor({
    super.key,
    required this.workspace,
    required this.task,
    required this.onCancel,
    required this.onSave,
  });
  final Workspace workspace;
  final ScheduledTask? task;
  final VoidCallback onCancel;
  final Future<void> Function(ScheduledTask) onSave;
  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final _name = TextEditingController(text: widget.task?.name ?? '');
  late final _prompt = TextEditingController(text: widget.task?.prompt ?? '');
  late String _kernel =
      widget.task?.kernel ?? widget.workspace.kernels.first.id;
  late String? _project =
      widget.task?.project ??
      widget.workspace.current?.project.path ??
      widget.workspace.projects.firstOrNull?.path;
  late String? _host = _project == null
      ? null
      : RemoteLocation.hostOf(_project!);
  late String? _worktree = widget.task?.worktree;
  late bool _newWorktree = widget.task?.newWorktree ?? false;
  late bool _reuse = widget.task?.reuse ?? false;
  late String? _sessionId = widget.task?.sessionId;
  late String? _sessionLocation = widget.task?.sessionLocation;
  late Set<int> _days = {
    ...?widget.task?.schedule.days,
    if (widget.task == null) ...[1, 2, 3, 4, 5],
  };
  late TimeOfDay _time = TimeOfDay(
    hour: widget.task?.schedule.hour ?? 9,
    minute: widget.task?.schedule.minute ?? 0,
  );
  ChatSession? _preview;
  bool _loading = true;
  bool _picking = false;
  bool _saving = false;
  String? _error;
  List<String> _worktrees = [];
  int _generation = 0;
  Completer<void>? _cancelConfiguration;

  @override
  void initState() {
    super.initState();
    widget.workspace.addListener(_changed);
    unawaited(_configure(widget.task?.settings ?? const {}));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _disposePreview() {
    _cancelConfiguration?.complete();
    _cancelConfiguration = null;
    final old = _preview;
    _preview = null;
    if (old != null) {
      old.removeListener(_changed);
      old.detach();
      old.dispose();
    }
  }

  Future<void> _configure([Map<String, String> settings = const {}]) async {
    final generation = ++_generation;
    _disposePreview();
    _loading = true;
    _picking = false;
    _error = null;
    if (mounted) setState(() {});
    final descriptor = widget.workspace.kernels
        .where((k) => k.id == _kernel)
        .firstOrNull;
    final project = _project;
    if (project == null || descriptor == null) {
      setState(() => _loading = false);
      return;
    }
    final preview = ChatSession(
      kernel: descriptor,
      kernels: widget.workspace.kernels,
      kernelContext: KernelContext(
        cwd: _worktree ?? project,
        settings: settings,
      ),
      historyCount: 0,
    );
    _preview = preview;
    final cancel = _cancelConfiguration = Completer<void>();
    preview.addListener(_changed);
    preview.attach();
    try {
      await applyTaskSettings(preview, settings, cancelled: cancel.future);
    } on Object catch (error) {
      if (mounted && generation == _generation) _error = error.toString();
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String? get _selectableSessionId {
    final id = _sessionId;
    if (id == null) return null;
    return widget.workspace.threads.any(
          (thread) =>
              thread.id == id &&
              thread.kernel.id == _kernel &&
              thread.project.path ==
                  (_sessionLocation ?? _worktree ?? _project) &&
              thread.archived,
        )
        ? null
        : id;
  }

  void _resetSession() {
    _sessionId = null;
    _sessionLocation = null;
  }

  Future<void> _pick(
    KernelChoiceKind kind,
    KernelOption option,
    void Function(KernelOption) select, {
    bool toggle = false,
  }) async {
    final preview = _preview;
    if (preview == null || _picking) return;
    final generation = _generation;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final model = preview.models?.selected.id ?? '';
      final enabled =
          preview
              .modelSettings(model)
              .where((s) => s.kind == kind)
              .firstOrNull
              ?.selected ==
          null;
      select(option);
      await waitForTaskSession(
        preview,
        () => toggle
            ? (preview
                          .modelSettings(model)
                          .where((s) => s.kind == kind)
                          .firstOrNull
                          ?.selected !=
                      null) ==
                  enabled
            : preview.selected(kind) == option.id,
        cancelled: _cancelConfiguration?.future,
      );
    } on Object catch (error) {
      if (mounted && generation == _generation) _error = error.toString();
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _loadWorktrees() async {
    final project = _project;
    if (project == null) return;
    try {
      final items = await taskGitService(project).worktrees();
      if (!mounted || project != _project) return;
      setState(
        () => _worktrees = [
          for (final item in items)
            if (!item.bare) RemoteLocation.of(_host, item.path),
        ],
      );
    } on Object catch (error) {
      if (mounted && project == _project) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _save() async {
    final preview = _preview;
    if (preview == null ||
        _loading ||
        _picking ||
        _days.isEmpty ||
        _prompt.text.trim().isEmpty ||
        _project == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final settings = {
        if (preview.models != null) 'model': preview.models!.selected.id,
        if (preview.modes != null) 'mode': preview.modes!.selected.id,
        if (preview.permissions != null)
          'permission': preview.permissions!.selected.id,
        for (final setting in preview.modelSettings(
          preview.models?.selected.id ?? '',
        ))
          setting.kind!.name: ?preview.selected(setting.kind!),
      };
      await widget.onSave(
        ScheduledTask(
          id: widget.task?.id ?? ChatSession.newTurnId(),
          name: _name.text.trim().isEmpty
              ? _prompt.text.trim().split('\n').first
              : _name.text.trim(),
          prompt: _prompt.text.trim(),
          kernel: _kernel,
          project: _project!,
          worktree: _newWorktree ? null : _worktree,
          newWorktree: _newWorktree,
          reuse: _reuse,
          settings: settings,
          schedule: TaskSchedule(
            hour: _time.hour,
            minute: _time.minute,
            days: _days,
          ),
          enabled: widget.task?.enabled ?? true,
          sessionId: _reuse ? _selectableSessionId : null,
          sessionLocation: _reuse && _selectableSessionId != null
              ? _sessionLocation
              : null,
          lastRun: widget.task?.lastRun,
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String label, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final workspace = widget.workspace;
    final hosts = <String>{
      ...workspace.sshServers.keys,
      for (final project in workspace.projects) ?project.host,
      ?_host,
    };
    final projects = <String>{
      for (final project in workspace.projects)
        if (project.host == _host) project.path,
      if (_project != null && RemoteLocation.hostOf(_project!) == _host)
        _project!,
    };
    final preview = _preview;
    final mode = preview?.modes;
    final permission = preview?.permissions;
    final models = preview?.models;
    final selectedSessionId = _selectableSessionId;
    final sessions = workspace.threads.where(
      (t) =>
          !t.archived &&
          t.project.path == (_worktree ?? _project) &&
          t.kernel.id == _kernel &&
          t.id != null,
    );
    Widget choice(KernelChoiceKind kind, KernelChoice value) => ComposerPicker(
      options: [
        for (final option in value.options)
          kind == KernelChoiceKind.permission
              ? localizedKernelOption(l10n, _kernel, kind, option)
              : option,
      ],
      selected: kind == KernelChoiceKind.permission
          ? localizedKernelOption(l10n, _kernel, kind, value.selected)
          : value.selected,
      onSelected: (option) => unawaited(_pick(kind, option, value.onSelected)),
    );
    final config = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          l10n.scheduledAgent,
          DropdownButtonFormField<String>(
            initialValue: workspace.kernels.any((k) => k.id == _kernel)
                ? _kernel
                : null,
            isExpanded: true,
            items: [
              for (final kernel in workspace.kernels)
                DropdownMenuItem(value: kernel.id, child: Text(kernel.label)),
            ],
            onChanged: (v) {
              if (v == null) return;
              _kernel = v;
              _resetSession();
              unawaited(_configure());
            },
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (preview != null)
          IgnorePointer(
            ignoring: _loading || _picking,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (mode != null) choice(KernelChoiceKind.mode, mode),
                if (permission != null)
                  choice(KernelChoiceKind.permission, permission),
                if (models != null) choice(KernelChoiceKind.model, models),
                for (final setting in preview.modelSettings(
                  models?.selected.id ?? '',
                ))
                  if (setting.toggle)
                    FilterChip(
                      label: Text(setting.options.first.label),
                      selected: setting.selected != null,
                      onSelected: (_) => unawaited(
                        _pick(
                          setting.kind!,
                          setting.options.first,
                          setting.onSelected,
                          toggle: true,
                        ),
                      ),
                    )
                  else
                    ComposerPicker(
                      options: setting.options,
                      selected: setting.selected ?? setting.options.first,
                      onSelected: (option) => unawaited(
                        _pick(setting.kind!, option, setting.onSelected),
                      ),
                    ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        _field(
          l10n.scheduledHost,
          DropdownButtonFormField<String>(
            key: ValueKey('host-$_host'),
            initialValue: _host ?? '',
            isExpanded: true,
            items: [
              DropdownMenuItem(value: '', child: Text(l10n.scheduledLocalHost)),
              for (final host in hosts)
                DropdownMenuItem(
                  value: host,
                  child: Text(workspace.hostLabel(host)),
                ),
            ],
            onChanged: (v) {
              _host = v == '' ? null : v;
              _project = workspace.projects
                  .where((p) => p.host == _host)
                  .firstOrNull
                  ?.path;
              _worktree = null;
              _worktrees = [];
              _resetSession();
              unawaited(_configure());
            },
          ),
        ),
        _field(
          l10n.scheduledProject,
          DropdownButtonFormField<String>(
            key: ValueKey('project-$_project'),
            initialValue: _project,
            isExpanded: true,
            hint: Text(l10n.scheduledOpenProjectHint),
            items: [
              for (final path in projects)
                DropdownMenuItem(
                  value: path,
                  child: Text(
                    Project.at(path).name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              _project = v;
              _worktree = null;
              _worktrees = [];
              _resetSession();
              unawaited(_configure());
            },
          ),
        ),
        _field(
          l10n.scheduledWorkspace,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<bool>(
                key: ValueKey('worktree-$_newWorktree'),
                isExpanded: true,
                initialValue: _newWorktree,
                items: [
                  DropdownMenuItem(
                    value: false,
                    child: Text(l10n.scheduledExistingWorktree),
                  ),
                  DropdownMenuItem(
                    value: true,
                    child: Text(l10n.scheduledNewWorktree),
                  ),
                ],
                onChanged: (v) {
                  setState(() {
                    _newWorktree = v ?? false;
                    _worktree = null;
                    _resetSession();
                  });
                  unawaited(_configure());
                },
              ),
              if (!_newWorktree)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('tree-$_worktree'),
                        initialValue: _worktree ?? _project,
                        isExpanded: true,
                        items: [
                          for (final path in <String>{
                            ?_project,
                            ?_worktree,
                            ..._worktrees,
                          })
                            DropdownMenuItem(
                              value: path,
                              child: Text(
                                Project.at(path).name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          _worktree = v == _project ? null : v;
                          _resetSession();
                          unawaited(_configure());
                        },
                      ),
                    ),
                    IconButton(
                      onPressed: _project == null ? null : _loadWorktrees,
                      tooltip: l10n.scheduledLoadWorktrees,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              if (_newWorktree) Text(l10n.scheduledNewWorktreeHint),
            ],
          ),
        ),
        _field(
          l10n.scheduledSession,
          Column(
            children: [
              DropdownButtonFormField<bool>(
                key: ValueKey('reuse-$_reuse'),
                isExpanded: true,
                initialValue: _reuse,
                items: [
                  DropdownMenuItem(
                    value: false,
                    child: Text(l10n.scheduledFreshSession),
                  ),
                  DropdownMenuItem(
                    value: true,
                    child: Text(l10n.scheduledReuseSession),
                  ),
                ],
                onChanged: (v) => setState(() {
                  _reuse = v ?? false;
                  _resetSession();
                }),
              ),
              if (_reuse && !_newWorktree)
                DropdownButtonFormField<String>(
                  key: ValueKey('session-$selectedSessionId'),
                  initialValue: selectedSessionId ?? '',
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(l10n.scheduledAutomaticSession),
                    ),
                    for (final thread in sessions)
                      DropdownMenuItem(
                        value: thread.id,
                        child: Text(
                          thread.localizedTitle(l10n),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (selectedSessionId != null &&
                        !sessions.any((t) => t.id == selectedSessionId))
                      DropdownMenuItem(
                        value: selectedSessionId,
                        child: Text(selectedSessionId),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _sessionId = v == '' ? null : v;
                    _sessionLocation = _worktree ?? _project;
                  }),
                ),
            ],
          ),
        ),
        _field(
          l10n.scheduledSchedule,
          DropdownButtonFormField<String>(
            key: ValueKey(_days.toList()..sort()),
            initialValue: _days.length == 7
                ? 'daily'
                : _days.length == 5 && !_days.contains(6) && !_days.contains(7)
                ? 'weekdays'
                : 'custom',
            items: [
              DropdownMenuItem(
                value: 'daily',
                child: Text(l10n.scheduledDaily),
              ),
              DropdownMenuItem(
                value: 'weekdays',
                child: Text(l10n.scheduledWeekdays),
              ),
              DropdownMenuItem(
                value: 'custom',
                child: Text(l10n.scheduledCustomDays),
              ),
            ],
            onChanged: (v) => setState(
              () => _days = v == 'daily'
                  ? {1, 2, 3, 4, 5, 6, 7}
                  : v == 'weekdays'
                  ? {1, 2, 3, 4, 5}
                  : {..._days},
            ),
          ),
        ),
        Wrap(
          spacing: 4,
          children: [
            for (var day = 1; day <= 7; day++)
              FilterChip(
                label: Text(
                  MaterialLocalizations.of(context).narrowWeekdays[day % 7],
                ),
                selected: _days.contains(day),
                onSelected: (v) => setState(() {
                  if (v) {
                    _days.add(day);
                  } else {
                    _days.remove(day);
                  }
                }),
              ),
          ],
        ),
        _field(
          l10n.scheduledTime,
          OutlinedButton.icon(
            onPressed: () async {
              final time = await showTimePicker(
                context: context,
                initialTime: _time,
              );
              if (mounted && time != null) setState(() => _time = time);
            },
            icon: const Icon(Icons.schedule),
            label: Text(_time.format(context)),
          ),
        ),
      ],
    );
    final prompt = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(l10n.scheduledName, TextField(controller: _name)),
        Expanded(
          child: TextField(
            key: const ValueKey('scheduled-prompt'),
            controller: _prompt,
            expands: true,
            maxLines: null,
            minLines: null,
            textAlignVertical: TextAlignVertical.top,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l10n.scheduledPrompt,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.scheduledPromptHint),
      ],
    );
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: prompt,
                        ),
                      ),
                      SizedBox(
                        width: 320,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: config,
                        ),
                      ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      config,
                      SizedBox(height: 400, child: prompt),
                    ],
                  ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(l10n.scheduledRuntimeHint),
              TextButton(
                onPressed: _saving ? null : widget.onCancel,
                child: Text(l10n.scheduledCancel),
              ),
              FilledButton(
                onPressed:
                    _saving ||
                        _loading ||
                        _picking ||
                        _error != null ||
                        _preview == null ||
                        _days.isEmpty ||
                        _prompt.text.trim().isEmpty
                    ? null
                    : _save,
                child: Text(l10n.scheduledSave),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_changed);
    _generation++;
    _disposePreview();
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }
}
