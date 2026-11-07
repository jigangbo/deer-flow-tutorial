# 第 0 章 全景鸟瞰

## 0.0 学习目标

读完本章，你应该能够：

1. 用一句话说清 DeerFlow 是什么：基于 LangGraph 的开源"超级 Agent Harness"，而不是一个简单的聊天前端；
2. 画出四服务拓扑（Nginx / Gateway / Frontend / Provisioner），并解释为什么浏览器入口是 `2026` 而不是 `3000` 或 `8001`；
3. 理解后端 Harness / App 两层依赖方向，知道读代码时该进 `backend/packages/harness/` 还是 `backend/app/`；
4. 知道本教程每一章对应仓库里的哪些源码与文档锚点，为后续章节建立"地图感"；
5. 说出一套 DeerFlow 代码能同时覆盖的四种交互面：Web、IM 渠道、定时任务、TUI。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 全局架构 | `docs/ARCHITECTURE.md` |
| 服务拓扑与启动模式表 | `AGENTS.md`、`backend/AGENTS.md:237` |
| 根命令一览 | `Makefile:26`（help 输出）、`Makefile:72`（setup 起） |
| 四份模型/能力配置样例 | `config.example.yaml:157`（models）、`config.example.yaml:2895`（scheduler）、`extensions_config.example.json:6`（mcpServers） |
| 后端分层 | `backend/AGENTS.md:147`（Harness / App Split）、`backend/packages/harness/deerflow/` |
| 中间件链 | `backend/packages/harness/deerflow/agents/factory.py:214` |
| 前端结构 | `frontend/AGENTS.md:120`（Source Layout）、`frontend/src/app/` |

---

## 0.1 DeerFlow 是什么

DeerFlow（**D**eep **E**xploration and **E**fficient **R**esearch **Flow**）是一个构建在
LangGraph 之上的开源"超级 Agent Harness"。官方架构文档的定义只有一段话，但每个词都值得展开
（`docs/ARCHITECTURE.md:17`）：

> A single "lead agent" orchestrates **sub-agents**, **persistent memory**, **sandboxed
> code execution**, and **extensible skills/tools** — all isolated per conversation thread.

拆开来看，DeerFlow 的核心能力有五块：

- **Lead Agent（主智能体）**：一个由 LangGraph 图驱动的编排者，负责理解用户意图、拆解任务、
  决定什么时候委派子代理、什么时候直接调用工具；
- **Sub-agents（子代理）**：可并行委派的执行单元，通过 `SubagentExecutor` 在后台运行，
  结果通过 `task_*` SSE 事件流回前端（见 `docs/ARCHITECTURE.md:154`）；
- **持久记忆（DeerMem）**：跨会话抽取、存储并注入用户偏好与事实，配置位于
  `config.example.yaml:2353`；
- **沙箱执行**：Agent 生成的代码与命令在可配置的沙箱中运行——开发态是
  `LocalSandboxProvider`，生产态是 Docker 隔离的 `AioSandboxProvider`
  （`docs/ARCHITECTURE.md:101`）；
- **可扩展的 Skills / Tools / MCP**：内置工具、配置工具、MCP 工具三源合并
  （`docs/ARCHITECTURE.md:97`），加上 `skills/public/` 下 23 个官方技能包，以及任意
  MCP server 与 Python 扩展。

**"按会话线程隔离"**（isolated per conversation thread）是理解 DeerFlow 的钥匙：每个
thread 有独立的数据目录 `backend/.deer-flow/threads/{thread_id}/`，上传、产物、checkpoint
互不串扰（`docs/ARCHITECTURE.md:93`）。这也是"超级 Agent Harness"里 harness 一词的含义——
它不只是调用一次大模型，而是把"跑一个 Agent"所需的全部运行时设施（状态、工具、沙箱、记忆、
流式输出、持久化）封装成可托管的底座。

### 一次对话在系统里的样子

用户在浏览器发送一条消息后，请求的完整旅程是：

1. 前端（Next.js）通过 LangGraph SDK 发起一次 run；
2. Nginx 把 `/api/langgraph/*` 重写到 Gateway 的原生 `/api/*` 路由；
3. Gateway 的 `RunManager` + `run_agent()` + `StreamBridge` 组装 lead agent，并在模型调用前
   依次执行中间件链；
