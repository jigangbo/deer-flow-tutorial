# 第 3 章 配置系统入门

## 3.0 学习目标

读完本章，你应该能够：

1. 说清两份运行时配置的分工：`config.yaml` 管什么、`extensions_config.json` 管什么，
   以及为什么这个边界不能混；
2. 理解"运行时可热改"的范围：哪些改动立即生效、哪些要重启 Gateway、哪些每个 run 各读一次；
3. 独立修改五个最常改的配置段：`models`、`sandbox`、`summarization`、`memory`、
   `scheduler.enabled`；
4. 通过"故意写坏配置"掌握配置加载失败的排障路径。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 配置模板 | `config.example.yaml`（3713 行，顶层键索引见 3.1） |
| 扩展配置模板 | `extensions_config.example.json` |
| 配置权威文档 | `backend/docs/CONFIGURATION.md` |
| 配置查找顺序 | `backend/docs/CONFIGURATION.md:2153`、`backend/docs/SETUP.md:52` |
| 版本升级 | `backend/docs/CONFIGURATION.md:105`、`Makefile:90`（config-upgrade） |
| 运行时热写 | `backend/AGENTS.md:22` |
| dev 模式配置热重载 | `backend/Makefile:12` |

---

## 3.1 两份配置各管什么

DeerFlow 的配置是"**两份文件 + 一个模板对**"：

| 文件 | 模板 | 管什么 | 谁可写 |
| --- | --- | --- | --- |
| `config.yaml` | `config.example.yaml` | 模型、工具组、沙箱、记忆、摘要、调度器、数据库、部署拓扑…… | 操作员（operator），建议手工/向导编辑 |
| `extensions_config.json` | `extensions_config.example.json` | MCP 服务器 + 技能启用状态（+ 中间件/拦截器槽位） | Gateway API 与 Web 界面可在运行时写 |

### `config.yaml` 的顶层键地图

`config.example.yaml` 约 3700 行，绝大部分是注释样例。用
`grep -n "^[a-z_]*:" config.example.yaml` 可以拿到全部顶层键，按功能分区记忆：

- **运行时行为**：`config_version`（:23）、`log_level`（:46）、`logging`（:52）、
  `recursion_limit`（:120）/`max_recursion_limit`（:125）、`token_usage`（:96）、
  `token_budget`（:106）；
- **Agent 能力**：`models`（:157）、`knowledge_base`（:825）、`tool_groups`（:836）、
  `tools`（:849）、`uploads`（:1705）、`sandbox`（:1732）、`subagent_runtime`（:2011）、
  `subagent_batches`（:2102）、`verification`（:2122）、`skills`（:2173）；
- **上下文治理**：`loop_detection`（:1505）、`pii_redaction`（:1538）、
  `summarization`（:2242）、`memory`（:2353）、`title`（:2223）；
- **持久化与拓扑**：`database`（:2733）、`run_events`（:2805）、`agent_storage`（:2844）、
  `deployment`（:2956）、`run_ownership`（:2981）；
- **调度与后台**：`scheduler`（:2895）、`mcp_tasks`（:2925）。

每个顶层键在 `backend/docs/CONFIGURATION.md` 都有对应小节——它是配置权威文档，
遇到任何键先查它。

### `extensions_config.json` 的四键结构

模板 `extensions_config.example.json` 只有 95 行，四个顶层键一目了然：

```json
{
  "middlewares": [],
  "mcpInterceptors": [
    "my_package.mcp.auth:build_auth_interceptor"
  ],
  "mcpServers": {
    "github": {
      "enabled": false,
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "$GITHUB_TOKEN" },
      "tool_name_prefix": true,
      "session_init_timeout": 60,
      "tool_call_timeout": 60
    }
  },
  "skills": {}
}
```

（摘自 `extensions_config.example.json:2`；`skills` 键在 :94。）

MCP 服务器支持 `stdio`（`command`/`args`/`env`）与 `http`（`url`/`headers`）两种类型；
`env` 里的 `$GITHUB_TOKEN` 是运行时环境变量解析。模板里还有带 `routing` 软路由提示的
`postgres` 示例（:41）和演示长任务契约的 `long-running-reports`（:77）。

### 为什么 `plugins:` 只留在 `config.yaml`

根 `AGENTS.md` 给出了一条硬规则：

> Third-party extensions load from operator-controlled `config.yaml -> plugins:`.
> This imports code, so the list stays outside API-writable `extensions_config.json`.

原理：`plugins:` 列表会触发 **Python 代码导入**，导入即执行；而 `extensions_config.json`
是 Gateway API 可写的文件——如果把可导入代码的路径放进一个"网页上点几下就能改"的文件，
等于把代码执行权交给了所有有界面权限的人。所以：**会 import 代码的配置只走 operator 专属的
`config.yaml`，API 可写的文件里只放数据型配置**（MCP、技能开关）。

---

## 3.2 运行时可热改：生效时机全景

"改了配置要不要重启"是最高频问题，答案分三档：

### 第一档：立即生效（每次读取都重新校验）

