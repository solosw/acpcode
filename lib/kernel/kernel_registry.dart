import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'acp/acp_agent.dart';
import 'acp/acp_catalog.dart';
import 'acp/acp_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import '../remote/remote_claude.dart';

/// The kernels the user can pick from. Another kernel is an adapter and a
/// line here.
abstract final class KernelRegistry {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      // On the project's host: this machine, or a remote one's.
      start: startClaude,
      readHistory: readClaudeHistory,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  /// Builds a descriptor for an externally configured ACP agent.
  static KernelDescriptor acp(AcpAgentConfig config) {
    late final KernelDescriptor descriptor;
    final catalog = AcpCatalog(agentId: config.id);
    descriptor = KernelDescriptor(
      id: config.id,
      label: config.label,
      icon: Icons.hub_rounded,
      description: config.description,
      catalog: catalog,
      create: (context) => AcpKernel(
        descriptor,
        context,
        config.transport,
        catalog: catalog,
      ),
    );
    return descriptor;
  }

  static List<KernelDescriptor> _all = [claudeCode];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