4. Agent 循环调用模型与工具（工具在沙箱中执行），产出流式回复、artifacts、todos；
5. SSE 事件沿原路流回，前端把消息、任务卡、产物渲染到会话页。

其中第 3 步的中间件链是 DeerFlow 后端的主干线，定义在
`backend/packages/harness/deerflow/agents/factory.py:214`：

```python
"""Build an ordered middleware chain + extra tools from *feat*.

Middleware order matches ``make_lead_agent`` (18 middlewares):

  0-2. Sandbox infrastructure (ThreadData → Uploads → Sandbox)
  3.   DanglingToolCallMiddleware (always)
  4.   GuardrailMiddleware (guardrail feature)
  5.   ToolErrorHandlingMiddleware (always)
  ...
  6.   SummarizationMiddleware (summarization feature)
  7.   TodoMiddleware (plan_mode parameter)
  8.   TitleMiddleware (auto_title feature)
  ...
  14.  ClarificationMiddleware (always last)
"""
```

从沙箱基础设施（`factory.py:249` 起，`ThreadDataMiddleware` → `UploadsMiddleware` →
`SandboxMiddleware`）到压缩、标题、记忆、视觉，再到永远垫底的
`ClarificationMiddleware`（`factory.py:454`），18 个中间件构成了"每次模型调用前发生了什么"
的完整答案。第二篇第 6 章会逐个拆解，这里只需要建立直觉：**DeerFlow 的所有横切能力都是
以中间件形态挂在 Agent 循环上的**。

---

## 0.2 从 v1 到 v2：一次彻底重写

DeerFlow 2.0 与大家印象中"做 Deep Research 报告"的旧版框架**不共享任何代码**。
`docs/ARCHITECTURE.md:10` 开篇即声明：

> DeerFlow 2.0 is a ground-up rewrite of the original Deep Research framework
> (see `README.md`); it shares no code with v1.

这意味着：网上很多基于 v1 的教程、`main.py`/`crew.py` 之类的入口文件、`web` 目录结构，在
2.0 仓库里都不存在了。判断你手头资料是否过时的最快方法——2.0 的根目录是
`backend/ + frontend/ + docker/` 三分结构，入口命令是根 `Makefile` 的 `make dev`。
阅读本教程时也请以仓库内文档（`AGENTS.md`、`docs/`、`backend/docs/`）为第一真相源。

---

## 0.3 四服务拓扑：为什么入口是 2026

一条 `make dev` 命令会拉起四个协作服务（`docs/ARCHITECTURE.md:31`）：

| 服务 | 端口 | 角色 |
| --- | --- | --- |
| **Nginx** | `2026` | 统一反向代理入口——浏览器只打开它 |
| **Gateway API** | `8001` | FastAPI REST API + 内嵌 LangGraph 兼容运行时 |
| **Frontend** | `3000` | Next.js Web 界面 |
| **Provisioner** | `8002` | 可选——仅当沙箱配置为 provisioner/K8s 模式时启用 |

Nginx 的路由契约是整个系统的入口规则（`docs/ARCHITECTURE.md:38`）：

```text
- /api/langgraph/*  → Gateway's LangGraph-compatible runtime (rewritten to native /api/*)
- /api/* (other)    → Gateway REST routers
- /* (non-API)      → Frontend
```

这里有两个初学者最容易困惑的点：

1. **为什么浏览器访问 `http://localhost:2026` 而不是 `3000`？**
   因为 Nginx 是唯一公网入口：它既代理 `/api/*` 到 Gateway，又直接伺服前端静态资源。
   前端的 `3000` 与 Gateway 的 `8001` 在本地模式都绑定在 `127.0.0.1` 回环地址上，
   仅作为 Nginx 的上游存在。这一"回环默认"由测试硬性约束：
   `backend/tests/test_compose_default_bind_host.py` 固定 Compose 里每个服务的绑定地址，
   `backend/tests/test_local_dev_loopback_bind.py` 固定本地 `make dev`/`make start` 的绑定。

2. **为什么标准 LangGraph SDK 能直连 DeerFlow？**
   因为 Gateway 内嵌了 LangGraph 兼容运行时，Nginx 把 `/api/langgraph/*` 原样重写到
   Gateway 的原生路由（`docs/ARCHITECTURE.md:43`）——不需要再单独部署一个 LangGraph
   Platform server。

