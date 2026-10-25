# BaoCode

[English](README.md) · **简体中文** · [日本語](README_JA.md) · [Français](README_FR.md) · [Español](README_ES.md)

面向 [Claude Code](https://github.com/anthropics/claude-code) 和可配置的 Agent Client Protocol（ACP）智能体的桌面界面，内置快速 IDE。

这里是 [baocode-dev/baocode](https://github.com/baocode-dev/baocode) 的 **solosw/baocode 分支**，不是上游原版发行渠道。在保留上游界面与功能的基础上，本分支增加了下文列出的集成。

[下载本分支](https://github.com/solosw/baocode/releases/latest) · [版本更新记录](release-notes/) · [上游官网](https://baocode.dev)

![BaoCode 主窗口：按项目分组的智能体、并排显示的两个对话，以及模型选择器](site/shots/main.png)

> 本文是英文 README 的中文介绍；如内容有差异，以 [English](README.md) 为准。链接指向的文档和网站不一定提供中文版本。

## 与原版有什么不同

以下对比以本仓库已合入的上游版本（提交 `c4c502e4`）为基准，不代表上游后续版本不会加入相同功能。编辑器、主题、Stash、GitHub/GitLab 集成、模型供应商支持和基础 SSH 工作流来自上游，不是本分支独有功能。

| 方面 | 本分支增加或调整的内容 |
| --- | --- |
| ACP 智能体 | 在 **设置 → Agents** 中配置多个 Agent，分别设置可执行文件、参数和环境变量。Agent 在项目所在的本机或 SSH 主机运行；保存 ACP 会话 ID，供支持恢复的 Agent 续接会话。 |
| ACP 会话控制 | 使用 Agent 实际提供的模型、模式和思考等级选项，兼容旧版模式协议；不预设固定模型列表，界面选项取决于 Agent 能力。 |
| ACP 的 MCP 接入 | 创建或恢复 ACP 会话时传入已配置的 MCP 服务器。本地 ACP Agent 还可通过 MCP 使用 BaoCode 的浏览器和图片工具；支持 HTTP 的 Agent 共用应用内服务，仅支持 stdio 的 Agent 使用转发方式。详见 [ACP MCP 接入](docs/acp-mcp.md)。 |
| Skills 和 Rules | 每个 Agent 可设置用户级目标目录，手动预览并确认后增量复制。Skills 包含完整资源，Rules 原样复制；保护既有及外部修改文件，源删除后保留过期副本。详见[目录复制说明](docs/acp-customizations.md)。 |
| Gitea | 支持通过个人访问令牌登录 HTTP/HTTPS 实例及自定义 Web 端口；接入 Stash 的 Issue 导入、同步、发布、编辑、评论、关闭，以及 PR 状态展示。 |
| SSH 主机管理 | 在设置中保存主机、用户名、端口及密码/私钥认证选项，密码保存在系统密钥环；未在应用中保存的主机仍可使用已有 SSH 配置。 |
| 发布与更新 | 安装包和远程服务端通过本仓库的 GitHub Releases 发布；本分支检查自己的更新渠道，不使用原版的发行渠道。 |

**兼容性边界：** 支持 ACP 不等于所有 Agent 都支持 Claude Code 的全部功能，MCP 传输和会话选项以 Agent 实际能力为准。Skills/Rules 是手动复制，不注入提示词、不转换规则语法，也不保证 Agent 一定加载；SSH 复制使用远端自己的自定义内容，不自动上传本机文件。Gitea 暂不支持本地图片上传及 URL 子路径部署；HTTP 传输未加密，登录前需要确认。

使用本分支请从本仓库 Releases 下载。上游官网、截图、性能数据及其他语言的 README 可能仍描述原版发行内容。

## 为什么做 BaoCode

我们每天都在使用 Claude Code。终端适合运行它，却不适合阅读它：长篇 diff 很容易滚出视野，先前的步骤难以重新找到，审查修改又需要切换应用。BaoCode 就是我们希望为它提供的那个窗口。

上游 BaoCode 围绕 Claude Code 的工具、技能、插件、MCP 服务器、子智能体和 hooks 生态提供界面。本分支保留这一集成，运行你已经安装的 Claude Code，沿用你的设置和 `CLAUDE.md`，同时增加外部 ACP Agent 接入。BaoCode 提供界面，具体任务由所选智能体执行。

## 功能

- **为阅读而生的界面。** 文件读取、搜索和命令可以折叠为单行。Claude 做出的修改可以逐文件保留或撤销；检查点保存在 BaoCode 自己的数据目录中，不会写入仓库的 `.git`。
- **目标。** 输入 `/goal` 和你希望完成的任务，Claude 会持续工作直到达成目标，输入框上方会显示目标及进度。
- **富文本输入。** 从编辑器复制的代码会以文件和行号引用的形式加入输入；粘贴的图片和拖入的文件可以放在句子中指定的位置。
- **快速 IDE。** 内置编辑器、终端，以及带提交图的源代码管理。Claude Code 可以起草提交信息，并支持快捷键映射和语言服务器。
- **统一主题。** 编辑器、对话和侧边栏采用一致的主题样式。
- **技能、MCP 服务器及更多扩展。** 在同一处管理插件、MCP 服务器、技能、子智能体、规则、命令和 hooks，可供个人使用或限定于某个项目。
- **多种模型。** 可以添加兼容 Anthropic API、OpenAI Chat Completions 或 OpenAI Responses 的供应商，本地代理负责与 Claude Code 之间的协议转换。密钥保存在系统密钥环中。
- **通过 SSH 使用远程项目。** 窗口留在本机，文件、Git、搜索、终端、语言服务器和 Claude Code 则运行在远程主机上（Linux，x64 或 arm64）。
- **通知。** 智能体需要你的操作或完成任务时，会通过系统通知、声音和角标提醒。关闭窗口后，智能体可以继续在菜单栏或系统托盘中运行。
- **自动更新。** 可选择后台自动更新、手动更新，或关闭更新。

## 速度

BaoCode 是原生应用，直接通过 GPU 绘制界面。以下数据沿用上游 README，未针对本分支重新测量；实际表现取决于硬件、版本、所用智能体和使用场景。

| 指标 | BaoCode |
| --- | --- |
| 启动时间 | 约 0.18 秒 |
| 单窗口空闲内存占用 | 约 120 MB |
| 单窗口进程数 | 2 |
| Windows 下载大小 | 约 16 MB |

## 系统要求

- macOS 12 或更新版本（Apple 芯片和 Intel 各提供一个下载版本），或 Windows 10 或更新版本（x64）。
- 使用 Claude Code 集成时需安装 [Claude Code](https://github.com/anthropics/claude-code)；使用 ACP 对话时需在 **设置 → Agents** 中配置兼容 ACP 的智能体。
- Agent 可执行文件须安装在项目实际运行的主机上。选择 ACP Agent 不会替换单独配置的辅助模型。

## 从源码构建

BaoCode 使用 Flutter 开发，Dart SDK 要求为 `^3.13.4`。

```sh
flutter pub get
flutter run -d macos        # Windows 使用：flutter run -d windows
```

构建发行版本，产物写入 `build/installers/`：

```sh
dart run tool/build_macos.dart            # BaoCode-<version>-{arm64,x64}.dmg 和 BaoCode-<version>-mac-{arm64,x64}.zip
dart run tool/build_windows.dart          # BaoCode-<version>-setup.exe（需要 Inno Setup）
dart run tool/build_remote_server.dart    # 用于 Linux x64 和 arm64 的 SSH 远程服务器
```

完整测试套件运行较慢，开发时应只运行与修改相关的测试，例如 `flutter test test/update`。

推送 `v*` 标签后，CI 会构建并发布发行版本。版本号、签名及发布位置的说明见 [docs/release.md](docs/release.md)。更多文档位于 [docs/](docs)，包括[自动更新](docs/auto-update.md)、[SSH 远程](docs/ssh-remote.md)和 [Windows](docs/windows.md)，其中部分文档为中文。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| [lib/](lib) | 应用代码 |
| [packages/bao_editor](packages/bao_editor) | 编辑器，以及语法高亮、主题和快捷键支持 |
| [packages/bao_xterm](packages/bao_xterm) | xterm.js 的 Dart 移植版本 |
| [packages/bao_pty](packages/bao_pty) | Dart 伪终端支持：macOS、Linux 使用 forkpty，Windows 使用 ConPTY |
| [packages/bao_remote](packages/bao_remote) | 通过 SSH 提供服务的远程端 |
| [macos/](macos)、[windows/](windows) | 原生平台启动器 |
| [tool/](tool) | 构建、打包及发布脚本 |
| [site/](site) | 官网 [baocode.dev](https://baocode.dev) 的源码 |
| [docs/](docs) | 设计文档 |

## 反馈

本分支相关问题请在本仓库提交 Issue，并注明应用版本和所用 Agent。上游使用独立的问题跟踪渠道，且不接受 Pull Request。

## 许可证

BaoCode 使用 [GNU General Public License v3.0](LICENSE)（GPL-3.0-only）许可证。[packages/](packages) 中的编辑器和终端相关包（bao_editor、bao_xterm、bao_pty）使用 MIT 许可证。第三方组件保留其自身许可证，具体文件位于对应源码旁。

BaoCode 是独立项目，与 Anthropic 无隶属关系，也未获得其背书。
