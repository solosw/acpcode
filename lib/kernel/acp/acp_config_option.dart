import 'package:flutter/widgets.dart';

import '../agent_kernel.dart';
import '../kernel_types.dart';

/// One select option advertised by an ACP agent. Its value changes only when
/// the agent reports the complete config state, not when a change is requested.
class AcpConfigOption implements KernelChoiceSource {
  AcpConfigOption(this.icon, this.onChanged);

  final IconData icon;
  final void Function(String configId, String value) onChanged;
  String? configId;

  @override
  List<KernelOption> options = const [];

  @override
  String? selected;

  void replace(Map? config) {
    configId = null;
    selected = null;
    options = const [];
    if (config == null ||
        config['type'] != 'select' ||
        config['id'] is! String ||
        config['currentValue'] is! String ||
        config['options'] is! List) {
      return;
    }
    configId = config['id'] as String;
    selected = config['currentValue'] as String;
    final values = <KernelOption>[];
    void addValue(Object? raw, [KernelOptionGroup? group]) {
      if (raw is! Map || raw['value'] is! String || raw['name'] is! String) {
        return;
      }
      values.add(
        KernelOption(
          raw['value'] as String,
          raw['name'] as String,
          icon,
          raw['description'] is String ? raw['description'] as String : '',
          group: group,
        ),
      );
    }

    for (final value in config['options'] as List) {
      if (value is Map && value['options'] is List) {
        if (value['group'] is! String || value['name'] is! String) continue;
        final group = KernelOptionGroup(
          value['group'] as String,
          value['name'] as String,
        );
        for (final option in value['options'] as List) {
          addValue(option, group);
        }
      } else {
        addValue(value);
      }
    }
    options = values;
  }

  @override
  void select(String id) {
    final configId = this.configId;
    if (configId == null || id == selected || !options.any((o) => o.id == id)) {
      return;
    }
    onChanged(configId, id);
  }
}

/// Reasoning values belong to the model currently in use. Another model's
/// values are not known until its set_config_option response arrives.
class AcpThoughtLevel implements ModelSetting {
  AcpThoughtLevel(this.option, this.model);

  final AcpConfigOption option;
  final AcpConfigOption model;

  @override
  List<KernelOption> optionsFor(String model) =>
      this.model.options.isEmpty || model == this.model.selected
      ? option.options
      : const [];

  @override
  bool get toggle => false;

  @override
  String? get selected => option.selected;

  @override
  String? selectedFor(String model) =>
      optionsFor(model).isEmpty ? null : selected;

  @override
  void select(String model, String id) {
    if (optionsFor(model).any((o) => o.id == id)) option.select(id);
  }
}