Provisioner（`8002`）是可选的第四服务：只有当 `config.yaml` 的 `sandbox.use` 配置为
`AioSandboxProvider` 且带有 `provisioner_url` 时（K8s 沙箱模式），Docker 栈才会启动它。
默认开发流程完全可以忽略它。

---

## 0.4 知识地图与阅读路线

### 后端：Harness / App 两层

后端是两层结构，依赖方向严格单向（`docs/ARCHITECTURE.md:53`、`backend/AGENTS.md:147`）：

- **Harness**：`backend/packages/harness/deerflow/`，import 前缀 `deerflow.*`——可独立发布的
  Agent 框架包，包含编排、工具、沙箱、模型、MCP、技能、配置等"构建和运行 Agent 所需的一切"；
- **App**：`backend/app/`，import 前缀 `app.*`——未发布的应用层代码，即 FastAPI Gateway 与
  IM 渠道集成（飞书、Slack、Telegram、钉钉等）。

依赖规则一句话：**App 可以 import `deerflow`，`deerflow` 永远不 import `app`**。
这条规则由 CI 中的 `backend/tests/test_harness_boundary.py` 强制执行。还有第三个更薄的包
`deerflow-extension-api`（`backend/packages/extension-api/`），定义与宿主无关的扩展契约。

读代码的导航口诀：

- 想**改 Agent 行为本身**（循环、中间件、工具、沙箱）→ 进 `backend/packages/harness/deerflow/`；
- 想**查一条 REST API 或 IM 渠道逻辑** → 进 `backend/app/`；
- 想**接入外部系统而不改核心** → 先看第 16 章的扩展机制与 `examples/` 目录。

### 前端：app 路由 + core 业务域

前端是 Next.js 16 / React 19 / Tailwind v4（`frontend/AGENTS.md:9`），源码分三块
（`docs/ARCHITECTURE.md:117`）：

- `app/` — App Router 路由：`/workspace/chats/[thread_id]`（登录后聊天）、
  `/workspace/agents/[agent_name]`（自定义 Agent）、`/showcase/[thread_id]`（公开只读演示）、
  `(auth)/{login,setup,auth/callback}` 等；
- `core/` — 业务逻辑心脏：`threads/`（创建、流式、状态）、`api/`、`agents/`、`artifacts/`、
  `skills/`、`mcp/`、`memory/`、`integrations/` 等域；
- `components/` — UI 组件，其中 `ui/` 与 `ai-elements/` 是注册表生成物，禁止手改
  （`frontend/AGENTS.md:173`）。

流式数据流一句话概括（`docs/ARCHITECTURE.md:129`）：`core/threads/` 通过 `core/api/` 的
LangGraph SDK 单例订阅 run 流，把 SSE 事件（消息、`values`、`task_*`、artifact 增量）归一化
为 TanStack Query 状态，再交给组件渲染。

### 本教程与官方文档的对应关系

本教程不复制官方文档，而是给每章配"锚点"，遇到细节以官方文档为准：

| 教程章节 | 主要官方锚点 |
| --- | --- |
| 第 0 章（本章） | `docs/ARCHITECTURE.md`、`AGENTS.md` |
| 第 1–2 章 环境与启动 | `Install.md`、`CONTRIBUTING.md`、根 `Makefile` |
| 第 3 章 配置 | `backend/docs/CONFIGURATION.md`、`backend/docs/SETUP.md` |
| 第 4 章 前端导览 | `frontend/AGENTS.md`、`frontend/src/content/{en,zh}/` |
| 第 5 章 运行方式 | `scripts/serve.sh`、`scripts/docker.sh`、`scripts/deploy.sh`、`deploy/helm/deer-flow/` |
| 第 6 章起 进阶篇 | `backend/AGENTS.md`、`backend/docs/`、`backend/packages/harness/deerflow/` 各模块 `AGENTS.md` |

---

## 0.5 为什么值得学：一套代码，四个交互面

DeerFlow 最划算的地方在于：**同一套 Gateway 运行时，同时服务四种交互面**。

1. **Web**：Next.js 聊天界面，含会话、artifacts 面板、todos 任务卡、`/goal` 目标
   条件（`docs/ARCHITECTURE.md:112`）；
2. **IM 渠道**：飞书、Slack、Telegram、Discord、钉钉通过 Gateway 桥接进*同一个* Agent
   （`docs/ARCHITECTURE.md:20`），渠道代码在 `backend/app/channels/`；
