# ACP Agent 的 Skills 和 Rules 目录复制

在 **Settings → Agents** 中，为每个 ACP Agent 分别设置：

- **User skills directory**：Agent 原生读取的用户级 Skills 目录。
- **User rules directory**：接收用户级 Rules 的目录。

目录留空表示不复制；支持绝对路径和 `~/`。程序不会根据 Agent 名称猜目录，也不会修改 ACP 启动参数。

## 操作

1. 填写目录并保存 Agent 配置。保存配置不会复制文件。
2. 选择 **This machine** 或当前工作区中 SSH 项目的主机。
3. 点击 **Preview skills copy** 或 **Preview rules copy**。
4. 核对实际来源、目标、新增、更新、冲突和过期内容，确认后点击 **Copy**。

这是手动增量复制：打开设置、保存自定义文件或启动 Agent 均不会自动写入目标目录。
本机复制使用本机用户配置；SSH 复制使用所选主机自己的用户配置和目录，不会将本机自定义上传到远端，连接失败也不会回退成本机复制。

## 复制范围

来源配置根目录为该主机的 Claude 用户配置目录，默认 `~/.claude`，遵循现有的配置目录解析（含 `CLAUDE_CONFIG_DIR`）。

### Skills

复制 `<config>/skills` 下包含普通文件 `SKILL.md` 的用户 Skill 文件夹：

```text
<config>/skills/pdf/  →  <skills destination>/pdf/
```

复制完整目录，包括脚本、引用、图片、二进制资源、隐藏资源文件和空目录。
不复制云同步的 `synced/`、隐藏的顶层目录、插件或项目级 Skills。

### Rules

保持原始字节，不合并、不改名、不转换 front matter、不注入 ACP 提示词：

```text
<config>/rules/style.md         → <rules destination>/style.md
<config>/rules/nested/style.md  → <rules destination>/nested/style.md
<config>/CLAUDE.md              → <rules destination>/CLAUDE.md
```

规则目录中的辅助文件也会复制。如果用户 `CLAUDE.md` 与规则目录内的同名路径冲突，预览会报错，不会任选一份覆盖。

**复制完成不等于 Agent 一定加载成功。** 请确认目标 Agent 支持这些路径、文件名和规则语法。
路径条件和 `@...` 等相对引用原样保留，不会自动修复布局变化带来的引用问题。
有些 Agent 需要新建或重启会话才读取新增内容；BaoCode 不会自动终止正在运行的 Agent。

## 冲突和安全边界

- 目标根目录的 `.baocode-customizations.json` 是受管清单，记录来源、类型以及已复制文件的内容和可执行标记摘要。
- 只更新内容和可执行标记都仍与清单一致的受管文件。
- 非受管同名文件即使内容相同，也不会被自动接管或覆盖。
- 受管文件在外部修改后显示冲突；存在冲突时整份预览不能执行。请自行保留、移动或处理冲突内容后重新预览。
- 源文件删除后仅标为过期，目标文件和清单记录保留，不自动清理。
- 拒绝源与目标配置目录重叠、符号链接、特殊文件和越界路径。
- 预览后来源、目标或清单发生变化时，需要重新预览。
- 文件逐个暂存并原子替换，不是整目录事务。中途失败可能已有部分文件完成；成功文件会逐个记录，以便重新预览后继续。
- 复制文件采用仅当前用户可读写的权限，在 POSIX 主机保留必要的可执行能力；不复制所有者、组、ACL 或特殊权限位。
- SSH 主机需具备标准 POSIX 工具 `sh`、`mkdir`、`mktemp`、`chmod` 和 `mv`，不依赖 Python。

更换目标目录或移除 Agent 配置不会删除旧目录中的副本。
