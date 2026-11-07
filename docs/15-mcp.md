# 第 15 章 MCP 集成（重点）

> 第 7 章的工具三来源里，MCP 是唯一"不改一行核心代码就能接入外部系统"的来源。
> 本章拆解 DeerFlow 的 MCP 子系统：`extensions_config.json` 的两种传输配置、
> 每服务器独立进程与超时防护、工具如何合并进 `get_available_tools()`、
> Gateway 热编辑的双锁与原子写契约、把长任务挡在 Agent 循环之外的
> `McpTaskService`，以及 `mcpInterceptors` 拦截器。两个动手实验带你完整走通
> "接入 GitHub MCP server → 自建 stdio MCP server → 调用 → 取消长任务"闭环。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| MCP 子系统守则（必读） | `backend/packages/harness/deerflow/mcp/AGENTS.md` |
| 配置模型 | `backend/packages/harness/deerflow/config/extensions_config.py:218`（`McpServerConfig`） |
| 示例配置（四种服务器） | `extensions_config.example.json` |
| 连接参数构建 | `backend/packages/harness/deerflow/mcp/client.py:12`（`build_server_params`） |
| 工具发现/包装/前缀 | `backend/packages/harness/deerflow/mcp/tools.py:1060`、`:1106`、`:655` |
| 工具缓存 | `backend/packages/harness/deerflow/mcp/cache.py:1188`（`get_cached_mcp_tools`） |
| stdio 会话池 | `backend/packages/harness/deerflow/mcp/session_pool.py:183`（`MAX_SESSIONS = 256`） |
| 工具合并入口 | `backend/packages/harness/deerflow/tools/tools.py:103`（`get_available_tools`） |
| 拦截器链 | `backend/packages/harness/deerflow/mcp/interceptors.py:18` |
| 双锁与原子写 | `backend/packages/harness/deerflow/config/extensions_config.py:955`、`:958`、`:717` |
| 长任务服务 | `backend/app/mcp_tasks/service.py:102`（`McpTaskService`） |
| 长任务持久化 | `backend/packages/harness/deerflow/persistence/mcp_tasks/model.py:17`（`McpTaskRow`） |
| 长任务驱动协议 | `backend/packages/harness/deerflow/mcp/tasks/driver.py:9`（`McpTaskDriver`） |
| 控制租约文档 | `backend/docs/mcp-control-leases.md` |
| MCP 配置官方文档 | `backend/docs/MCP_SERVER.md` |
| Gateway MCP 路由 | `backend/app/gateway/routers/mcp.py`（7 个端点）+ `routers/mcp_tasks.py` |
| 双锁/原子写测试 | `backend/tests/test_extensions_config_atomic_write.py`、`backend/tests/test_compose_extensions_config_writable.py` |

## 15.0 学习目标

读完本章，你应该能够：

1. 写出 stdio（`command/args/env`）与 http（`url/headers`）两种 `mcpServers`
   配置，并解释 `$ENV_VAR` 运行时解析、`tool_name_prefix`、
   `session_init_timeout`、`tool_call_timeout` 四个键的行为；
2. 描述一次 MCP 工具调用从"配置文件 → 连接参数 → 每服务器独立发现 →
   会话池 → 合并进 `get_available_tools()`"的完整路径；
3. 说出 Gateway 热编辑 `extensions_config.json` 的双锁契约
   （`extensions_config_write_lock` + `extensions_config_file_lock`）与
   `atomic_write_extensions_config` 的临时文件替换语义，以及 Compose 中
   "该文件可写、`config.yaml` 只读"的原因；
4. 解释 `McpTaskService` 为什么把远端任务 ID/轮询挡在 Agent 循环之外
   （租约、DB 为真相源、通知重试/死信、取消端点 worker-stopped 503）；
5. 独立完成 GitHub MCP server 接入与自建 stdio MCP server 并在对话中调用。

## 15.1 配置 MCP 服务器

### 15.1.1 四键骨架：middlewares / mcpInterceptors / mcpServers / skills

MCP 服务器与技能同住一份 `extensions_config.json`（仓库根，gitignored，从
`extensions_config.example.json` 复制）。顶层四个键（第 16 章会再见到它们）：
`middlewares`（Agent 中间件类路径）、`mcpInterceptors`（MCP 工具拦截器）、
`mcpServers`（服务器映射）、`skills`（技能开关）。Pydantic 模型在
`backend/packages/harness/deerflow/config/extensions_config.py:399-420`：

```python
class ExtensionsConfig(BaseModel):
    """Unified configuration for MCP servers and skills."""

    middlewares: list[str | ConfiguredMiddlewareSpec] = Field(...)
    mcp_servers: dict[str, McpServerConfig] = Field(
        default_factory=dict,
        description="Map of MCP server name to configuration",
        alias="mcpServers",
    )
    skills: dict[str, SkillStateConfig] = Field(...)
    model_config = ConfigDict(extra="allow", populate_by_name=True)
```

单个服务器的配置模型是 `McpServerConfig`
（`backend/packages/harness/deerflow/config/extensions_config.py:218-272`）。
先看本章的四个主角字段（`:241-261`）：

```python
    tool_name_prefix: bool = Field(
        default=True,
        description="Whether to prefix discovered tool names with the MCP server name to avoid cross-server collisions",
    )
    tool_call_timeout: float | None = Field(
        default=None,
        gt=0,
        allow_inf_nan=False,
        description=("Timeout in seconds for individual stdio MCP tool calls and durable-task calls on every transport. Other HTTP/SSE tools use transport-level timeouts. None means no call-level timeout."),
    )
    session_init_timeout: float | None = Field(
        default=DEFAULT_MCP_SESSION_INIT_TIMEOUT,
        gt=0,
        allow_inf_nan=False,
        description=(
            "Timeout in seconds for MCP server bring-up: tool discovery (subprocess spawn + initialize + tools/list) "
            "and persistent stdio session initialization, plus ephemeral HTTP/SSE durable-task session "
            "initialization. Defaults to DEFAULT_MCP_SESSION_INIT_TIMEOUT so a hung server cannot block agent "
            "construction or the task poller indefinitely. None means no timeout."
        ),
    )
```

