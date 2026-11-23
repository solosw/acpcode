import 'dart:io';

import 'package:path/path.dart' as p;

import '../../customize/customization_store.dart';
import '../../customize/customizations.dart';
import '../../remote/remote_customization_disk.dart';
import '../../remote/remote_location.dart';
import '../../remote/ssh_host.dart';
import '../agent_kernel.dart';
import '../extension_switches.dart';
import 'acp_skills.dart';

Future<AcpSkills> loadAcpSkills(
  KernelContext context, {
  Map<String, String> environment = const {},
  ExtensionSwitches? switches,
}) async {
  final location = context.cwd ?? context.resume?.cwd;
  final hostName = location == null ? null : RemoteLocation.hostOf(location);
  final project = location == null ? null : RemoteLocation.pathOf(location);
  final host = hostName == null ? null : SshHosts.instance[hostName];
  final customHome =
      environment['HOME'] ??
      (host == null && Platform.isWindows ? environment['USERPROFILE'] : null);
  final paths = host == null ? p.context : p.posix;
  final store = CustomizationStore(
    configDir:
        environment['CLAUDE_CONFIG_DIR'] ??
        (customHome == null ? null : paths.join(customHome, '.claude')),
    homeDir: customHome,
    disk: host == null ? null : RemoteCustomizationDisk(host),
  );
  return loadAcpSkillsFromStore(
    store,
    project: project,
    switches: switches ?? ExtensionSwitches.current(),
  );
}

/// Loads enabled BaoCode skills from [store] for [project], with project skills
/// taking precedence over user and synced skills of the same name.
Future<AcpSkills> loadAcpSkillsFromStore(
  CustomizationStore store, {
  String? project,
  ExtensionSwitches switches = ExtensionSwitches.none,
}) async {
  final List<Customization> items;
  try {
    items = await store.list(CustomizationKind.skills, project: project);
  } on Object {
    return const AcpSkills();
  }
  if (items.isEmpty) return const AcpSkills();
  int priority(CustomizationScope scope) => switch (scope) {
    CustomizationScope.synced => 0,
    CustomizationScope.user => 1,
    CustomizationScope.project => 2,
    CustomizationScope.local => 3,
    CustomizationScope.plugin => 0,
  };
  final effective = <String, Customization>{};
  for (final item in items) {
    if (item.kind != CustomizationKind.skills || item.unreachable) continue;
    final previous = effective[item.name];
    if (previous == null || priority(item.scope) >= priority(previous.scope)) {
      effective[item.name] = item;
    }
  }
  final skills = <AcpSkill>[];
  for (final item in effective.values) {
    if (!switches.skillEnabled(item.name)) continue;
    final String markdown;
    try {
      markdown = await store.read(item.path);
    } on Object {
      continue;
    }
    skills.add(
      AcpSkill.fromMarkdown(
        fallbackName: item.name,
        path: item.path,
        baseDir: store.paths.dirname(item.path),
        markdown: markdown,
      ),
    );
  }
  skills.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return AcpSkills(skills: skills);
}