3. **定时任务**：`config.yaml → scheduler.enabled` 打开后，`/workspace/scheduled-tasks`
   页面 + 后台调度器复用与 Web 完全相同的 run 生命周期
   （`docs/ARCHITECTURE.md:157`）；
4. **TUI**：终端工作台（`README.md:4068` 的 Terminal Workbench），不打开浏览器也能对话。

除此之外，学 DeerFlow 还有三个工程层面的理由：

- **它是"Agent 平台"的完整参考实现**：流式协议、线程隔离、沙箱安全、记忆、子代理并发控制、
  配置热更新、多实例租约——每一项都是真实生产问题，且都有对应测试钉住行为；
- **扩展优先的架构哲学**：新功能优先做成打包扩展而非改核心（`AGENTS.md` 的
  "Extension-first evaluation"一节），`examples/deerflow-extension-{example,bookmarks,agent-teams}`
  提供了可运行范例，这套贡献点设计本身就是教材；
- **文档与代码同步的文化**：`AGENTS.md` 体系 + 每个 subsystem 一份 scoped 指南 +
  `backend/docs/` 的专题文档，让你能顺着锚点读懂一个真实的复杂系统。

最后必须提前强调安全边界：DeerFlow 具备**系统命令执行、资源操作**等高权限能力，默认设计是
**仅通过 `127.0.0.1` 回环访问的本地可信环境**（`README.md:4137` 的 Security Notice）。
Gateway 管理员相当于拥有主机代码执行权限（`README.md:4144`）。任何非回环部署都必须先读
`README.md` 的 Security Notice 与 `SECURITY.md`，本教程第 5 章与第 20 章会反复回到这个主题。

---

## 动手实验 0-1：给仓库画一张"我自己的地图"

不启动任何服务，纯离线完成：

```bash
# 1. 确认四份顶层 AGENTS.md 都在
ls AGENTS.md backend/AGENTS.md frontend/AGENTS.md backend/packages/harness/deerflow/AGENTS.md

# 2. 数一数 harness 包里的子系统目录（对应第 6-12 章的拆解对象）
ls backend/packages/harness/deerflow/

# 3. 看看 Gateway 应用层有什么
ls backend/app/

# 4. 浏览根 Makefile 的 help 输出，圈出你在第 1-5 章会用到的命令
make help
```

然后在纸上（或笔记里）画出四服务拓扑图，并标注：浏览器访问哪个端口、`/api/langgraph/*`
最终落到哪个进程、前端进程监听哪里。对照 `docs/ARCHITECTURE.md:31` 的表格自查。

预期产出：一张手绘拓扑图 + 一份你圈出的"将要用到的 make 命令"清单。后续五章会逐一验证
这张图。

---

## 常见坑

1. **把 DeerFlow 当成"又一个 Deep Research 脚本"**：2.0 是彻底重写的 Agent 平台，与 v1
   不共享代码（`docs/ARCHITECTURE.md:10`）；搜到的旧教程入口文件在新仓库里不存在。
2. **直连 `localhost:3000` 或 `8001` 却发现页面/接口行为怪异**：`3000`/`8001` 是回环绑定的
   内部服务，浏览器统一入口是 Nginx 的 `2026`（`docs/ARCHITECTURE.md:31`）。
3. **以为要单独装 LangGraph Server**：Gateway 已内嵌 LangGraph 兼容运行时，
   `/api/langgraph/*` 由 Nginx 重写到 Gateway 原生路由（`docs/ARCHITECTURE.md:43`）。
4. **把 `config.yaml` 提交进 git**：它是 gitignored 的运行时配置且含密钥，仓库里只有
   `config.example.yaml` 模板（`AGENTS.md` 的 Repository Map 一节）。
5. **在不可信网络上裸部署**：Agent 能执行系统命令，默认模型是回环可信环境；非回环部署前
   必须读 `README.md:4135` 起的 Security Notice（IP allowlist、认证网关、网络隔离）。
6. **试图手改 `frontend/src/components/ui/`**：那是 Shadcn / Vercel AI SDK 注册表生成物，
   手改会被覆盖（`frontend/AGENTS.md:173`）。

---

## 下一步

环境还没就绪？下一章《第 1 章 准备环境》带你检查工具链、拿到代码、读懂模型 Key 的配置位，
并用 `make check` / `make doctor` 完成第一次"体检"——见 `01-environment.md`。
