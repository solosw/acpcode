# Scheduled tasks

Open **Scheduled Tasks** directly below **Stash** in the main window's sidebar.

1. Create a task and choose Claude Code or a configured ACP agent.
2. Pick its mode, approvals, model and model-dependent settings. These are the
   conversation composer's live kernel choices, not a separate list of models
   or permission modes. Loading ACP choices starts its configured agent on the
   selected host; no prompt is sent by the editor.
3. Select the host and an already-open project (including multi-folder
   workspaces). To add another project, open it from the regular sidebar first.
4. Use the project or an existing Git working tree. The refresh button loads
   its working trees through the IDE's existing local/SSH Git service.
   Alternatively, create a new branch and working tree for each new run.
5. Start a fresh conversation each time, or reuse a conversation. Reuse can
   start with an existing conversation of the selected agent and working tree,
   or create one on the first run. For a newly created working tree, reuse
   keeps both the first conversation and its working tree.
6. Enter a prompt, select every day, weekdays or individual weekdays, and set
   the time in the scheduling computer's local time zone. Save enables the
   schedule immediately. A name is optional.

The task list supports **Run now**, editing, pause/resume, deletion, and opening
its last conversation. It shows the next scheduled time, last start time, and
execution errors. Pausing stops future triggers; stop an active agent in its
ordinary conversation. Deleting a task does not delete its conversations or
Git working trees/branches. Generated working trees are beside the project
and are not removed automatically.

## Execution and limits

The main window owns scheduling, including schedules targeting SSH hosts.
Keep this client running: this is not an OS service or a remote cron job.
Closed-app and sleeping-computer occurrences are skipped rather than replayed.
A 15-second timer dispatches within the scheduled minute; a trigger already a
minute late is skipped. The next occurrence is computed in calendar days, so
it stays at the selected local wall-clock time across daylight-saving changes.

A trigger uses Workspace to create/load an ordinary AgentThread, applies the
saved choices, then sends the prompt through ChatSession. It does not change
the focused conversation. Agent-specific skills, slash commands, approval
requests, results and errors work as they do for a manually sent message.
The scheduler does not automatically grant permissions or answer questions.
ACP configuration acknowledgments are awaited before its prompt is dispatched.

A task never overlaps itself, and a reused conversation already working,
waiting for an interaction, or running a background task is not interrupted or
queued into. The occurrence is skipped. Unavailable agents, saved sessions or
settings produce errors rather than silently substituting a different agent,
model, mode, conversation or host. Remote locations retain their SSH host;
they never fall back to local execution.

Tasks, prompts, choices, next times and last conversation references are kept
separately in `state/scheduled-tasks.json` under the configured app data directory.
They do not replace the workbench's existing state file.
