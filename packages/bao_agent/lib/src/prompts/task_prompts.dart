/// The prompts of the agent's own errands: summaries, titles, checks.
library;

/// Asks for the conversation so far, summed up to go on from.
String compactPrompt([String? instructions]) {
  final extra = instructions == null || instructions.trim().isEmpty
      ? ''
      : '\n\nAdditional instructions from the user for this summary:\n${instructions.trim()}';
  return '''Your task is to create a detailed summary of the conversation so far. This summary will replace the conversation: the work goes on from it alone, so it must keep everything needed to continue without losing context.

Before the summary, think through the conversation in <analysis> tags: go through each message in order and note the user's explicit requests and intents, your approach, key decisions, technical concepts, file names, full code snippets and function signatures, file edits, errors met and how they were fixed, and any feedback from the user (especially where they asked you to do something differently).

Then write the summary in <summary> tags, with these sections:

1. Primary Request and Intent: all of the user's explicit requests and intents, in detail.
2. Key Technical Concepts: the technologies, frameworks and concepts discussed.
3. Files and Code Sections: the files examined, modified or created, with why each matters, a summary of the changes, and the important code snippets in full.
4. Errors and fixes: the errors met and how they were fixed, and what the user said about them.
5. Problem Solving: problems solved and troubleshooting under way.
6. All user messages: every message from the user that is not a tool result, verbatim or nearly so.
7. Pending Tasks: what you were explicitly asked to do and have not done yet.
8. Current Work: precisely what was being worked on immediately before this summary, with file names and code.
9. Optional Next Step: the next step in line with the most recent request, quoting the latest messages to show where the work left off. Only include one if it directly continues what the user asked for.$extra

Answer with the <analysis> and <summary> only; do not call any tools.''';
}

/// The message the conversation goes on from after it is compacted.
String compactedSummary(String summary, {String? transcriptPath}) {
  final cleaned = summary
      .replaceAll(RegExp(r'<analysis>[\s\S]*?</analysis>'), '')
      .replaceAllMapped(
        RegExp(r'<summary>([\s\S]*?)</summary>'),
        (m) => m[1]!.trim(),
      )
      .trim();
  return [
    'This session is being continued from a previous conversation that ran '
        'out of context. The summary below covers the earlier portion of the '
        'conversation.',
    '',
    'Summary:',
    cleaned,
    if (transcriptPath != null) ...[
      '',
      'If you need specific details from before compaction (like exact code '
          'snippets, error messages, or content you generated), read the full '
          'transcript at: $transcriptPath',
    ],
    '',
    'Continue the conversation from where it left off without asking the '
        'user any further questions. Resume directly — do not acknowledge the '
        'summary, do not recap what was happening, do not preface with "I\'ll '
        'continue" or similar. Pick up the last task as if the break never '
        'happened.',
  ].join('\n');
}

/// Asks for a title for the conversation.
const titleSystem =
    'You name conversations between a user and a coding agent. Answer with '
    'a title only: 3 to 7 words, in the language the user writes in, '
    'sentence case, no quotes, no trailing punctuation.';

String titlePrompt(String conversation) =>
    'Name this conversation:\n\n$conversation';

/// Asks what the user is likely to say next.
const suggestionSystem =
    'You predict the next message a user will send to their coding agent. '
    'Answer with that message only, as the user would type it: at most 12 '
    'words, in the language the user writes in, no quotes. Suggest only a '
    'natural, obvious next step the agent itself proposed or that clearly '
    'follows (such as running the tests, or committing the change). If '
    'there is none, answer with nothing at all.';

String suggestionPrompt(String conversation) =>
    'The conversation so far (most recent last):\n\n$conversation\n\n'
    'What will the user most likely send next?';

/// Asks whether a goal is met.
const goalCheckSystem =
    'You check whether a coding agent has met the goal its user set, from '
    'the conversation. Answer with a JSON object only: {"ok": true, '
    '"reason": "the evidence"} when the goal is met, or {"ok": false, '
    '"reason": "what is still missing"} when it is not. Be strict: the goal '
    'is met only when the conversation shows it plainly.';

