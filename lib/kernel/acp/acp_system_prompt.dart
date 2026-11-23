import '../agent_kernel.dart';
import '../claude_code/claude_core_setting.dart';

/// What the ACP agent advertised for client-provided system prompts during
/// `initialize` (ACP v1 `sessionCapabilities.systemPrompt` and v2
/// `session.systemPrompt`).
class AcpSystemPromptCapabilities {
  const AcpSystemPromptCapabilities({
    this.supported = false,
    this.override = false,
  });

  /// Agent accepts `systemPrompt` with `mode: "append"`.
  final bool supported;

  /// Agent additionally accepts `mode: "override"`.
  final bool override;

  factory AcpSystemPromptCapabilities.parse(
    Map<String, Object?>? agentCapabilities,
  ) {
    if (agentCapabilities == null) return const AcpSystemPromptCapabilities();
    final v1 = _asMap(agentCapabilities['sessionCapabilities']);
    final v2 = _asMap(agentCapabilities['session']);
    final raw = v1 != null && v1.containsKey('systemPrompt')
        ? v1['systemPrompt']
        : v2 != null && v2.containsKey('systemPrompt')
        ? v2['systemPrompt']
        : null;
    if (raw == null || raw == false) {
      return const AcpSystemPromptCapabilities();
    }
    if (raw == true) {
      return const AcpSystemPromptCapabilities(supported: true);
    }
    if (raw is! Map) {
      return const AcpSystemPromptCapabilities();
    }
    final mode = _asMap(raw['mode']);
    final supportsOverride =
        (mode != null &&
            mode.containsKey('override') &&
            mode['override'] != false &&
            mode['override'] != null) ||
        raw['override'] == true;
    return AcpSystemPromptCapabilities(
      supported: true,
      override: supportsOverride,
    );
  }

  static Map<String, Object?>? _asMap(Object? value) =>
      value is Map ? value.cast<String, Object?>() : null;
}

/// Resolved `systemPrompt` request parameter and any user-facing warnings when
/// configured instructions could not be delivered to an older or limited agent.
class AcpSystemPromptResolution {
  const AcpSystemPromptResolution({this.param, this.warnings = const []});

  /// Ready to pass as `params['systemPrompt']` in `session/new` and
  /// `session/load`, or null when omitted. Never has an empty content array.
  final Map<String, Object?>? param;
  final List<String> warnings;
}

/// Combines BaoCode's built-in core system prompt setting ([corePrompt]),
/// workspace instructions ([workspace]), and optional installed skills catalog
/// ([skillsSection]) according to the ACP agent's advertised [capabilities].
AcpSystemPromptResolution resolveAcpSystemPrompt({
  required AcpSystemPromptCapabilities capabilities,
  required CoreSystemPrompt corePrompt,
  KernelWorkspace? workspace,
  String? skillsSection,
}) {
  if (workspace != null && workspace.ownPrompt) {
    final own = workspace.instructions.trim();
    if (own.isEmpty) return const AcpSystemPromptResolution();
    if (capabilities.override) {
      return AcpSystemPromptResolution(param: _payload('override', own));
    }
    if (capabilities.supported) {
      return AcpSystemPromptResolution(
        param: _payload('append', own),
        warnings: const [
          'This ACP agent does not support replacing its system prompt (override); '
              'custom instructions were appended instead.',
        ],
      );
    }
    return const AcpSystemPromptResolution(
      warnings: [
        'This ACP agent does not advertise systemPrompt support; '
            'custom system prompt instructions were not sent.',
      ],
    );
  }

  final extras = _join([workspace?.instructions, skillsSection]);

  if (corePrompt.coreOverride case final overrideText?) {
    final combined = _join([overrideText, extras]);
    if (capabilities.override) {
      return AcpSystemPromptResolution(param: _payload('override', combined));
    }
    if (capabilities.supported) {
      return AcpSystemPromptResolution(
        param: extras.isEmpty ? null : _payload('append', extras),
        warnings: const [
          'This ACP agent does not support replacing its system prompt (override); '
              'the Built-in Core Replace system prompt setting was not applied.',
        ],
      );
    }
    return const AcpSystemPromptResolution(
      warnings: [
        'This ACP agent does not advertise systemPrompt support; '
            'the Built-in Core custom system prompt setting was not applied.',
      ],
    );
  }

  if (corePrompt.appended case final appendedText?) {
    final combined = _join([appendedText, extras]);
    if (capabilities.supported) {
      return AcpSystemPromptResolution(param: _payload('append', combined));
    }
    return const AcpSystemPromptResolution(
      warnings: [
        'This ACP agent does not advertise systemPrompt support; '
            'the Built-in Core custom system prompt setting was not applied.',
      ],
    );
  }

  if (extras.isNotEmpty && capabilities.supported) {
    return AcpSystemPromptResolution(param: _payload('append', extras));
  }
  return const AcpSystemPromptResolution();
}

Map<String, Object?> _payload(String mode, String text) => {
  'mode': mode,
  'content': [
    {'type': 'text', 'text': text},
  ],
};

String _join(Iterable<String?> parts) => [
  for (final part in parts)
    if (part != null && part.trim().isNotEmpty) part.trim(),
].join('\n\n');
