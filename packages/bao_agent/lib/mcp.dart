/// MCP transports shared by the agent and the desktop's SSH MCP bridge.
library;

export 'src/mcp/transports.dart'
    show McpTransport, SseTransport, StdioTransport, StreamableHttpTransport;
