import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';

const options = [
  KernelOption('first', 'Agent first', Icons.code, ''),
  KernelOption('second', 'Agent second', Icons.code, ''),
];

class TaskTestKernel
    with KernelEventSource
    implements AgentKernel, SelectsModel, SelectsMode, SelectsFast {
  TaskTestKernel(this.descriptor, this.context) {
    model = LocalChoice(options, onChanged: (_) => emitInfoChanged());
    mode = LocalChoice(options, onChanged: (_) => emitInfoChanged());
    sessionId = context.resume?.id;
  }
  @override
  final KernelDescriptor descriptor;
  final KernelContext context;
  @override
  late final TaskTestToggle fast = TaskTestToggle(emitInfoChanged);
  @override
  late final LocalChoice model;
  @override
  late final LocalChoice mode;
  @override
  KernelHealth health = KernelHealth.idle;
  @override
  String? sessionId;
  final sent = <KernelTurn>[];
  bool autoFinish = true;
  bool disposed = false;
  @override
  void send(KernelTurn turn) {
    sent.add(turn);
    sessionId ??= 'session-${identityHashCode(this)}';
    emit(TurnStarted(nextSeq, turn.id));
    emit(ItemUpserted(nextSeq, turn.id, UserMessageItem(text: turn.text)));
    if (autoFinish) finish();
  }

  void finish() => emit(TurnEnded(nextSeq, sent.last.id));
  @override
  void prepare() {
    health = KernelHealth.ready;
    scheduleMicrotask(emitInfoChanged);
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {}
  @override
  void cancel() {}
  @override
  void restart() => prepare();
  @override
  void release() {}
  @override
  void dispose() {
    disposed = true;
    closeEvents();
  }

  @override
  Future<void> get stopped async {}
}

class TaskTestToggle implements ModelSetting {
  TaskTestToggle(this.changed);
  final VoidCallback changed;
  bool enabled = false;
  @override
  bool get toggle => true;
  @override
  List<KernelOption> optionsFor(String model) => const [
    KernelOption('fast', 'Fast', Icons.bolt, ''),
  ];
  @override
  String get selected => enabled ? 'fast' : 'standard';
  @override
  String selectedFor(String model) => selected;
  @override
  void select(String model, String id) {
    enabled = !enabled;
    changed();
  }
}

class TaskTestCatalog implements SessionCatalog {
  final records = <SessionRecord>[];
  @override
  Future<List<ProjectRecord>> projects() async => const [];
  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async =>
      records.where((r) => r.cwd == cwd).toList();
  @override
  Future<void> delete(String id) async =>
      records.removeWhere((r) => r.id == id);
}

KernelDescriptor taskDescriptor(
  List<TaskTestKernel> created, {
  String id = 'claude-code',
  TaskTestCatalog? catalog,
}) {
  late final KernelDescriptor descriptor;
  descriptor = KernelDescriptor(
    id: id,
    label: id == 'claude-code' ? 'Claude Code' : 'Custom ACP',
    icon: Icons.code,
    description: '',
    catalog: catalog,
    create: (context) {
      final kernel = TaskTestKernel(descriptor, context);
      created.add(kernel);
      return kernel;
    },
  );
  return descriptor;
}