- `tool_name_prefix`（默认 `true`）：发现到的工具名加上 `<server_name>_` 前缀，
  避免两台服务器暴露同名工具时冲突。服务器自身已带命名空间时可关掉
  （`backend/docs/MCP_SERVER.md:216-240` 的 semantic-scholar 例子）。
- `session_init_timeout`：服务器"从拉起到应答"的期限——stdio 是子进程 spawn +
  `initialize` + `tools/list` 的全过程；默认值为常量
  `backend/packages/harness/deerflow/constants.py:61`：
  `DEFAULT_MCP_SESSION_INIT_TIMEOUT = 60.0`。设为 `null` 可显式关闭。
- `tool_call_timeout`：单次工具调用的期限（stdio 调用 + 所有传输上的长任务
  调用）；普通 http/sse 工具走传输层超时。

### 15.1.2 真实配置示例：stdio 与 http

仓库自带的 `extensions_config.example.json` 给了四台示例服务器，全部默认
`enabled: false`。**stdio 型**（`extensions_config.example.json:7-22`）：

```json
    "github": {
      "enabled": false,
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-github"
      ],
      "env": {
        "GITHUB_TOKEN": "$GITHUB_TOKEN"
      },
      "tool_name_prefix": true,
      "session_init_timeout": 60,
      "tool_call_timeout": 60,
      "description": "GitHub MCP server for repository operations"
    },
```

**http 型**（`extensions_config.example.json:23-31`）：

```json
    "parallel-search": {
      "enabled": false,
      "type": "http",
      "url": "https://search.parallel.ai/mcp",
      "headers": {
        "User-Agent": "deer-flow"
      },
      "description": "Optional anonymous Parallel Search tools for web search and fetching requested URLs"
    },
```

两种传输的字段分野清晰：stdio 用 `command`/`args`/`env`（可选 `cwd`），http/sse
用 `url`/`headers`（可选 `oauth`、`user_auth`、`headers_from_context`）。同一
文件里还有一台演示**软路由提示**的 stdio 服务器（`extensions_config.example.json:41-76`）：
`postgres` 在服务器级与 `tools.query` 工具级各配一个 `routing` 块
（`mode: prefer`、`priority`、`keywords`）——它们只影响提示词里的
`<mcp_routing_hints>` 推荐段与 `tool_search` 自动提升，不会硬禁其他工具
（`backend/docs/MCP_SERVER.md:160-215`）。

### 15.1.3 `$ENV_VAR` 运行时解析

配置里凡是以 `$` 开头的整串字符串，加载时递归解析为环境变量。实现在
`backend/packages/harness/deerflow/config/extensions_config.py:570-601`：

```python
    @classmethod
    def resolve_env_variables(cls, config: Any) -> Any:
        """Recursively resolve environment variables in the config.

        Environment variables are resolved using the `os.getenv` function. Example: $OPENAI_API_KEY
        """
        if isinstance(config, str):
            if not config.startswith("$"):
                return config
            env_value = os.getenv(config[1:])
            if env_value is None:
                # Unresolved placeholder — store empty string so downstream
                # consumers (e.g. MCP servers) don't receive the literal "$VAR"
                # token as an actual environment value.
                return ""
            return env_value
        ...
```

两个必须记住的副作用：

1. **未设置的变量解析为空串**，不是保留字面 `$VAR`——下游（比如 stdio 子进程
   环境）拿不到占位符原文；
2. **`from_file()` 返回的模型已把密钥展开**，因此永远不能把它序列化写回磁盘
   （会把明文密钥持久化、把 `$VAR` 引用抹掉）。写回必须走
   `read_raw_extensions_config()`（`:776-793`，"This is the only safe merge
   source for a read-modify-write"）——15.3 节的热编辑链路正建立在这条规则上。

### 15.1.4 从配置到连接参数：`build_server_params`

发现工具前，每台服务器先被翻译成 `langchain-mcp-adapters` 的连接参数。
`backend/packages/harness/deerflow/mcp/client.py:12-60`（摘录主干）：

```python
def build_server_params(server_name: str, config: McpServerConfig) -> dict[str, Any]:
    """Build server parameters for MultiServerMCPClient."""
    transport_type = config.type or "stdio"
    params: dict[str, Any] = {"transport": transport_type}

    if transport_type == "stdio":
        if not config.command:
            raise ValueError(f"MCP server '{server_name}' with stdio transport requires 'command' field")
        params["command"] = config.command
        params["args"] = config.args
        if config.cwd:
            params["cwd"] = config.cwd
        # Add environment variables if present
        if config.env:
            params["env"] = config.env
    elif transport_type in ("sse", "http"):
        if not config.url:
            raise ValueError(f"MCP server '{server_name}' with {transport_type} transport requires 'url' field")
        params["url"] = config.url
        # Add headers if present
        if config.headers:
            # A statically configured value the transport would refuse gets the
            # same treatment as a request-scoped one: h11 renders the full
            # value into its exception on a line break or surrounding
            # whitespace, which reaches the model through
            # ToolErrorHandlingMiddleware. ...
            for header_name, header_value in config.headers.items():
                reason = illegal_header_value_reason(header_value)
                if reason is not None:
                    raise ValueError(f"MCP server '{server_name}' has a header '{header_name}' that cannot be sent as an HTTP header value: it {reason}")
            params["headers"] = config.headers
    else:
        raise ValueError(f"MCP server '{server_name}' has unsupported transport type: {transport_type}")
```

注意 http 分支里的 `illegal_header_value_reason` 检查：换行、首尾空白、非 ASCII
的静态 header 会在配置阶段直接拒绝该服务器。理由在注释里——h11 的报错会把
**完整 header 值**（常常就是 API key）回显进异常消息，而工具错误是
model-visible 的，等于把密钥泄进提示词、checkpoint 与 trace。
`build_servers_config`（`client.py:63-86`）逐台调用它，单台失败只丢弃该服务器
并记日志，不拖垮其余服务器。

