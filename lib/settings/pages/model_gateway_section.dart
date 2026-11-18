import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../l10n/l10n.dart';
import '../../models/gateway/gateway_settings.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'settings_widgets.dart';

/// The local model gateway, beside the upstreams it serves.
class ModelGatewaySection extends StatefulWidget {
  const ModelGatewaySection({super.key, required this.gateway});

  final ModelGateway gateway;

  @override
  State<ModelGatewaySection> createState() => _ModelGatewaySectionState();
}

class _ModelGatewaySectionState extends State<ModelGatewaySection> {
  final _port = TextEditingController();
  final _key = TextEditingController();
  late GatewayConfig _seen;
  bool _useNetworkProxy = true;
  bool _showKey = false;
  bool _saving = false;
  String? _portError;
  String? _keyError;
  String? _saveError;

  ModelGateway get _gateway => widget.gateway;

  bool get _dirty =>
      _port.text != _gateway.config.port.toString() ||
      _key.text != _gateway.config.apiKey ||
      _useNetworkProxy != _gateway.config.useNetworkProxy;

  @override
  void initState() {
    super.initState();
    _read();
    _gateway.addListener(_changed);
  }

  @override
  void didUpdateWidget(ModelGatewaySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != _gateway) {
      oldWidget.gateway.removeListener(_changed);
      _read();
      _gateway.addListener(_changed);
    }
  }

  void _read() {
    _seen = _gateway.config;
    _port.text = _seen.port.toString();
    _key.text = _seen.apiKey;
    _useNetworkProxy = _seen.useNetworkProxy;
  }

  void _changed() {
    if (!mounted) return;
    // A runtime status update must not discard a port or key being edited.
    final untouched =
        _port.text == _seen.port.toString() &&
        _key.text == _seen.apiKey &&
        _useNetworkProxy == _seen.useNetworkProxy;
    setState(() {
      if (untouched) _read();
      _seen = _gateway.config;
    });
  }

  @override
  void dispose() {
    _gateway.removeListener(_changed);
    _port.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save({bool? enabled}) async {
    if (_saving) return;
    final l10n = context.l10n;
    // Stopping remains possible even while a draft port or key is invalid.
    final stopping = enabled == false;
    final port = stopping ? _gateway.config.port : int.tryParse(_port.text);
    final key = stopping ? _gateway.config.apiKey : _key.text;
    setState(() {
      _portError = port == null || port < 1 || port > 65535
          ? l10n.modelsGatewayPortInvalid
          : null;
      _keyError = key.isEmpty || key.codeUnits.any((c) => c <= 32 || c >= 127)
          ? l10n.modelsGatewayKeyInvalid
          : null;
      _saveError = null;
    });
    if (_portError != null || _keyError != null) return;
    setState(() => _saving = true);
    try {
      await _gateway.update(
        GatewayConfig(
          enabled: enabled ?? _gateway.config.enabled,
          port: port!,
          apiKey: key,
          useNetworkProxy: stopping
              ? _gateway.config.useNetworkProxy
              : _useNetworkProxy,
        ),
      );
      if (mounted && !stopping) setState(_read);
    } on Object catch (error) {
      if (mounted) setState(() => _saveError = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final busy = _saving || _gateway.starting;
    final error = _saveError ?? _gateway.error;
    final address = _gateway.running ? _gateway.baseUrl : null;
    return SettingsGroup(
      title: l10n.modelsGatewayTitle,
      description: l10n.modelsGatewayDescription,
      children: [
        SettingsSwitchRow(
          label: l10n.modelsGatewayEnable,
          description: l10n.modelsGatewayEnableDescription,
          value: _gateway.config.enabled,
          enabled: !busy,
          onChanged: (value) => unawaited(_save(enabled: value)),
        ),
        SettingsRow(
          label: l10n.modelsGatewayPort,
          description: l10n.modelsGatewayPortDescription,
          trailing: SizedBox(
            width: 220,
            child: IgnorePointer(
              ignoring: busy,
              child: IdeInputBox(
                controller: _port,
                semanticsLabel: l10n.modelsGatewayPort,
                validation: _portError == null
                    ? null
                    : IdeInputValidation(_portError!),
                onChanged: (_) => setState(() => _portError = null),
                onSubmitted: (_) => unawaited(_save()),
              ),
            ),
          ),
        ),
        SettingsRow(
          label: l10n.modelsGatewayKey,
          description: l10n.modelsGatewayKeyDescription,
          trailing: SizedBox(
            width: 220,
            child: IgnorePointer(
              ignoring: busy,
              child: IdeInputBox(
                controller: _key,
                semanticsLabel: l10n.modelsGatewayKey,
                obscureText: !_showKey,
                validation: _keyError == null
                    ? null
                    : IdeInputValidation(_keyError!),
                onChanged: (_) => setState(() => _keyError = null),
                onSubmitted: (_) => unawaited(_save()),
                toggles: [
                  IdeInputToggle(
                    icon: _showKey ? Codicons.eyeClosed : Codicons.eye,
                    tooltip: _showKey
                        ? l10n.modelsApiKeyHide
                        : l10n.modelsApiKeyShow,
                    checked: false,
                    onChanged: (_) => setState(() => _showKey = !_showKey),
                  ),
                ],
              ),
            ),
          ),
        ),
        SettingsSwitchRow(
          label: l10n.modelsGatewayProxy,
          description: l10n.modelsGatewayProxyDescription,
          value: _useNetworkProxy,
          enabled: !busy,
          onChanged: (value) => setState(() => _useNetworkProxy = value),
        ),
        SettingsRow(
          label: busy
              ? l10n.modelsGatewayStarting
              : _gateway.running
              ? l10n.modelsGatewayRunning
              : l10n.modelsGatewayStopped,
          below: [
            if (address != null)
              SelectableText(address, style: SettingsText.path),
            Text(l10n.modelsGatewayModelIds, style: SettingsText.description),
            if (error != null)
              SelectableText(
                l10n.modelsGatewayError(error),
                style: SettingsText.description.copyWith(
                  color: themeColors['errorForeground'],
                ),
              ),
          ],
          trailing: SettingsButtons(
            children: [
              if (address != null)
                IdeButton(
                  label: l10n.modelsGatewayCopyAddress,
                  icon: Codicons.copy,
                  secondary: true,
                  onPressed: () => unawaited(
                    Clipboard.setData(ClipboardData(text: address)),
                  ),
                ),
              IdeButton(
                label: l10n.modelsGatewayApply,
                spinning: busy,
                onPressed: busy || (!_dirty && error == null)
                    ? null
                    : () => unawaited(_save()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
