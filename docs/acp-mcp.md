# ACP 的 MCP 接入

BaoCode 创建和恢复 ACP 会话时，会把当前工作区已配置、未禁用的 MCP
转换成 ACP `mcpServers`，分别传入 `session/new` 和 `session/load`。
这是配置传递，不代表 MCP 已成功连接；连接和工具执行由 ACP Agent 负责。

## 配置来源

与「自定义 → MCP」使用同一套配置来源：

- 用户配置：默认 `~/.claude.json` 的 `mcpServers`。
- 项目共享配置：工作区根目录 `.mcp.json` 的 `mcpServers`。
- 项目私有配置：`.claude.json` 的 `projects[项目路径].mcpServers`。

同名配置采用 **项目私有 > 项目共享 > 用户**。禁用的高优先级配置不会
回退到低优先级配置。沿用项目状态中的 `disabledMcpServers` 和
`disabledMcpjsonServers`。仅有名称、没有连接参数的 claude.ai 账号连接器
不会传给其他 Agent。

ACP Agent 设置里的 `CLAUDE_CONFIG_DIR` 和 `HOME` 覆盖也用于配置查找。
配置更改后需要新建会话或重启 Agent；没有实现会话内热更新。

## 传输与转换

- stdio：把 `command` 解析为 Agent 所在主机上的绝对路径；`args` 保留为
  数组；`env` 对象转换为 ACP 的 `{name, value}` 数组。
- HTTP / SSE：只有 Agent 在 `initialize` 响应的
  `agentCapabilities.mcpCapabilities` 中声明支持相应类型时才传入。
  `headers` 对象转换为 `{name, value}` 数组。
- 只有 `url` 而未指定 `type` 的配置按 HTTP 处理。
- 支持配置值中的 `${VAR}` 和 `${VAR:-default}`，使用 Agent 主机环境与
  ACP 启动环境覆盖进行展开。不会把全部继承环境作为 MCP 的 `env` 发送。
- 不支持的传输、缺失的变量、格式错误或找不到的启动命令会被跳过，并在
  对话中显示警告；其他有效 MCP 仍会传入。警告不输出凭证或配置值。

stdio 配置示例（替换成主机上已安装的实际工具）：

```json
{
  "mcpServers": {
    "my-tools": {
      "command": "/absolute/path/to/mcp-server",
      "args": ["--stdio"],
      "env": {
        "API_TOKEN": "${MY_TOOLS_TOKEN}"
      }
    }
  }
}
```

## 应用自己的工具（浏览器、生成图片）

Claude Code 由应用自己启动，所以它的浏览器工具和 `generate_image` 以
应用内置的 MCP 服务器 `baocode`（`mcp__baocode__*`）提供。ACP Agent 是
另一个进程，应用因此把它也做成一个真正的 MCP 服务器：

1. 应用先解析数据目录，再启动 `mcp/tools.sock`（Windows 为
   `127.0.0.1` 随机端口）。当前地址保存在 `mcp/endpoint.json`，一次性令牌
   在 `mcp/token`；目录权限 700，socket 和令牌权限 600。
2. 应用将 `baocode` 注册到**用户级** `.claude.json` 的 `mcpServers`，不是
   项目的 `.mcp.json`。默认是 `~/.claude.json`；自定义 Claude 配置目录时
   是该目录中的 `.claude.json`，设置的自定义 MCP 列表也能读到。
3. 服务器命令为应用自己的可执行文件加 `--mcp-stdio`；持久配置只保存
   `BAOCODE_MCP_DATA_DIR`。进程每次启动时读取当前连接地址和令牌，
   默认以进程工作目录作为项目目录，因此应用重启后不需要重新配置令牌。
4. stdout 只输出 MCP JSON-RPC，错误写 stderr。扩展首次连接或工具开关变化
   后，已初始化的客户端会收到 `notifications/tools/list_changed`。

因此本地 ACP Agent 与 Claude Code 用到的工具完全一致，浏览器工具也仍然
只操作用户共享出来的标签页。几点约定：

- 服务器名 `baocode`。用户自己定义的同名服务器不会被覆盖；应用托管的
  注册项会在应用移动后更新命令路径，同时保留其它服务器和用户配置。
  本机注册通过临时文件原子替换，保留原文件权限和符号链接；格式错误或
  无法读取的已有配置不会被覆盖。
- 用户级注册对本机项目生效。SSH Agent 仍只读取远端配置，不把本机路径、
  地址或令牌复制到远端。
- 注册本身不依赖扩展是否已连接；可用工具仍由浏览器开关、共享标签页和
  图片模型决定，关闭的工具不会因注册为用户级而变得可调用。
- `--mcp-stdio` 的进程不启动界面，只转发；应用退出后它也随之结束。
  客户端关闭 stdin 时最多等待 2 秒排空回复，再断开以取消未完成调用。
- 令牌只属于本次运行，写入文件供应用拉起的进程读取，不经网络。

## SSH 工作区

配置从远程主机读取，项目路径使用远程 POSIX 路径；环境和可执行文件也在
远程解析，不读取客户端 Windows 的 PATH 来查找远程命令。MCP 通常由
远程 ACP Agent 在远程主机启动，并不会因此操作客户端本机的浏览器。

这次接入不包含 skill 注入、浏览器内核或浏览器 MCP 的自动安装，也不
改变 Agent 自己已有的 MCP 配置加载方式。
