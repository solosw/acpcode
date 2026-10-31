import 'dart:async';

import 'package:bao_remote/client.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../remote/ssh_host.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'settings_widgets.dart';

Future<String?> showAgentRemoteFolderDialog(
  BuildContext context,
  String host,
) => showDialog<String>(
  context: context,
  builder: (_) => AgentRemoteFolderDialog(
    host: host,
    connect: () => SshHosts.instance[host].ready,
  ),
);

class AgentRemoteFolderDialog extends StatefulWidget {
  const AgentRemoteFolderDialog({
    super.key,
    required this.host,
    required this.connect,
  });
  final String host;
  final Future<RemoteClient> Function() connect;
  @override
  State<AgentRemoteFolderDialog> createState() =>
      _AgentRemoteFolderDialogState();
}

class _AgentRemoteFolderDialogState extends State<AgentRemoteFolderDialog> {
  RemoteClient? _client;
  String? _directory;
  List<String> _folders = [];
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load([String? directory]) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = _client ??= await widget.connect();
      final path = await client.realPath(
        directory ?? client.hello?.home ?? '/',
      );
      final folders = [
        for (final entry in await client.list(path, path))
          if (entry.isDirectory) entry.name,
      ]..sort();
      if (mounted) {
        setState(() {
          _directory = path;
          _folders = folders;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Dialog(
      backgroundColor: themeColors['editorWidget.background'],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('SSH: ${widget.host}', style: SettingsText.heading),
              const SizedBox(height: 8),
              Text(
                _directory ?? l10n.agentsChooseFolder,
                style: SettingsText.path,
              ),
              const SizedBox(height: 8),
              if (_busy) const LinearProgressIndicator(),
              if (_error case final error?) ...[
                Text(
                  error,
                  style: TextStyle(color: themeColors['errorForeground']),
                ),
                IdeButton(
                  label: l10n.agentsRetry,
                  onPressed: () => unawaited(_load(_directory)),
                ),
              ],
              if (!_busy && _error == null)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (_directory != null &&
                          p.posix.dirname(_directory!) != _directory)
                        ListTile(
                          title: const Text('..'),
                          onTap: () =>
                              unawaited(_load(p.posix.dirname(_directory!))),
                        ),
                      for (final folder in _folders)
                        ListTile(
                          leading: const Icon(Codicons.folder, size: 18),
                          title: Text(folder),
                          onTap: () => unawaited(
                            _load(p.posix.join(_directory!, folder)),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IdeButton(
                    label: l10n.commonCancel,
                    secondary: true,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: l10n.agentsSelectFolder,
                    onPressed: _busy || _error != null || _directory == null
                        ? null
                        : () => Navigator.pop(context, _directory),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
