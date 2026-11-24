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

## Start script

A task can have a start script that decides whether a run happens. Before each
run, BaoCode runs it in the project (or working tree) folder on the project's
host: `sh -c` on macOS and Linux, `cmd.exe /c` on Windows, over the existing
SSH connection for remote projects. It gets at most 10 minutes.

- Output on stdout: the run goes ahead with the selected agent, Claude Code or
  ACP. The message is the prompt followed by the output, or just the output
  when the prompt is empty.
- No output: the run is skipped and no conversation is created.
- Non-zero exit: the run is skipped and the task shows the error with stderr.

For example, `gh issue list --label triage --json number,title` with the
prompt "Triage these issues:" only wakes an agent when there are issues.

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

## Creating a task through MCP

When conversation tools are enabled in **Settings → General**, a project agent
can call BaoCode’s `scheduled_task_create` tool at the user’s request. The tool
saves an enabled task without running it immediately. It selects the default
agent at creation and leaves the model at its default. Omit `project` to use the
calling project, or give an open project’s name or exact path (including SSH).

Example: every weekday at 09:00 in the BaoCode computer’s local time zone.

```json
{
  "name": "Daily summary",
  "prompt": "Summarize recent project changes without editing files.",
  "schedule": {"type": "calendar", "hour": 9, "minute": 0, "days": [1, 2, 3, 4, 5]}
}
```

For other schedules, use `{"type": "interval", "minutes": 30}` or
`{"type": "cron", "expression": "0 9 * * 1-5"}`. Each run starts a new
conversation unless the script skips it.

Pass a shell script in `script` to check a condition before opening a
conversation. Supply `prompt`, `script`, or both. For a Gitea-backed project,
configure the selected project’s `origin` and Git credentials, then schedule
an interval. This example compares Gitea’s `main` tip with the current checkout:

```sh
set -eu
refs=$(git ls-remote --exit-code origin refs/heads/main)
remote_sha=${refs%%[[:space:]]*}
local_sha=$(git rev-parse HEAD)
if [ "$remote_sha" != "$local_sha" ]; then
  printf "Gitea main changed to %s\n" "$remote_sha"
fi
```

Pair it with a prompt such as “Deploy the reported commit using the project’s
deployment procedure; update the deployed checkout only on success.” The
example assumes the checkout’s HEAD represents the deployed revision; otherwise
compare with a separately recorded deployed SHA. The script runs in the selected
project folder, locally or over SSH. Exit 0 with no output to skip the agent,
print to stdout to start it, or exit nonzero to record a task error. A script
that handles deployment itself can omit the prompt and keep stdout empty to
avoid starting an agent.
