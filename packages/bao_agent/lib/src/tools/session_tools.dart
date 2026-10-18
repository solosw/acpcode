import 'dart:io';

import '../engine/session.dart';
import '../permissions/decision.dart';
import '../util/json.dart';
import 'tool.dart';

/// Keeps the agent's todo list.
class TodoWriteTool extends Tool {
  const TodoWriteTool();

  @override
  String get name => 'TodoWrite';

  @override
  String get description => '''Use this tool to create and manage a structured task list for your current coding session. This helps you track progress, organize complex tasks, and demonstrate thoroughness to the user.
It also helps the user understand the progress of the task and progress of their requests.

## When to Use This Tool
Use this tool proactively in these scenarios:

1. Complex multi-step tasks - When a task requires 3 or more distinct steps or actions
2. Non-trivial and complex tasks - Tasks that require careful planning or multiple operations
3. User explicitly requests todo list - When the user directly asks you to use the todo list
4. User provides multiple tasks - When users provide a list of things to be done (numbered or comma-separated)
5. After receiving new instructions - Immediately capture user requirements as todos
6. When you start working on a task - Mark it as in_progress BEFORE beginning work. Ideally you should only have one todo as in_progress at a time
7. After completing a task - Mark it as completed and add any new follow-up tasks discovered during implementation

## When NOT to Use This Tool

Skip using this tool when:
1. There is only a single, straightforward task
2. The task is trivial and tracking it provides no organizational benefit
3. The task can be completed in less than 3 trivial steps
4. The task is purely conversational or informational

## Task States and Management

1. **Task States**: Use these states to track progress:
   - pending: Task not yet started
   - in_progress: Currently working on (limit to ONE task at a time)
   - completed: Task finished successfully

   **IMPORTANT**: Task descriptions must have two forms:
   - content: The imperative form describing what needs to be done (e.g., "Run tests", "Build the project")
   - activeForm: The present continuous form shown during execution (e.g., "Running tests", "Building the project")

2. **Task Management**:
   - Update task status in real-time as you work
   - Mark tasks complete IMMEDIATELY after finishing (don't batch completions)
   - Exactly ONE task must be in_progress at any time (not less, not more)
   - Complete current tasks before starting new ones
   - Remove tasks that are no longer relevant from the list entirely

3. **Task Completion Requirements**:
   - ONLY mark a task as completed when you have FULLY accomplished it
   - If you encounter errors, blockers, or cannot finish, keep the task as in_progress
   - Never mark a task as completed if tests are failing, implementation is partial, or you encountered unresolved errors

When in doubt, use this tool. Being proactive with task management demonstrates attentiveness and ensures you complete all requirements successfully.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'todos': {
        'type': 'array',
        'description': 'The updated todo list',
        'items': {
          'type': 'object',
          'properties': {
            'content': {'type': 'string', 'minLength': 1},
            'status': {
              'type': 'string',
              'enum': ['pending', 'in_progress', 'completed'],
            },
            'activeForm': {'type': 'string', 'minLength': 1},
          },
          'required': ['content', 'status', 'activeForm'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['todos'],
    'additionalProperties': false,
  };

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final key = context.run.agentId ?? context.session.sessionId;
    final old = context.session.todos[key] ?? const [];
    final todos = [
      for (final raw in asList(input['todos']))
        {
          'content': '${asMap(raw)['content'] ?? ''}',
          'status': '${asMap(raw)['status'] ?? 'pending'}',
          'activeForm':
              '${asMap(raw)['activeForm'] ?? asMap(raw)['content'] ?? ''}',
        },
    ];
    // All done: the list is cleared.
    final kept = todos.every((todo) => todo['status'] == 'completed')
        ? <Map<String, Object?>>[]
        : todos;
    context.session.todos[key] = kept;
    return ToolOutput(
      'Todos have been modified successfully. Ensure that you continue to use '
      'the todo list to track your progress. Please proceed with the current '
      'tasks if applicable',
      result: {'oldTodos': old, 'newTodos': todos},
    );
  }
}

/// Puts questions to the user, with options to pick.
class AskUserQuestionTool extends Tool {
  const AskUserQuestionTool();

  @override
  String get name => 'AskUserQuestion';

  @override
  String get description => '''Use this tool when you need to ask the user questions during execution. This allows you to:
1. Gather user preferences or requirements
2. Clarify ambiguous instructions
3. Get decisions on implementation choices as you work
4. Offer choices to the user about what direction to take.

Usage notes:
- Users will always be able to select "Other" to provide custom text input
- Use multiSelect: true to allow multiple answers to be selected for a question
- If you recommend a specific option, make that the first option in the list and add "(Recommended)" at the end of the label

Plan mode note: In plan mode, use this tool to clarify requirements or choose between approaches BEFORE finalizing your plan. Do NOT use this tool to ask "Is my plan ready?" or "Should I proceed?" - use ExitPlanMode for plan approval.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 4,
        'description': 'Questions to ask the user (1-4 questions)',
        'items': {
          'type': 'object',
          'properties': {
            'question': {
              'type': 'string',
              'description': 'The complete question to ask the user. Should be clear, specific, and end with a question mark.',
            },
            'header': {
              'type': 'string',
              'description': 'Very short label displayed as a chip/tag (max 12 chars). Examples: "Auth method", "Library", "Approach".',
            },
            'options': {
              'type': 'array',
              'minItems': 2,
              'maxItems': 4,
              'description': 'The available choices for this question. Must have 2-4 options. There should be no "Other" option, that will be provided automatically.',
              'items': {
                'type': 'object',
                'properties': {
                  'label': {
                    'type': 'string',
                    'description':
                        'The display text for this option (1-5 words).',
                  },
                  'description': {
                    'type': 'string',
                    'description': 'Explanation of what this option means or what will happen if chosen.',
                  },
                  'preview': {
                    'type': 'string',
                    'description': 'Optional preview content (a mockup, code snippet) shown when this option is focused.',
                  },
                },
                'required': ['label', 'description'],
              },
            },
            'multiSelect': {
              'type': 'boolean',
              'default': false,
              'description': 'Set to true to allow the user to select multiple options instead of just one.',
            },
          },
          'required': ['question', 'header', 'options', 'multiSelect'],
        },
      },
      'answers': {
        'type': 'object',
        'description': 'User answers collected by the permission component',
      },
      'annotations': {
        'type': 'object',
        'description': 'Optional per-question annotations from the user',
      },
      'metadata': {
        'type': 'object',
        'description': 'Optional metadata for tracking and analytics purposes.',
      },
    },
    'required': ['questions'],
    'additionalProperties': false,
  };

  @override
  bool get requiresUserInteraction => true;

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAsk(
    message: 'Answer questions?',
    requiresUserInteraction: true,
    classifierApprovable: false,
  );

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final questions = asList(input['questions']);
    final texts = <String>{};
    for (final q in questions) {
      final question = '${asMap(q)['question'] ?? ''}';
      if (!texts.add(question)) return 'Question texts must be unique';
      final labels = <String>{};
      for (final option in asList(asMap(q)['options'])) {
        if (!labels.add('${asMap(option)['label'] ?? ''}')) {
          return 'Option labels must be unique within each question';
        }
      }
    }
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final answers = asMap(input['answers']);
    if (answers.isEmpty) {
      return ToolOutput.error('The user did not answer the questions.');
    }
    final said = [
      for (final MapEntry(:key, :value) in answers.entries) '"$key"="$value"',
    ].join(', ');
    return ToolOutput(
      'User has answered your questions: $said. You can now continue with '
      "the user's answers in mind.",
      result: {'questions': input['questions'], 'answers': answers},
    );
  }
}