配置模型还接受 MCP 规范的 `transport` 拼写作为 `type` 的别名
（`extensions_config.py:291-303` 的 `_accept_transport_alias`），两种写法等价。

## 15.2 进程隔离与工具合并

### 15.2.1 每服务器独立发现：一个慢服务器不拖累别人

发现被拆成"每服务器一个客户端 + 一次独立 discovery await"。
`backend/packages/harness/deerflow/mcp/tools.py:1060-1103` 的
`_prepare_server_client` 为**单个服务器**构建 `MultiServerMCPClient`（注意
`client_cls({server_name: connection}, ...)`——字典里只有这一台），并把
`tool_name_prefix` 与 `session_init_timeout` 一并带出：

```python
def _prepare_server_client(
    extensions_config: ExtensionsConfig,
    server_name: str,
    connection: dict[str, Any],
    *,
    client_cls: Any,
    initial_oauth_header: str | None,
    oauth_token_manager: OAuthTokenManager,
) -> _PreparedServerClient:
    """Build the client/interceptors for one selected server."""
    server_cfg = extensions_config.mcp_servers.get(server_name)
    transport = connection.get("transport", "stdio")
    tool_name_prefix = server_cfg.tool_name_prefix if server_cfg is not None else True
    session_init_timeout = _resolve_session_init_timeout(server_cfg)
    server_view = extensions_config.model_copy(
        update={"mcp_servers": {server_name: extensions_config.mcp_servers[server_name]}},
    )
    tool_interceptors = build_mcp_tool_interceptors(
        server_view,
        oauth_builder=lambda config: build_oauth_tool_interceptor(config, token_manager=oauth_token_manager),
        resolver=resolve_variable,
        target_logger=logger,
    )
    ...
    client = client_cls(
        {server_name: connection},
        tool_interceptors=tool_interceptors,
        tool_name_prefix=True,
    )
```

`server_view` 是只含这一台服务器的配置副本——拦截器构建者拿到的是"单服务器
视图"（`backend/packages/harness/deerflow/mcp/AGENTS.md` 与
`backend/docs/MCP_SERVER.md:643-649` 均强调：有状态的拦截器实例每服务器一份，
不要假设跨服务器共享）。

真正带超时的发现在 `tools.py:1106-1144`：

```python
        if prepared_client.session_init_timeout is not None:
            # Timeout tool discovery (subprocess spawn + initialize +
            # tools/list) so a hung stdio server cannot block agent
            # construction indefinitely. This runs per server so one slow
            # server does not prevent healthy siblings from contributing.
            try:
                server_tools = await asyncio.wait_for(discovery, timeout=prepared_client.session_init_timeout)
            except TimeoutError:
                logger.warning(
                    "Skipping MCP server '%s' after tool discovery timed out (%.1fs)",
                    server_name,
                    prepared_client.session_init_timeout,
                )
                return server_name, None
```

超时的服务器被**跳过**（返回 `None`），健康的兄弟服务器照常发布工具；一台
`npx -y` 卡在下载包上，不会让整次 agent 构建挂起。这就是"进程隔离与开关"的
第二层含义：**隔离不仅发生在运行期（独立子进程/独立连接），也发生在发现期
（独立超时、独立失败）**。`enabled: false` 或删除配置条目则把一台服务器从
上述流程里完全摘除；启用/停用可在运行时通过 API 切换（15.3 节）。

stdio 服务器在运行期还有第三重隔离：持久会话池。池按
`(server_name, user/thread/incarnation scope, ownership domain)` 键控，
`MCPSessionPool.MAX_SESSIONS = 256` 是硬上限（`backend/packages/harness/deerflow/mcp/session_pool.py:186`）；工具包装器
`_make_session_pool_tool`（`tools.py:655`）把每次调用放进池化会话，有状态的
stdio 服务器（如 Playwright）在同一线程内保持状态，又按用户/线程隔离。

### 15.2.2 工具名前缀的两处剥离

`tool_name_prefix=true` 时，适配器给工具名加 `<server_name>_` 前缀；DeerFlow
需要在**两个方向**还原"原始工具名"：路由查找按原名校验、`task_toolsets`
绑定的是远端原始名。第一处在会话池工具包装器里
（`backend/packages/harness/deerflow/mcp/tools.py:678-683`）：

```python
    # Strip only prefixes added by the adapter. An unprefixed server may expose
    # a tool whose own name happens to start with ``<server_name>_``.
    original_name = tool.name
    prefix = f"{server_name}_"
    if tool_name_prefix and original_name.startswith(prefix):
        original_name = original_name[len(prefix) :]
```

第二处在发现后的包装循环（`tools.py:1197-1202`）：剥离前缀得到
`original_name`，用它解析 `resolve_effective_mcp_routing(server_cfg, original_name)`
——`extensions_config.json → mcpServers.<server>.tools.<原始工具名>.routing`
的键是**加前缀之前**的名字。守则文件 `mcp/AGENTS.md:53` 补充了边界：
源路由与 stdio 会话池包装基于"产出的服务器与传输"，与可见名是否带前缀无关。

### 15.2.3 合并进 `get_available_tools()`

Agent 组装时工具来自四路合并（第 7 章讲过三路，这里看 MCP 一路的实现）。
`backend/packages/harness/deerflow/tools/tools.py:251-268`：

```python
    mcp_tools = []
    if include_mcp:
        try:
            from deerflow.config.extensions_config import ExtensionsConfig
            from deerflow.mcp.cache import get_cached_mcp_tools, refresh_mcp_cache_if_active

            try:
                extensions_config = ExtensionsConfig.from_file()
            except Exception as exc:
                # Only this call carries the resolved-credential risk:
                # from_file() resolves $VAR values before validation, so a
                # ValidationError message can embed secrets. Log the type only.
                logger.error("Failed to load MCP extensions config (%s)", type(exc).__name__)
            else:
                if extensions_config.get_enabled_mcp_servers():
                    mcp_tools = get_cached_mcp_tools()
                    if mcp_tools:
                        logger.info(f"Using {len(mcp_tools)} cached MCP tool(s)")
```

