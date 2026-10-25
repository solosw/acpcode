# BaoCode
<a href="https://trendshift.io/repositories/289180?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-289180" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/289180/daily?language=Dart" alt="baocode-dev%2Fbaocode | Trendshift" width="250" height="55"/></a>

**English** · [简体中文](README_CN.md) · [日本語](README_JA.md) · [Français](README_FR.md) · [Español](README_ES.md)

A desktop UI for [Claude Code](https://github.com/anthropics/claude-code) and configurable Agent Client Protocol (ACP) agents, with a fast IDE built in.

This is the **solosw/baocode fork** of [baocode-dev/baocode](https://github.com/baocode-dev/baocode), not the upstream distribution. It retains the upstream interface and features while adding the integrations described below.

[Download this fork](https://github.com/solosw/baocode/releases/latest) · [Release notes](release-notes/) · [Upstream website](https://baocode.dev)

![BaoCode's main window: agents grouped by project, two conversations side by side, and the model picker](site/shots/main.png)

## How this fork differs from upstream

The comparison below describes this fork's additions relative to the upstream revision merged here (`c4c502e4`), not a claim about every future upstream release. The editor, themes, Stash, GitHub/GitLab integration, model-provider support and basic SSH workflow come from upstream; they are not unique to this fork.

| Area | Additions and changes in this fork |
| --- | --- |
| ACP agents | Configure multiple agents in **Settings → Agents**, each with its own executable, arguments and environment. Agents run on the project's host, locally or over SSH. ACP session IDs are kept for agents that support resuming sessions. |
| ACP session controls | Select the models, modes and thinking levels advertised by the agent, with compatibility for the older mode protocol. Available controls depend on the agent, not a hard-coded model list. |
| MCP for ACP | Pass configured MCP servers when creating or restoring ACP sessions. Local ACP agents can also access BaoCode's browser and image tools through MCP; HTTP-capable agents share an in-app service, with stdio fallback. See [ACP MCP integration](docs/acp-mcp.md). |
| Skills and Rules | Configure per-agent user-level destination directories, then preview and confirm a manual incremental copy. Skills include their complete resources; Rules are copied unchanged. Existing unowned or externally modified files are protected, and stale files are retained. See [directory copying](docs/acp-customizations.md). |
| Gitea | Add personal access token accounts for HTTP/HTTPS instances and custom Web ports. Use Gitea issues and pull request status in Stash, including issue import, sync, publishing, editing, comments and closing. |
| Saved SSH hosts | Keep host, user, port and password/key authentication choices in settings; passwords stay in the system keychain. Existing SSH config remains available for hosts not saved here. |
| Releases and updates | Publish installers and remote-server binaries through this repository's GitHub Releases. This fork checks its own update channel rather than upstream's distribution channel. |

**Compatibility boundaries:** ACP support does not make every Claude Code feature available to every agent. MCP transport and session controls depend on agent capabilities. Skills/Rules copying is manual, does not inject rules into prompts or convert their syntax, and does not guarantee that an agent loads them. SSH copying uses the selected host's own customizations, without uploading local files. Gitea does not support local image uploads or instances deployed under a URL subpath; HTTP sign-in requires confirmation because traffic is unencrypted.

Use this repository's Releases for this fork. The upstream website, screenshots, performance figures and other translated READMEs may describe the original distribution.

## Why

We use Claude Code every day. The terminal is a fine place to run it, but a poor place to read it: long diffs scroll out of view, earlier steps are hard to find again, and reviewing what changed means switching to another app. BaoCode is the window we wanted around it.

BaoCode's upstream design centers on Claude Code and its tools, skills, plugins, MCP servers, subagents and hooks. This fork keeps that integration, using your installed Claude Code, settings and `CLAUDE.md`, and additionally lets you connect external ACP agents. BaoCode provides the interface; the selected agent executes the tasks.

## Features

- **An interface made for reading.** Reads, searches and commands fold into single lines. Keep or Undo each change Claude made, file by file; checkpoints live in BaoCode's own data folder, never in your repository's `.git`.
- **Goals.** Type `/goal` and what you want done, and Claude keeps working until it is met, with the goal and its progress above the input.
- **A rich-text input.** Code copied from the editor arrives as a reference to its file and lines; pasted images and dropped files sit where you put them in the sentence.
- **Fast IDE.** An editor, a terminal and Source Control with a commit graph, built in. Claude Code drafts your commit messages. VS Code, IntelliJ, Sublime and Atom keymaps, and language servers.
- **Your VS Code themes.** The editor, the conversation and the sidebar all follow them.
- **Skills, MCP servers and more.** Plugins, MCP servers, skills, subagents, rules, commands and hooks in one place, for you or for a single project.
- **Any model.** Add an upstream that speaks Anthropic's API, OpenAI's Chat Completions or OpenAI's Responses; a local proxy translates between it and Claude Code. Keys stay in the system keychain.
- **Remote projects over SSH.** The window stays on your machine; files, Git, search, terminals, language servers and Claude Code run on the remote host (Linux, x64 or arm64).
- **Notifications.** A system notification, a sound and a badge when an agent needs you or finishes. Close the window and the agents keep running in the menu bar or tray.
- **Updates itself** in the background, or manually, or not at all.

## Speed

The figures below are retained from the upstream README and have not been re-measured for this fork. Actual performance depends on the version, hardware and agents in use.

VS Code and Cursor are built on Electron: each window is a web page, and every copy carries its own Chromium and Node.js. BaoCode is a native app that draws its own interface straight to the GPU.

| | BaoCode | VS Code | Cursor |
| --- | --- | --- | --- |
| Launch | ≈ 0.18 s | ≈ 2–3 s | ≈ 2–3 s |
| Memory, one window idle | ≈ 120 MB | ≈ 970 MB | ≈ 1.9 GB |
| Processes, one window | 2 | 8 | 13 |
| Download size, Windows | ≈ 16 MB | ≈ 244 MB | ≈ 214 MB |

## Requirements

- macOS 12 or later (Apple silicon or Intel, one download each), or Windows 10 or later (x64).
- An installed [Claude Code](https://github.com/anthropics/claude-code) for the Claude Code integration, or an ACP-compatible agent configured in **Settings → Agents** for ACP conversations.
- Agent executables must be installed on the host where the project runs. Selecting an ACP agent does not replace the separate auxiliary-model configuration.

## Building from source

BaoCode is a Flutter app (Dart SDK `^3.13.4`).

```sh
flutter pub get
flutter run -d macos        # or: flutter run -d windows
```

To build what is released, into `build/installers/`:

```sh
dart run tool/build_macos.dart            # BaoCode-<version>-{arm64,x64}.dmg and BaoCode-<version>-mac-{arm64,x64}.zip
dart run tool/build_windows.dart          # BaoCode-<version>-setup.exe (needs Inno Setup)
dart run tool/build_remote_server.dart    # the SSH remote server, for Linux x64 and arm64
```

The full test suite is slow; run the tests for what you changed, for example `flutter test test/update`.

Releases are built and published by CI when a `v*` tag is pushed; versions, signing and where releases go are in [docs/release.md](docs/release.md). More in [docs/](docs): [auto-update](docs/auto-update.md), [SSH remote](docs/ssh-remote.md), [Windows](docs/windows.md) (some are in Chinese).

## Repository

| Path | What it is |
| --- | --- |
| [lib/](lib) | The app |
| [packages/bao_editor](packages/bao_editor) | Monaco, ported to Flutter: the editor, its highlighting, VS Code's themes and keybindings |
| [packages/bao_xterm](packages/bao_xterm) | A Dart port of xterm.js |
| [packages/bao_pty](packages/bao_pty) | Pseudo terminals for Dart: forkpty on macOS and Linux, ConPTY on Windows |
| [packages/bao_remote](packages/bao_remote) | The remote host served over SSH |
| [macos/](macos), [windows/](windows) | The native runners |
| [tool/](tool) | Build, packaging and release scripts |
| [site/](site) | The website, [baocode.dev](https://baocode.dev) |
| [docs/](docs) | Design notes |

## Feedback

For fork-specific issues, use this repository's issue tracker and include the app version and agent in use. Upstream has its own issue tracker and does not accept pull requests.

## License

BaoCode is licensed under the [GNU General Public License v3.0](LICENSE)
(GPL-3.0-only). The editor and terminal packages in [packages/](packages)
(bao_editor, bao_xterm, bao_pty) are MIT. Third-party components keep their
own licenses, found next to them in the source tree.

BaoCode is an independent project, not affiliated with or endorsed by
Anthropic.