`extensions_config.json` 的运行时编辑（Web 界面、MCP/技能 API、手工改文件）会被**所有**
读同一份文件的 Gateway 进程感知。`backend/docs/CONFIGURATION.md:128`：

> Runtime edits to `extensions_config.json` ... are picked up by every Gateway process
> that reads the same file: the process cache revalidates the file's path and content
> signature on each read, so uvicorn workers and multi-instance Pods sharing one volume
> converge without a restart or a per-Pod reload call.

并发写安全也有保障：Gateway 写这份文件时持双锁
（`extensions_config_write_lock` + sidecar 文件锁）并用临时文件原子替换
（`backend/AGENTS.md:22`）；损坏/半写的文件不会污染已加载配置
（`backend/docs/CONFIGURATION.md:134`）。

### 第二档：dev 模式热重载 / 按次读取

- `make dev` 的 Gateway 带 `--reload-include='*.yaml' --reload-include='.env'`
  （`backend/Makefile:12`）——**改 `config.yaml` 会触发开发模式下的自动重载**；
- 即使在非重载环境，许多键也是"按 run/按次读取"的：例如 `recursion_limit` 与
  `max_recursion_limit` "read per run, so changes apply to the next request without a
  Gateway restart"（`backend/docs/CONFIGURATION.md:145`）；调度器启动时读取的
  `scheduler.recursion_limit` 同样每次派发读取（`backend/AGENTS.md:14`）。

### 第三档：必须重启 Gateway

- 进程生命周期类字段：`scheduler` 的 poller 字段（`enabled`、`multi_instance`、
  `poll_interval_seconds` 等）"restart-required"（`backend/docs/CONFIGURATION.md:777`）；
- `mcp_tasks:` 整段 "All fields are restart-required (captured at Gateway lifespan
  startup)"（`config.example.yaml:2913`）；
- `logging.enhance`：注释明确 "Restart required (see reload_boundary.py)"
  （`config.example.yaml:51`）；
- 模型请求限流 `request_admission`："Restart the Gateway after changing, disabling or
  regrouping active policies"（`backend/docs/CONFIGURATION.md:81`）。

**保守原则**：不确定时重启 Gateway——它永远不亏。

### 配置文件查找顺序

无论 `config.yaml` 还是 `extensions_config.json`，查找优先级一致
（`backend/docs/CONFIGURATION.md:2157`）：

1. 代码里的 `config_path` 参数；
2. `DEER_FLOW_CONFIG_PATH` 环境变量；
3. `DEER_FLOW_PROJECT_ROOT`（或当前工作目录）下的 `config.yaml`；
4. 兼容旧 monorepo 的遗留位置。

推荐放仓库根（`backend/docs/SETUP.md:61`）。运行时数据根默认是 `<项目根>/.deer-flow`，
可用 `DEER_FLOW_HOME` 迁移（`config.example.yaml:8`）。

### 版本升级：`make config-upgrade`

`config.example.yaml:23` 的 `config_version: 64` 是 schema 版本戳。当模板版本高于你的
`config.yaml` 时，启动会告警（`backend/docs/CONFIGURATION.md:110`）：

```text
WARNING - Your config.yaml (version 0) is outdated — the latest version is 1.
Run `make config-upgrade` to merge new fields into your config.
```

`make config-upgrade`（`Makefile:90`）自动合并缺失字段：保留你已有的值，并生成 `.bak`
备份（`backend/docs/CONFIGURATION.md:115`）。

---

## 3.3 常改项 TOP 5

### ① `models` —— 换供应商/加模型

最常改的段。最小可用条目（OpenAI 兼容供应商也用 `langchain_openai:ChatOpenAI` 加
`base_url`，见 `backend/docs/CONFIGURATION.md:222`）：

```yaml
models:
  - name: deepseek-v4
    display_name: DeepSeek V4 (Thinking)
    use: deerflow.models.patched_deepseek:PatchedChatDeepSeek
    model: deepseek-v4-pro
    api_key: $DEEPSEEK_API_KEY
    timeout: 600.0
    max_retries: 2
    max_tokens: 8192
    supports_thinking: true
    supports_vision: false
```

（结构摘自 `config.example.yaml:484`。）要点：`use:` 决定 LangChain 类；`api_key: $VAR`
引用 `.env`；`supports_vision` 等能力位决定中间件行为。

### ② `sandbox` —— 本地直执行 vs Docker 隔离

默认是本地直执行（`config.example.yaml:1732`）：

```yaml
sandbox:
  use: deerflow.sandbox.local:LocalSandboxProvider
  allow_host_bash: false   # 本地沙箱不是安全隔离边界，默认禁 shell
```

生产/隔离需求切换为容器沙箱（`config.example.yaml:1788`）：

```yaml
# sandbox:
#   use: deerflow.community.aio_sandbox:AioSandboxProvider
#   image: enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0
```

安全语义对比见 `backend/docs/CONFIGURATION.md:2174` 的三模式表
（local / aio DooD / provisioner）。切换前建议先 `make setup-sandbox` 预拉镜像。

### ③ `summarization` —— 长对话自动压缩

默认开启（`config.example.yaml:2242`）：