要点：`from_file()` 每次直读磁盘（注释里说明了为什么——Gateway 在独立进程里
改配置后，这里要立刻反映）；读取失败只记**异常类型**不记消息（消息可能内嵌
解析出的密钥）；有启用服务器才走 `get_cached_mcp_tools()`（带文件签名两段式
失效检查，见 `mcp/cache.py:1188`），否则调 `refresh_mcp_cache_if_active()`
退役旧缓存与池化会话。随后把个人 MCP 工具并入、按服务器名碰撞去重
（`tools.py:293-302`），最后与其他来源统一按工具名去重
（`tools.py:339-355`，重复名会让 LLM 收到歧义 schema——issue #1803）：

```python
    ordinary_tools = loaded_tools + builtin_tools + mcp_tools + acp_tools
    ...
    seen_names: set[str] = set()
    unique_tools: list[BaseTool] = []
    for t in all_tools:
        if t.name not in seen_names:
            unique_tools.append(t)
            seen_names.add(t.name)
        else:
            logger.warning(
                "Duplicate tool name %r detected and skipped — check your config.yaml and MCP server registrations (issue #1803).",
                t.name,
            )
    return unique_tools
```

顺带一提：`tools.py:186-187` 里 `is_mcp_task_runtime_available()` 为真时，
内置工具里还会追加 `list_background_tasks` / `cancel_background_task` 两个
管理工具——这是 15.4 节长任务运行时对 Agent 的唯一可见面。

## 15.3 运行时热编辑与并发安全

### 15.3.1 Gateway 的 7 个 MCP 端点

MCP 配置在运行时可经 Gateway API 修改（`backend/app/gateway/routers/mcp.py`）：
`GET /api/mcp/config`（`:1138`）、`POST /api/mcp/cache/reset`（`:1550`）、
`PUT /api/mcp/config`（整包替换，`:1579`）、`POST /api/mcp/config/servers`
（新增，`:1638`）、`PUT /api/mcp/config/server`（替换单台，`:1660`）、
`DELETE /api/mcp/config/servers/{server_name}`（`:1685`）、
`PATCH /api/mcp/config`（只改 enabled，`:1706`）。API 是不可信输入边界：
`_validate_mcp_update_request`（`routers/mcp.py:769`）对 stdio 命令做白名单
（默认 `{npx, uvx}`，可用 `DEER_FLOW_MCP_STDIO_COMMAND_ALLOWLIST` 扩展）、
拒绝任意执行参数与注入代码的环境变量（`PYTHONPATH`/`PYTHONHOME` 等）。
`backend/packages/harness/deerflow/mcp/AGENTS.md:79` 的提醒值得原样复述：
**这是纵深防御而非信任边界**——边界是管理员认证加网络可达性。

### 15.3.2 双锁：进程内 + 跨进程

写配置是"读 → 合并 → 写回 → 重载"的读改写循环。两个写方（MCP 路由与技能
开关）并发交错会互相吞掉改动，所以有**两把锁**。第一把，进程内线程锁
（`backend/packages/harness/deerflow/config/extensions_config.py:939-955`）：

```python
#: Serializes read-modify-write cycles on ``extensions_config.json`` across every
#: writer. Both the skills router (skill enable/disable) and the MCP router
#: (server config updates) read this file, merge a change and write it back.
#: ...
#: This is a ``threading.Lock`` rather than an ``asyncio.Lock``, and it must be
#: acquired *inside* the worker that performs the RMW. An asyncio lock held
#: around ``await asyncio.to_thread(...)`` protects only the awaiting task: if
#: that task is cancelled the context manager releases immediately while the
#: worker thread keeps writing, letting a second writer in. Owning the lock from
#: the worker keeps it held until the write and reload actually finish. It also
#: has no event-loop affinity, so writers running on different loops still
#: exclude each other.
extensions_config_write_lock = threading.Lock()
```

锁名是 `extensions_config_write_lock`（`backend/AGENTS.md:22` 的"hold both
`extensions_config_write_lock` and the sidecar advisory
`extensions_config_file_lock`"即指这两把）。为什么是 `threading.Lock` 而不是
`asyncio.Lock`：读改写被 offload 到工作线程执行，asyncio 锁只护住 await 点，
任务一取消锁就放、线程还在写——线程锁必须在**执行写的工作线程内**获取。

第二把，跨进程的 sidecar 文件锁（`extensions_config.py:958-996`）：

```python
@contextmanager
def extensions_config_file_lock(path: Path) -> Iterator[None]:
    """Exclude read-modify-write cycles in other Gateway processes.

    ``extensions_config_write_lock`` serializes threads in this process. This
    sidecar advisory lock extends the same critical section across worker
    processes and separate embedded clients that share the config directory.
    Callers must hold both locks around the complete read, merge, write, and
    reload cycle; locking only the final atomic replace still permits lost
    updates.
    """
    ...
    lock_path = target_path.parent / f".{target_path.name}.lock"

    with open(lock_path, "a+b") as lock_file:
        if os.name == "nt":
            import msvcrt
            ...
            msvcrt.locking(lock_file.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
```

锁文件是配置旁边的 `.<配置名>.lock`；Windows 走 `msvcrt.locking`，POSIX 走
`fcntl.flock`。多 worker / 多实例共享同一份配置目录时，谁先拿到文件锁谁完成
整个读改写。跨进程排他性有测试钉住：
`backend/tests/test_extensions_config_atomic_write.py:182-204` 用
`multiprocessing` fork 两个子进程各做一次带锁的读改写，断言后写的进程在
前者持锁期间**进不去**、最终两次改动都落盘。

### 15.3.3 原子写：临时文件替换与 EBUSY 回退