String goalCheckPrompt(String condition, String conversation) =>
    'The goal:\n$condition\n\nThe conversation (most recent last):\n\n'
    '$conversation\n\nIs the goal met?';

/// Has auto mode's classifier judge an action.
const classifierSystem =
    'You review actions a coding agent wants to take on its user\'s machine, '
    'in auto mode: the user lets it act without asking, unless an action is '
    'risky. Allow what is plainly part of the task the user asked for and '
    'can be undone, or does not reach beyond the project (reading, building, '
    'testing, editing project files, local git commits). Block what could '
    'cause harm the user did not ask for: deleting or overwriting data '
    'outside the project, force-pushing, pushing to shared branches, '
    'publishing or deploying, sending data to unknown destinations, '
    'changing system or credential settings, installing software globally, '
    'running code downloaded from the internet, or anything the user said '
    'not to do. Answer with a JSON object only: {"decision": "allow"} or '
    '{"decision": "block", "reason": "why, briefly"}.';

String classifierPrompt(String transcript, String action) =>
    'What the user asked, and what the agent did so far (most recent '
    'last):\n\n$transcript\n\nThe action the agent wants to take now:\n\n'
    '$action\n\nAllow or block?';

/// The command that has the agent write the project's CLAUDE.md.
const initPrompt = '''Please analyze this codebase and create a CLAUDE.md file, which will be given to future instances of coding agents to operate in this repository.

What to add:
1. Commands that will be commonly used, such as how to build, lint, and run tests. Include the necessary commands to develop in this codebase, such as how to run a single test.
2. High-level code architecture and structure so that future instances can be productive more quickly. Focus on the "big picture" architecture that requires reading multiple files to understand.

Usage notes:
- If there's already a CLAUDE.md, suggest improvements to it.
- When you make the initial CLAUDE.md, do not repeat yourself and do not include obvious instructions like "Provide helpful error messages to users" or "Write unit tests for all new utilities".
- Avoid listing every component or file structure that can be easily discovered.
- Don't include generic development practices.
- If there are Cursor rules (in .cursor/rules/ or .cursorrules) or Copilot rules (in .github/copilot-instructions.md), make sure to include the important parts.
- If there is a README.md, make sure to include the important parts.
- Do not make up information such as "Common Development Tasks", "Tips for Development", "Support and Documentation" unless this is expressly included in other files that you read.
- Be sure to prefix the file with the following text:

```
# CLAUDE.md

This file provides guidance to coding agents when working with code in this repository.
```''';

/// The command that has the agent review the changes not committed.
String reviewPrompt(String args) =>
    '''You are an expert code reviewer. Review ${args.trim().isEmpty ? 'the current changes in this repository (staged and unstaged; use git status and git diff, and git diff against the main branch if the branch has commits of its own)' : args.trim()}.

Follow these steps:
1. Find the changes to review and read the code around them.
2. Analyze them for correctness, bugs and edge cases, security, performance, and how well they follow the project's conventions.
3. Report the issues you found, most severe first, each with the file and line, why it matters and a concrete fix. Say plainly when you found nothing worth changing.

Keep your review concise but thorough.''';

/// The command that has the agent review the branch for security issues.
const securityReviewPrompt = '''Complete a security review of the pending changes on the current branch (git diff against the main branch, and uncommitted changes).

Focus on vulnerabilities newly introduced by these changes that have real exploitation potential: injection (SQL, command, path traversal, template), authentication and authorization flaws, unsafe deserialization, secrets in code, cryptography misuse, data exposure, XSS and SSRF. Ignore style, denial of service, and theoretical issues without a plausible exploit path.

For each finding give: the file and line, the vulnerability category, the severity (high/medium/low), an exploit scenario, and a recommended fix. If there are none, say so.''';
