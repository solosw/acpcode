import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_dialog.dart';
import '../../kernel/agent_kernel.dart';
import '../../kernel/kernel_types.dart';
import '../../l10n/l10n.dart';
import '../../settings/settings_dialog.dart'
    show SettingsOpener, SettingsSection;
import '../chat_session.dart';
import 'composer_picker.dart';

/// The pill that picks [session]'s model, each model's settings (its
/// effort, its context) beside it: the composer's, and the one a plan is
/// started with. Nothing where the kernel picks no model.
class SessionModelPicker extends StatelessWidget {
  const SessionModelPicker({
    super.key,
    required this.session,
    this.pickerKey,
    this.tooltip,
    this.tapRegionGroupId,
    this.focusNode,
  });

  final ChatSession session;

  /// The picker's own, to open it from a keybinding.
  final GlobalKey<ComposerPickerState>? pickerKey;

  /// See [ComposerPicker.tooltip], [ComposerPicker.tapRegionGroupId] and
  /// [ComposerPicker.focusNode].
  final String? tooltip;
  final Object? tapRegionGroupId;
  final FocusNode? focusNode;

  /// The model with its settings, e.g. "Opus · 1M · High": the context
  /// only when it is not the standard one; its upstream before it only
  /// when another upstream has a model of its name.
  String _label(KernelOption model, List<KernelOption> options) => [
    if (model.group case final group?
        when options.any(
          (other) => other.label == model.label && other.group?.id != group.id,
        ))
      group.label,
    model.label,
    for (final setting in session.modelSettings(model.id))
      if (setting.selected case final selected?
          when setting.kind != KernelChoiceKind.context ||
              selected != setting.options.first)
        selected.label,
  ].join(' · ');

  /// Runs [pick], which switches to [option]: once confirmed, if that
  /// restarts the agent on another upstream mid-conversation.
  Future<void> _switch(
    BuildContext context,
    KernelOption option,
    VoidCallback pick,
  ) async {
    if (!session.switchRestarts(option.id)) return pick();
    final l10n = context.l10n;
    final choice = await showIdeDialog(
      context,
      message: l10n.modelsSwitchTitle(option.group?.label ?? option.label),
      detail: l10n.modelsSwitchDetail,
      buttons: [l10n.modelsSwitchConfirm],
      type: IdeDialogType.question,
    );
    if (choice == 0 && context.mounted) pick();
  }

  @override
  Widget build(BuildContext context) {
    final model = session.models;
    if (model == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ComposerPicker(
      key: pickerKey,
      options: model.options,
      selected: model.selected,
      label: _label(model.selected, model.options),
      // Each its name alone, one line; its maker's logo and its upstream's
      // heading tell the rest.
      describes: false,
      settingsOf: (option) => [
        for (final setting in session.modelSettings(option.id))
          ModelSettingChoice(
            kind: setting.kind,
            options: setting.options,
            selected: setting.selected,
            toggle: setting.toggle,
            onSelected: (choice) => unawaited(
              _switch(context, option, () => setting.onSelected(choice)),
            ),
          ),
      ],
      tooltip: tooltip,
      menuWidth: 260,
      searchPlaceholder: l10n.modelsSearch,
      footer: switch (SettingsOpener.maybeOf(context)) {
        final open? => (
          label: l10n.modelsManage,
          icon: Icons.tune_rounded,
          onTap: () => open(SettingsSection.models),
        ),
        null => null,
      },
      tapRegionGroupId: tapRegionGroupId,
      focusNode: focusNode,
      onSelected: (option) =>
          unawaited(_switch(context, option, () => model.onSelected(option))),
    );
  }
}
