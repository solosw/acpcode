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

## SSH 工作区

配置从远程主机读取，项目路径使用远程 POSIX 路径；环境和可执行文件也在
远程解析，不读取客户端 Windows 的 PATH 来查找远程命令。MCP 通常由
远程 ACP Agent 在远程主机启动，并不会因此操作客户端本机的浏览器。

这次接入不包含 skill 注入、浏览器内核或浏览器 MCP 的自动安装，也不
改变 Agent 自己已有的 MCP 配置加载方式。