写回不是 `open(..., "w")` 就完事——崩溃写到一半的文件会留下残废配置。
`atomic_write_extensions_config`（`extensions_config.py:717-773`）的核心段
（`:741-763`）：

```python
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target_path.parent,
            prefix=f".{target_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary_file:
            temporary_path = Path(temporary_file.name)
            json.dump(data, temporary_file, indent=2)
            if existing_mode is not None:
                temporary_path.chmod(existing_mode)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())

        try:
            os.replace(temporary_path, target_path)
        except OSError as exc:
            if exc.errno != errno.EBUSY:
                raise
            _log_non_atomic_fallback(target_path)
            _overwrite_in_place(target_path, temporary_path)
        _fsync_directory_best_effort(target_path.parent)
```

语义链：同目录临时文件（同目录保证 `os.replace` 原子）→ 写完 fsync →
`os.replace` 原子替换 → 目录 fsync（POSIX）。失败路径全部保旧文件、清理临时
文件（`test_extensions_config_atomic_write.py:60-128` 逐一钉住 json.dump /
replace / fsync 三种失败）。唯一例外是 `EBUSY`：Docker 把
`extensions_config.json` 单独挂载为挂载点，内核拒绝 rename 覆盖挂载点，
此时退化为就地覆盖（会丢原子性，每个目标只警告一次）。

这个 EBUSY 回退正是 `backend/tests/test_extensions_config_atomic_write.py:131-158` 的内容：

```python
def test_atomic_write_falls_back_in_place_when_destination_is_a_mount_point(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Docker mounts extensions_config.json as its own mount point, and the kernel
    answers rename-over-a-mount-point with EBUSY. The write must still land."""
    ...
    def refuse_replace(_source, _destination) -> None:
        raise OSError(errno.EBUSY, "Device or resource busy")
    ...
    # The destination inode must survive: replacing it is exactly what the
    # kernel refused, and a mount point that got unlinked would break the mount.
    assert config_path.stat().st_ino == original_inode
```

### 15.3.4 Compose 的可写性契约

连带的生产约束由 `backend/tests/test_compose_extensions_config_writable.py:73-80` 钉死：

```python
def test_extensions_config_is_mounted_writable() -> None:
    mount = _gateway_volume_for(EXTENSIONS_CONFIG_TARGET)
    assert "ro" not in _mount_options(mount), f"the Gateway writes {EXTENSIONS_CONFIG_TARGET} at runtime, so it must not be mounted read-only: {mount}"


def test_app_config_stays_read_only() -> None:
    mount = _gateway_volume_for(APP_CONFIG_TARGET)
    assert "ro" in _mount_options(mount), f"no API writes {APP_CONFIG_TARGET}; it must stay read-only: {mount}"
```

生产 Compose 里 `extensions_config.json` 必须**读写挂载**（Gateway 要热写它），
`config.yaml` 必须**只读**（没有 API 写它；它携带的顶层 `plugins:` 列表会触发
代码导入，必须留在 operator 专属、API 写不到的文件里——见该测试
`test_compose_extensions_config_writable.py:19-21` 的注释）。这是第 3 章
"两份配置各管什么"的源码级落点。读取侧的新鲜度由文件签名重校验保证：
`get_extensions_config()`（`extensions_config.py:887-936`）每次调用对比
`(mtime, size, sha256)` 签名，其他 worker 写的文件在下次读取时自动可见——
`backend/packages/harness/deerflow/config/AGENTS.md` 的 "Extensions Config
Caching" 节（`config/AGENTS.md:135` 附近）是权威描述。

## 15.4 长任务运行时：McpTaskService

### 15.4.1 问题与结构

有些 MCP 工具天生长时（生成报告、跑数据管道）。若让 Agent 循环自己轮询，
一个 run 要挂住几分钟到几小时，还要求模型"记住"远端任务 ID。DeerFlow 的
答案是一个独立的持久任务运行时：`backend/packages/harness/deerflow/mcp/AGENTS.md:81-84` 总结为——

> Long-running MCP work uses a separate durable task runtime rather than
> keeping remote task IDs or status polling inside the Agent loop. Explicit
> `task_toolsets` bind raw submit/status/cancel names; only submit remains
> Agent-visible, and its wrapper persists the remote handle before returning a
> local ID.

服务器侧用 `task_toolsets` 声明"普通提交/状态/取消"三件套（示例见
`extensions_config.example.json:77-92` 的 `long-running-reports`）：

```json
    "long-running-reports": {
      "enabled": false,
      "type": "http",
      "url": "https://reports.example.com/mcp",
      "description": "Example ordinary MCP background-task contract",
      "session_init_timeout": 60,
      "tool_call_timeout": 60,
      "task_toolsets": [
        {
          "name": "report-generation",
          "submit_tool": "submit_report",
          "status_tool": "get_report_status",
          "cancel_tool": "cancel_report"
        }
      ]
    }
```

三个名字是服务器**原始工具名**（与展示前缀无关，`extensions_config.py:80-96`
的 `McpTaskToolsetConfig`）。协议约束（`backend/docs/MCP_SERVER.md:348-378`）：
三件套必须返回 MCP `structuredContent`；`submit` 快速返回
`{"task_id": ..., "status": "running"}`；状态取值
`running/input_required/completed/failed/cancelled`；`error_code:
"task_not_found"` 是永久失败，而 `isError: true` 的状态调用只是**调用本身**
失败（可重试）——远端任务真失败必须通过正常结果里的
`structuredContent.status="failed"` 表达。

服务类在 App 层：`backend/app/mcp_tasks/service.py:102-103`：

```python
class McpTaskService:
    """Persist and poll long-running MCP tasks outside the Agent loop."""
```

构造依赖（`service.py:105-134`）暴露了运行时形状：`repository`（SQL 存储）、
`drivers`（协议注册表）、`poll_interval_seconds` / `lease_seconds` /
`max_concurrent_polls` 等参数、可选的 `launch_notification`（任务完成时以
Agent run 的形式把结果送回线程）。对应配置段是 `config.yaml → mcp_tasks:`
（`config.example.yaml:2915-2932`：`enabled` 默认 false、`poll_interval_seconds: 5`、
`lease_seconds: 120`、`max_concurrent_polls: 8`……全部 restart-required）。