```yaml
summarization:
  enabled: true
  model_name: null            # null = 用当前 run 的模型做摘要
  trigger:
    - type: tokens
      value: 32000            # 任一阈值命中即触发（OR）
  keep:
    type: messages
    value: 10                 # 保留最近 10 条
```

（摘自 `config.example.yaml:2242`。）`trigger` 支持 `tokens` / `messages` / `fraction`
三类；`fraction` 需要 `context_window` 才能解析，第三方 OpenAI 兼容模型要显式声明
（`config.example.yaml:2263`）。

### ④ `memory` —— 跨会话记忆

默认开启（`config.example.yaml:2353`）：

```yaml
memory:
  enabled: true
  injection_enabled: true   # 是否注入 system prompt
```

DeerMem 后端的私有参数（抽取模型、`max_facts`、置信阈值、注入 token 预算等）全部放在
`memory.backend_config` 下，注释清单见 `config.example.yaml:2321`。

### ⑤ `scheduler.enabled` —— 定时任务总闸

默认关闭（`config.example.yaml:2895`）：

```yaml
scheduler:
  enabled: false
  tool_enabled: false        # 是否向授权会话提供 schedule 工具
  multi_instance: false
  poll_interval_seconds: 5
  max_concurrent_runs: 3
```

（摘自 `config.example.yaml:2895`。）注意两个开关的语义差异：`enabled` 控后台轮询，
`tool_enabled` 控制**会话内**的 `schedule_task` 工具（根 `AGENTS.md` 的
Scheduled-task note）。两者都要重启 Gateway 生效（poller 字段 restart-required）。

---

## 动手实验 3-1：切换默认模型并验证生效

1. 在 `config.yaml` 的 `models:` 下确认有两个可用模型条目（例如一个 Doubao、一个
   DeepSeek，Key 都写在 `.env`）；
2. **不重启** Gateway（若在 `make dev` 下它自己会热重载），在 Web 界面新开一个会话，
   在模型选择器里切换到另一个模型并发一条消息，确认回复风格/自我介绍与所选模型一致；
3. 用配置校验命令验证后端真的读到了你改的文件
   （命令来自 `backend/docs/SETUP.md:41`，在仓库根执行）：

   ```bash
   uv run --no-sync --project backend python -c "from deerflow.config import get_app_config; print('✓ Config loaded:', get_app_config().models[0].name)"
   ```

4. 把 `models[0]` 换成另一个条目（调整列表顺序），重跑上面的命令观察输出变化。

## 动手实验 3-2：故意写坏配置，观察报错

1. 备份 `config.yaml`，然后在其中制造一个 YAML 语法错误（比如把某行缩进改坏或删一个
   冒号），或在 `models:` 里写一个不存在的 `use:` 类路径；
2. 重启 Gateway（`make stop && make dev`），观察 `logs/gateway.log`：
   - YAML 语法错误：启动即失败，日志给出解析错误位置；
   - `use:` 路径错误：在构建模型时报 actionable import error；
3. 记住这两类报错的"指纹"，然后恢复备份、重启确认恢复正常；
4. 进阶：把 `scheduler.enabled` 改为 `true` 但保留 `database.backend` 为默认 SQLite，
   再开启 `multi_instance: true` 重启——观察多实例启动门禁的 fail-fast 报错
   （`backend/AGENTS.md:16`：multi_instance 需要 Postgres + 心跳 + DB 事件后端）。
   看完改回来。

---

## 常见坑

1. **改了配置"没生效"就到处找缓存**：先判断该键属于哪一档——`extensions_config.json`
   即时生效；`config.yaml` 在 `make dev` 下热重载；poller/`mcp_tasks`/`logging.enhance`/
   `request_admission` 等要重启（见 3.2 三档清单）。
2. **两份配置的角色记反**：`extensions_config.json` 是 API 可写的（MCP/技能），
   `config.yaml` 是 operator 专属的（含会导入代码的 `plugins:`）；不要把插件列表写进
   `extensions_config.json`。
3. **`config.yaml` 提交进了 git**：它含密钥且 gitignored；误提交后除了 `git rm --cached`
   还要轮换泄露的 Key。
4. **`config_version` 落后导致行为怪异**：schema 升级后旧配置缺新字段，跑
   `make config-upgrade` 合并（自动备份 `.bak`）。
5. **密钥写死在 `config.yaml`**：用 `api_key: $ENV_VAR` 引用 `.env`；明文 Key 会经
   配置读取接口暴露。
6. **改了 `sandbox.use` 但没拉镜像**：容器沙箱第一次执行才拉镜像会等数分钟；先
   `make setup-sandbox` 预拉（`backend/docs/SETUP.md:63`）。
7. **找不到配置文件被读自哪里**：用 `backend/docs/SETUP.md:84` 提供的
   `AppConfig.resolve_config_path()` 片段直接打印解析结果。

---

## 下一步

配置已经是"可编程"的了，但你现在还只在聊天页里打转。下一章《第 4 章 前端界面与基本功能
导览》把 `/workspace` 下每个页面过一遍：会话页、自定义 Agent、公开演示页、定时任务页与
双语用户手册——见 `04-frontend-tour.md`。