/// Enters plan mode: the agent explores and plans before it changes
/// anything.
class EnterPlanModeTool extends Tool {
  const EnterPlanModeTool();

  @override
  String get name => 'EnterPlanMode';

  @override
  String get description => '''Use this tool proactively when you're about to start a non-trivial implementation task. Getting user sign-off on your approach before writing code prevents wasted effort and ensures alignment. This tool transitions you into plan mode where you can explore the codebase and design an implementation approach for user approval.

## When to Use This Tool

Prefer using EnterPlanMode for implementation tasks unless they're simple. Use it when ANY of these conditions apply:
1. New feature implementation that needs architectural decisions
2. Multiple valid approaches exist and the choice matters
3. Code modifications that affect existing behavior or structure
4. Changes that touch more than 2-3 files
5. Unclear requirements where you need to explore before understanding the full scope

## When NOT to Use This Tool

Skip EnterPlanMode for simple tasks: single-line or few-line fixes, adding a single function with clear requirements, tasks where the user has given very specific detailed instructions, or pure research/exploration tasks.

## What Happens in Plan Mode

In plan mode, you'll:
1. Thoroughly explore the codebase using Glob, Grep, and Read tools
2. Understand existing patterns and architecture
3. Design an implementation approach
4. Write the plan to the plan file, then use ExitPlanMode to present it to the user for approval
5. Use AskUserQuestion if you need to clarify approaches

This tool REQUIRES user approval - they must consent to entering plan mode.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
    'additionalProperties': false,
  };

  @override
  bool get changesMode => true;

  @override
  bool isEnabled(AgentSession session) => session.permissionMode != 'plan';

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAsk(message: 'Enter plan mode?');

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    if (!context.run.isMain) {
      return ToolOutput.error(
        'EnterPlanMode tool cannot be used in agent contexts',
      );
    }
    context.session.setPermissionMode('plan', byModel: true);
    return ToolOutput(
      'Entered plan mode. You should now focus on exploring the codebase and '
      'designing an implementation approach.\n\n'
      'In plan mode, you should:\n'
      '1. Thoroughly explore the codebase to understand existing patterns\n'
      '2. Identify similar features and architectural approaches\n'
      '3. Consider multiple approaches and their trade-offs\n'
      '4. Use AskUserQuestion if you need to clarify the approach\n'
      '5. Design a concrete implementation strategy\n'
      '6. When ready, write the plan to the plan file and use ExitPlanMode '
      'to present it for approval\n\n'
      'Remember: DO NOT write or edit any files yet, except the plan file. '
      'This is a read-only exploration and planning phase.',
      result: {'message': 'Entered plan mode'},
    );
  }
}

/// Puts the plan written to the user, to be started.
class ExitPlanModeTool extends Tool {
  const ExitPlanModeTool();

  @override
  String get name => 'ExitPlanMode';

  @override
  String get description => '''Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval.

## How This Tool Works
- You should have already written your plan to the plan file specified in the plan mode system message
- This tool does NOT take the plan content as a parameter - it will read the plan from the file you wrote
- This tool simply signals that you're done planning and ready for the user to review and approve
- The user will see the contents of your plan file when they review it

## When to Use This Tool
IMPORTANT: Only use this tool when the task requires planning the implementation steps of a task that requires writing code. For research tasks where you're gathering information, searching files, reading files or in general trying to understand the codebase - do NOT use this tool.

## Before Using This Tool
Ensure your plan is complete and unambiguous:
- If you have unresolved questions about requirements or approach, use AskUserQuestion first (in earlier phases)
- Once your plan is finalized, use THIS tool to request approval

**Important:** Do NOT use AskUserQuestion to ask "Is this plan okay?" or "Should I proceed?" - that's exactly what THIS tool does.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'plan': {
        'type': 'string',
        'description': 'The plan, if not written to the plan file (it is read from the file otherwise)',
      },
    },
    'additionalProperties': true,
  };

  @override
  bool get changesMode => true;

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  /// The plan written, and where, for the user to see.
  @override
  Map<String, Object?> observableInput(
    Map<String, Object?> input,
    AgentSession session,
  ) {
    if (input['plan'] is String && input['planFilePath'] is String) {
      return input;
    }
    final path = session.planFilePath;
    String? plan = asString(input['plan']);
    if (plan == null) {
      try {
        plan = File(path).readAsStringSync();
      } on FileSystemException {
        plan = null;
      }
    }
    return {...input, 'plan': ?plan, 'planFilePath': path};
  }

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAsk(
    message: 'Exit plan mode?',
    requiresUserInteraction: true,
    classifierApprovable: false,
  );

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final session = context.session;
    final path = session.planFilePath;
    String? plan = asText(input['plan']);
    final file = File(path);
    if (plan == null && file.existsSync()) plan = file.readAsStringSync();
    if (session.permissionMode == 'plan') {
      session.setPermissionMode(
        session.modeBeforePlan ?? 'default',
        byModel: true,
      );
    }
    return ToolOutput(
      plan == null
          ? 'User has approved exiting plan mode. You can now proceed.'
          : 'User has approved your plan. You can now start coding. Start '
                'with updating your todo list if applicable\n\n'
                'Your plan has been saved to: $path\n'
                'You can refer back to it if needed during implementation.\n\n'
                '## Approved Plan:\n$plan',
      result: {'plan': plan, 'isAgent': !context.run.isMain, 'filePath': path},
    );
  }
}