### 15.4.2 持久化：mcp_tasks 表

`backend/packages/harness/deerflow/persistence/mcp_tasks/model.py:17-30`：

```python
class McpTaskRow(Base):
    __tablename__ = "mcp_tasks"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), index=True)
    thread_id: Mapped[str] = mapped_column(String(64), index=True)
    ...
    server_name: Mapped[str] = mapped_column(String(MCP_TASK_SERVER_NAME_MAX_LENGTH))
    driver_name: Mapped[str] = mapped_column(String(64))
    remote_task_id: Mapped[str] = mapped_column(String(MCP_TASK_REMOTE_ID_MAX_LENGTH))
    task_name: Mapped[str] = mapped_column(String(MCP_TASK_NAME_MAX_LENGTH))
    status: Mapped[str] = mapped_column(String(32), index=True)
```

注意表里**没有** Agent 看得见的远端任务 ID 字段直接暴露给模型——
`remote_task_id` 存在行里，Agent 侧只拿到本地 `id`。轮询/取消/通知三套调度
字段（`next_poll_at` / `next_cancel_at` / `next_notification_at`、各自的重试
计数与租约列）都在 `model.py:42-63`。归属唯一约束在 `model.py:72-78`：

```python
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "server_name",
            "remote_task_id",
            name="uq_mcp_tasks_user_server_remote",
        ),
        Index("ix_mcp_tasks_thread_created", "thread_id", "created_at"),
        Index("ix_mcp_tasks_due", "status", "next_poll_at"),
        Index("ix_mcp_tasks_notification_due", "notification_status", "next_notification_at"),
        Index("ix_mcp_tasks_cancel_due", "cancel_requested_at", "next_cancel_at"),
    )
```

`uq_mcp_tasks_user_server_remote` 防止同一 (用户, 服务器, 远端任务) 重复入库；
三个 `ix_mcp_tasks_*_due` 索引分别服务轮询/通知/取消三类"到期扫描"。

### 15.4.3 租约：崩溃恢复与控制调用所有权

`lease_seconds`（默认 120）是**崩溃恢复窗口**，不是远程调用超时
（`backend/docs/mcp-control-leases.md:3-6`）。工作方式：worker 认领到期行时
写入 `lease_owner` / `lease_token` / `lease_expires_at`；过期未释放的租约就是
"前任已死"的信号，别的 worker 可以接手——这是重启后队列存活的机制。
SQLite 不支持 `SELECT FOR UPDATE`，认领事务用条件 UPDATE 复核/`BEGIN IMMEDIATE`
预留写者，PostgreSQL 用 `FOR UPDATE SKIP LOCKED`
（`mcp-control-leases.md:17-22`）。状态/取消这类"控制调用"在远程请求期间
每 lease/3 续租一次（`mcp-control-leases.md:24-31`），续租失败即停止本地操作，
任务本地所有权栅栏会挡住"吞掉了取消的驱动"稍后写回的过期快照。

协议无关的驱动接口在 `backend/packages/harness/deerflow/mcp/tasks/driver.py:9-14`：

```python
class McpTaskDriver(Protocol):
    """Transport/protocol adapter used by the protocol-neutral task runtime."""

    async def submit(self, request: TaskSubmitRequest) -> TaskSubmission: ...

    async def get_status(self, task: TaskReference) -> TaskSnapshot: ...

    async def cancel(self, task: TaskReference) -> TaskSnapshot: ...
```

`McpTaskDriverRegistry`（同文件 `:17-38`）在 Gateway 启动时装配；普通
submit/status/cancel 契约的实现是
`backend/packages/harness/deerflow/mcp/tasks/ordinary.py:171` 的
`OrdinaryMcpTaskDriver`（`submit` 在 `:177`，`cancel` 在 `:224`），它只读
MCP `structuredContent`、把远端 `running` 映射为本地 `working`。

### 15.4.4 通知、取消与可用性边界

任务终态与 `input_required` 通过**幂等 Agent run**送回原线程：通知有独立的
连续失败计数、上限指数退避、5 次尝试预算，永久拒绝（如目标线程缺失）直接
死信；通知 launch 前先做 owner/token/version/expiry 栅栏化的
`notification_status=launching` 预留，busy-thread 冲突保留预留态与幂等键等
重试（`mcp/AGENTS.md:84`）。取消走 HTTP 端点
`backend/app/gateway/routers/mcp_tasks.py:204-209`：

```python
    if not getattr(request.app.state, "mcp_tasks_available", False):
        ...
        raise HTTPException(status_code=503, detail="MCP task cancellation worker is not running")
```

worker 不在（例如 `mcp_tasks.enabled=false`）就返回 **worker-stopped 503**——
取消绝不会被"确认"却没有 worker 去执行。运行时可用性是启动级事实：
`mcp_tasks` 是 startup-only 配置，改了磁盘上的键不重启不生效；安装在本进程的
submitter 是管理工具暴露与否的唯一真相（`mcp/AGENTS.md:16` 与 `:82`）。
Agent 能主动做的只有两件事：提交（submit 包装器持久化远端句柄后只返回本地
任务 ID），以及用内置管理工具 `list_background_tasks` /
`cancel_background_task` 查询/取消（`tools/tools.py:186-187`）。当前线程的
任务详情另有 REST 查询：`GET /api/threads/{thread_id}/mcp-tasks` 与
`GET /api/threads/{thread_id}/mcp-tasks/{task_id}`（`backend/docs/MCP_SERVER.md:386-390`）。

## 15.5 拦截器：mcpInterceptors

每次 MCP 工具调用前会经过一条拦截器链：内置的 OAuth、按用户凭证
（`user_auth`）、按请求凭证（`headers_from_context`），最后是配置声明的自定义
拦截器。构建函数在 `backend/packages/harness/deerflow/mcp/interceptors.py:18-49`（摘录）：

