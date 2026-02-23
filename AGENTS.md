# AGENTS.md

## dash-api MCP Server

本项目配置了 [dash-mcp-server](https://github.com/Kapeli/dash-mcp-server)，可以通过 MCP 工具直接查询 Dash 中安装的文档。

### 可用工具

| 工具 | 用途 |
|------|------|
| `mcp__dash_api__list_installed_docsets` | 列出 Dash 中已安装的所有文档集 |
| `mcp__dash_api__search_documentation` | 在指定文档集中搜索，需提供 `query` 和 `docset_identifiers` |
| `mcp__dash_api__enable_docset_fts` | 为指定文档集启用全文搜索 |
| `mcp__dash_api__load_documentation_page` | 加载搜索结果中的文档页面（使用搜索结果返回的 `load_url`） |

### 使用步骤

1. 先调用 `list_installed_docsets` 获取可用的文档集及其 `identifier`
2. 用 `search_documentation` 搜索，传入 `query` 和 `docset_identifiers`（逗号分隔）
3. 从搜索结果中取 `load_url`，调用 `load_documentation_page` 查看完整文档

### 注意事项

- **Dash 必须正在运行**，否则 MCP 工具无法连接
- **Surge 等代理软件**会拦截 localhost 请求。配置中已通过 `env.no_proxy` 绕过，见 `~/.config/amp/settings.json`：
  ```json
  "dash-api": {
    "command": "uvx",
    "args": ["--from", "git+https://github.com/Kapeli/dash-mcp-server.git", "dash-mcp-server"],
    "env": {
      "no_proxy": "127.0.0.1,localhost",
      "NO_PROXY": "127.0.0.1,localhost"
    }
  }
  ```
- Dash API 端口是动态的，存储在 `~/Library/Application Support/Dash/.dash_api_server/status.json`
- 如果工具报 "Failed to connect to Dash API Server"，检查：
  1. Dash 是否正在运行
  2. Dash Settings → Integration 中 API Server 是否已启用
  3. 代理是否跳过了 127.0.0.1（`curl --noproxy '*' http://127.0.0.1:<port>/health` 验证）