```python
def build_mcp_tool_interceptors(
    extensions_config: ExtensionsConfig,
    *,
    oauth_builder: Any = build_oauth_tool_interceptor,
    user_auth_builder: Any = build_user_scoped_auth_interceptor,
    context_headers_builder: Any = build_context_headers_interceptor,
    resolver: Any = resolve_variable,
    target_logger: logging.Logger = logger,
) -> list[Any]:
    """Build OAuth, user-scoped auth, context headers, then custom MCP interceptors."""
    interceptors: list[Any] = []
    oauth_interceptor = oauth_builder(extensions_config)
    if oauth_interceptor is not None:
        interceptors.append(oauth_interceptor)

    # After OAuth so a server declaring both gets the per-user credential:
    # interceptors wrap outermost-first, so the later-registered user-scoped
    # override runs closer to the transport and wins the final header value.
    user_auth_interceptor = user_auth_builder(extensions_config)
    if user_auth_interceptor is not None:
        interceptors.append(user_auth_interceptor)
    ...
```

顺序即语义：**先注册的在洋葱外层，后注册的贴近传输层并最终决定 header 值**，
所以优先级是 static `headers` < `oauth` < `user_auth` < `headers_from_context`
（`mcp/AGENTS.md:56`；`context_headers.py` 的拦截器注册在 `user_auth` 之后）。

自定义拦截器在配置里以 `模块:变量` 形式声明（`extensions_config.example.json:3-5`）：

```json
  "mcpInterceptors": [
    "my_package.mcp.auth:build_auth_interceptor"
  ],
```

变量必须是无参 builder，返回一个 async 拦截器（兼容
`MultiServerMCPClient` 的 `tool_interceptors` 接口）或 `None`。
`backend/docs/MCP_SERVER.md:657-673` 给了从请求级 secret 注入 Authorization
的参考实现（读运行时走 `request.runtime`，不要用
`langgraph.config.get_config()["context"]`——run context 挂在 runtime 上，
不随 `RunnableConfig` 传给子 runnable）：

```python
from deerflow.runtime.secret_context import extract_request_secrets


def build_auth_interceptor():
    async def interceptor(request, handler):
        runtime = getattr(request, "runtime", None)
        secrets = extract_request_secrets(getattr(runtime, "context", None))
        token = secrets.get("MCP_AUTH_TOKEN")
        if token:
            request = request.override(
                headers={**(request.headers or {}), "Authorization": f"Bearer {token}"}
            )
        return await handler(request)

    return interceptor
```

生命周期要点（`MCP_SERVER.md:643-649`）：builder **每启用服务器各跑一次**，
不是每次发现跑一次；单台服务器的拦截器实例只观察该服务器的调用。非法路径或
builder 失败记 warning 跳过，不阻塞其他拦截器。

## 15.6 动手实验：接入 GitHub MCP server + 自建 stdio MCP server

两个实验共用一套前置：可运行的 Gateway（`make dev`）、`GITHUB_TOKEN`
（实验 A）或离线环境（实验 B 用本地 Python 服务器，无需外网）。

### 实验一：接入 GitHub MCP server

**步骤 1：准备配置。** 把根目录 `extensions_config.example.json` 复制为
`extensions_config.json`（若已存在则跳过），把 `github` 条目改为启用：

```json
    "github": {
      "enabled": true,
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "$GITHUB_TOKEN" },
      "tool_name_prefix": true,
      "session_init_timeout": 60,
      "tool_call_timeout": 60,
      "description": "GitHub MCP server for repository operations"
    }
```

并在启动 Gateway 的终端环境里导出 `GITHUB_TOKEN`（配置加载时
`$GITHUB_TOKEN` 才会被解析；未设置会解析为空串，GitHub 服务器认证失败）。

**步骤 2：重启 Gateway 并验证发现。** stdio 服务器走 `npx` 拉包，首次启动
可能逼近 `session_init_timeout`（60s）。观察 `logs/gateway.log`：

```
Configured MCP server: github
...
Using N cached MCP tool(s)
```

工具名都带前缀：`github_create_issue`、`github_get_me`、`github_list_issues`…

**步骤 3：对话调用。** 在 `http://localhost:2026` 新建会话，输入
"列出 langchain-ai/langchain 仓库里最新的 5 个 open issue"。观察 agent 选用
`github_list_issues`（或 `github_search_issues`）并携带正确参数。

**步骤 4（可选）：运行时热编辑。** 不重启，直接调
`PATCH /api/mcp/config` 把 `github.enabled` 置回 false（或用设置页的开关），
再开新会话——`github_*` 工具消失、缓存与池化会话被退役；改回 true 又回来。
这就是 15.3 节双锁 + 原子写 + 文件签名重校验链路的直观体验。

### 实验二：自建 stdio MCP server 并调用

用官方 Python SDK（`mcp` 包，含 FastMCP）写一个查询"内部业务系统"的
stdio 服务器。这里用内存字典模拟业务库，完全离线可跑。

**步骤 1：写服务器。** 新建仓库外目录（例如 `D:\Code\mcp-demo\server.py`）：

```python
"""内部业务系统查询 MCP server（stdio 传输）。运行: python server.py"""
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("internal-biz")

ORDERS = {
    "SO-1001": {"customer": "ACME", "amount": 1299.0, "status": "shipped"},
    "SO-1002": {"customer": "Globex", "amount": 89.0, "status": "pending"},
    "SO-1003": {"customer": "ACME", "amount": 430.0, "status": "cancelled"},
}

@mcp.tool()
def query_order(order_id: str) -> dict:
    """按订单号查询内部订单系统。返回订单详情或 not_found。"""
    return ORDERS.get(order_id, {"status": "not_found"})

@mcp.tool()
def list_orders(customer: str | None = None) -> list[dict]:
    """列出订单，可按客户名过滤。"""
    rows = [{"order_id": k, **v} for k, v in ORDERS.items()]
    return [r for r in rows if customer is None or r["customer"] == customer]

if __name__ == "__main__":
    mcp.run()  # 默认 stdio 传输
```

安装 SDK：`uv pip install mcp`（或 `pip install mcp`）。先独立冒烟测试：
`python server.py` 不报错即可（它从 stdin 读 MCP 协议帧，Ctrl-C 退出）。

**步骤 2：注册进 DeerFlow。** 在 `extensions_config.json` 的 `mcpServers`
下新增（`command` 用你环境里能跑 `python` 的绝对路径更稳）：

```json
    "internal-biz": {
      "enabled": true,
      "type": "stdio",
      "command": "python",
      "args": ["D:/Code/mcp-demo/server.py"],
      "tool_name_prefix": true,
      "session_init_timeout": 30,
      "tool_call_timeout": 30,
      "description": "内部业务系统订单查询"
    }
```

注意：通过 **API**（`PUT /api/mcp/config`）提交这台服务器时，
`_validate_mcp_update_request` 的 stdio 白名单（默认只放 `npx`/`uvx`）会拒绝
`python`——直接编辑本地 `extensions_config.json` 再重启，或把
`DEER_FLOW_MCP_STDIO_COMMAND_ALLOWLIST` 设为 `npx,uvx,python` 后走 API
（见 `backend/app/gateway/routers/mcp.py:665-694` 与
`mcp/AGENTS.md:73`）。这正是"配置文件表达力 > API 边界"的现成例子。

**步骤 3：重启 Gateway，验证工具出现。** 日志出现
`Configured MCP server: internal-biz`；新会话里问
"查一下订单 SO-1002 的状态"，agent 应调用 `internal-biz_query_order`，
返回 `{"customer": "Globex", "amount": 89.0, "status": "pending"}`。
再问"列出 ACME 的所有订单"验证 `internal-biz_list_orders`。

**步骤 4：观察 stdio 会话隔离。** 同一线程里连续问两次查询——第二次不重启
子进程（会话池复用）；换一个新线程再查——新线程拿到自己的会话作用域。
可用 `GET /api/mcp/config` 确认服务器在列；用 `POST /api/mcp/cache/reset`
强制重新发现，观察日志里整池退役再重建。

### （进阶）长任务闭环

如果完成了两个基础实验，可再走一遍 `long-running-reports` 契约：在
`config.yaml` 打开 `mcp_tasks:`（`enabled: true`，注意 restart-required 且
需要 `database.backend: sqlite` 或 `postgres`），为你的 `internal-biz` 服务器
加一个 `task_toolsets`（本地实现 submit 返回 `{"task_id": "R-1", "status":
"running"}`、`get_report_status` 数秒后返回 `completed`），然后：
对话中提交 → 拿到本地任务 ID → `GET /api/threads/{id}/mcp-tasks/{task_id}`
观察轮询 → 用 `cancel_background_task`（或 HTTP 取消端点）走一次取消。
这一段把 15.4 节的租约、通知与 503 语义全部点亮。

## 常见坑

1. **改了配置不生效（没重启/没触发重载）**。工具缓存由文件签名两段式检查
   守护：`(mtime, size, sha256)` 变化且"有效 MCP 切片"变化才退役
   （`mcp/AGENTS.md:51`）。只改 `skills` 或 `middlewares` 不动 MCP 服务器时，
   已缓存的 MCP 工具**有意**保留。而 `mcp_tasks`、`mcpInterceptors`、
   task-enabled 服务器的连接/超时改动是 startup-only——必须重启
   （`MCP_SERVER.md:447-453`）。远程服务器偷偷改了 `tools/list` 也不会自动
   发现，用 `POST /api/mcp/cache/reset`。
2. **把 `$VAR` 写成混合字符串**。`"Bearer $GITHUB_TOKEN"` 不会被展开——只有
   **整串**以 `$` 开头才解析（`MCP_SERVER.md:150-155`）。要么环境变量里放好
   `Bearer <token>` 全值，要么用拦截器拼装。未设置的变量解析为空串
   （`extensions_config.py:584-590`），服务器会拿到空凭证而非报错。
3. **自己把 `extensions_config.json` 挂成只读、或用单文件 bind mount**。
   前者让所有 Gateway 写路径 500（`test_compose_extensions_config_writable.py`
   的存在就是防这个回归）；后者在宿主编辑器"保存替换文件"时可能 stale。
   Docker 配置文件应放在**目录** bind mount 之后（`config/AGENTS.md:120-123`）。
4. **给 stdio 服务器配了 filesystem MCP server**。DeerFlow 自带线程工作区
   文件工具，两套文件工具语义不同会让模型选择行为不稳，且 DeerFlow 不适配
   MCP Roots（`MCP_SERVER.md:293-304`）。
5. **在拦截器里读 `langgraph.config.get_config()["context"]`**。工具调用里
   这个键是 `None`；run context 在 runtime 上，用 `request.runtime`
   （`mcp/AGENTS.md:58`、`MCP_SERVER.md:675-683`）。
6. **以为 `lease_seconds` 是远程调用超时**。它是崩溃恢复窗口；远程调用的
   期限由服务器配置的 `tool_call_timeout` 控制（`mcp-control-leases.md:3-6`）。
   把租约调小想让慢调用"早点失败"只会造成所有权抖动，正确做法是调
   `tool_call_timeout`。

## 下一步

你现在已经能把任意外部系统工具化进 DeerFlow。下一章把"不改核心"的另一半
补齐：**扩展（Extensions）开发**——middleware / lifecycle observers /
Gateway services / FastAPI routers / full-stack plugins 五类贡献点，
`make extension-install` 生命周期，以及 `config.yaml → plugins:` 与
`extensions_config.json` 两条配置通道的区别。见《第 16 章 扩展（Extensions）
开发》（`docs/tutorials/16-extensions.md`）；本章的 `mcpInterceptors` 与
第 14 章的 `deerflow_extension_api` 契约包都是它的前置。
