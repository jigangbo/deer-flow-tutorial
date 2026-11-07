# 《DeerFlow 从入门到精通》系统教程大纲

> 本大纲基于工作区源码与架构文档体系（`docs/ARCHITECTURE.md` → `backend/AGENTS.md` /
> `backend/docs/ARCHITECTURE.md` → `frontend/AGENTS.md`）编写，每一章的要点、动手实验
> 与参考锚点均对应真实代码路径，可直接作为后续逐章写作的施工图。

**读者画像与学习路径**

| 画像 | 建议路径 | 目标 |
| --- | --- | --- |
| 使用者 / 体验者 | 第 0–6 章 | 跑起来、会用、会配置 |
| 平台运维者 | 第 0–6 章 + 第 13、21 章 | 部署、稳定运行、多实例 |
| 后端开发者 | 第 0–5 章 + 第 7–15 章 | 读懂运行时、能改核心 |
| 扩展 / 集成作者 | 第 8、16、17 章 + 第 18 章 | 不改核心把业务装进去 |

---

## 第〇部分 导读：认识 DeerFlow（预备篇）

### 第 0 章 全景鸟瞰
- **0.1 DeerFlow 是什么**：Deep Exploration and Efficient Research Flow —— 基于 LangGraph 的
  开源"超级 Agent Harness"；lead agent 编排 sub-agents、持久记忆、沙箱执行、可扩展技能/工具，
  全部按会话线程（thread）隔离；`docs/ARCHITECTURE.md` §1。
- **0.2 从 v1 到 v2**：2.0 为彻底重写，与旧版 Deep Research 框架不共享代码（`README.md`）。
- **0.3 四服务拓扑**：Nginx `2026`（唯一公网入口）/ Gateway `8001`（FastAPI + 内嵌 LangGraph
  兼容运行时）/ Frontend `3000`（Next.js）/ Provisioner `8002`（沙箱 K8s 模式才启用）；
  `/api/langgraph/*` 重写到 Gateway 原生路由，标准 LangGraph SDK 可直连。
- **0.4 知识地图与阅读路线**：Harness/App 分层（`backend/packages/harness/` vs `backend/app/`）、
  本教程与官方文档的对应关系。
- **0.5 为什么值得学**：一套代码同时覆盖 Web、IM 渠道（飞书/Slack/Telegram/Discord/钉钉）、
  定时任务、TUI 四种交互面。

---

## 第一篇 入门篇：环境配置与一键运行

### 第 1 章 准备环境（Environment Setup）
- **1.1 系统要求**：Python 3.12+、Node 22+、pnpm 10.26.2+、uv、Make / Docker；Windows / macOS / Linux 差异。
- **1.2 获取代码**：clone 仓库 + 根目录结构导览（`backend/`、`frontend/`、`skills/`、`examples/`、`docker/`、`scripts/`、`deploy/`）。
- **1.3 模型 API Key 准备**：`config.example.yaml → models:` 段的多供应商配置，`supports_vision`、
  深度思考等模型能力位；`.env.example` 中的密钥类环境变量。
- **1.4 体检命令**：`make check`（工具链检查）与 `make doctor`（配置 + 系统要求诊断）。
- 🔧 **动手实验**：跑通 `make check` 与 `make doctor`，读懂输出并修复第一处环境问题。

### 第 2 章 一键启动（Quick Start）
- **2.1 标准三步**：`make config`（从 example 生成两份 gitignored 配置）→ `make install`
  （前后端依赖 + pre-commit 钩子）→ `make dev`（全栈热重载）。
- **2.2 打开 `http://localhost:2026`**：为什么入口是 Nginx 而不是 3000/8001；回环绑定默认值
  （`BIND_HOST`，`test_compose_default_bind_host.py` 的约束）。
- **2.3 首次对话**：创建 thread、流式回复、文件上传、artifacts 产物、todos 任务卡、
  `/goal` 完成条件。
- **2.4 看日志**：`logs/gateway.log`、`logs/frontend.log`，`tail -f` 双跟随；`make stop`。
- 🔧 **动手实验**：从零执行三步命令，完成一次"上传 Excel → 生成图表"的对话。

### 第 3 章 配置系统入门
- **3.1 两份配置各管什么**：`config.yaml`（模型、工具组、沙箱、记忆、summarization、scheduler、
  database…，见 `backend/docs/CONFIGURATION.md`）vs `extensions_config.json`（MCP 服务器 + 技能）。
- **3.2 运行时可热改**：两份配置都可通过 Gateway API 在运行时编辑；为何 `plugins:` 只留在
  `config.yaml`（会触发代码导入，必须 operator 控制）。
- **3.3 常改项 TOP 5**：`models`、`sandbox`、`summarization`、`memory`、`scheduler.enabled`。
- 🔧 **动手实验**：切换默认模型供应商并验证新会话生效；故意写坏配置观察启动报错。

### 第 4 章 前端界面与基本功能导览
- **4.1 会话页** `/workspace/chats/[thread_id]`：消息、上传、artifacts、todos、goal 卡片。
- **4.2 自定义 Agent 页** `/workspace/agents/[agent_name]`。
- **4.3 公开演示页** `/showcase/[thread_id]`（allowlist 只读）。
- **4.4 定时任务页** `/workspace/scheduled-tasks`。
- **4.5 国际化与内容**：`frontend/src/content/{en,zh}/` MDX 用户手册；zh-CN / en-US 双语。

### 第 5 章 更多运行方式
- **5.1 本地生产模式**：`make start` / `make start-daemon`，`SKIP_FRONTEND_BUILD=1` 复用上次构建。
- **5.2 Docker 开发栈**：`make docker-start / docker-stop / docker-logs`。
- **5.3 Docker 生产栈**：`make up / down`，`/health` 就绪等待；`docker/` 目录与 Compose 文件。
- **5.4 Helm 部署概览**：`deploy/helm/deer-flow/`，配置以 home 卷可写副本方式注入。
- **5.5 模式对比表**：Local Foreground / Daemon、Docker Dev / Prod 四象限（`backend/AGENTS.md`）。
- 🔧 **动手实验**：分别用 `make dev` 与 `make up` 跑通，对比进程结构与日志位置。

---

## 第二篇 进阶篇：核心组件拆解

### 第 6 章 一次请求的一生：Agent 运行时全链路
- **6.1 端到端时序**：前端 `core/threads/` → Nginx `/api/langgraph/*` → Gateway
  `RunManager + run_agent() + StreamBridge`（`packages/harness/deerflow/runtime/`）→ SSE 流回。
- **6.2 中间件链逐个拆解**（模型调用前依次执行）：
  `ThreadDataMiddleware` → `UploadsMiddleware` → `SandboxMiddleware` → `SummarizationMiddleware` →
  `TitleMiddleware` → `TodoListMiddleware` → `ViewImageMiddleware` → `ClarificationMiddleware`。
- **6.3 ThreadState 与 checkpoint**：`sandbox / artifacts / thread_data / title / todos /
  viewed_images` 扩展字段；线程数据目录 `backend/.deer-flow/threads/{thread_id}/`。
- **6.4 SSE 流协议**：`messages-tuple`、有界 `values` 快照、`task_*` 自定义事件；
  `stream_subgraphs` 的命名空间帧（`values|<ns>`，LangGraph Platform 风格）。
- 📎 参考锚点：`backend/docs/RUN_EVENT_STREAM.md`、`backend/docs/STREAMING.md`、
  `backend/docs/THREAD_LIFECYCLE.md`、`backend/docs/middleware-execution-flow.md`。
- 🔧 **动手实验**：用脚本抓一次完整 SSE 流，画出事件时序图并标注中间件生效点。

### 第 7 章 工具系统与 Skills（重点）
- **7.1 工具三来源合并**：`get_available_tools()` = 内置工具（`present_files`、
  `ask_clarification`、`view_image`、`review_skill_package`）+ 配置工具（`bash`、`read_file`、
  `write_file`、`str_replace`、`ls`、web search/fetch）+ MCP 工具。
- **7.2 Skill 解剖**：`SKILL.md` frontmatter 与资源目录；`skills/public/`（入库）、
  `skills/custom/`（gitignored）、全局集成技能包 `.deer-flow/integrations/skills/{provider}/`。
- **7.3 官方技能导览**（23 个）：`deep-research`、`ppt-generation`、`podcast-generation`、
  `data-analysis`、`chart-visualization`、`academic-paper-review`、`systematic-literature-review`、
  `image-generation`、`video-generation`、`skill-creator`、`skill-reviewer` 等，按场景分类。
- **7.4 Skill 引擎内部**（`backend/packages/harness/deerflow/skills/`）：`parser.py` / `frontmatter.py`
  解析、懒加载发现、`permissions.py` 权限、`security_scanner.py` 静态安全扫描、`slash.py` 斜杠命令、
  `installer.py` 安装器、`review/` 评审管线。
- **7.5 质量评审体系**：`skill-reviewer` 技能 + harness 工具 `review_skill_package` +
  `contracts/skill_review/` 契约；CI 豁免文件 `.github/skill-review-waivers.v1.json`
  （blocker 永不可豁免）；`tests/skills/` 技能脚本回归。
- **7.6 动手写技能**：在 `skills/custom/` 新建一个技能的完整流程（frontmatter → 脚本 → 测试 → 启用）。
- 🔧 **动手实验**：编写一个"周报生成"自定义技能，用 skill-reviewer 自审并修复 blocker。

### 第 8 章 沙箱与代码执行（重点）
- **8.1 抽象与两个实现**：`SandboxProvider` 抽象；`LocalSandboxProvider`（开发直执行）vs
  `AioSandboxProvider`（Docker 生产隔离）；"生产必须容器沙箱"的安全理由（`docs/ARCHITECTURE.md` §6）。
- **8.2 虚拟路径映射**：`/mnt/user-data/...` 与真实线程目录的映射；`sandbox.thread_data_mounts`。
- **8.3 沙箱模块解剖**（`backend/packages/harness/deerflow/sandbox/`）：`sandbox_provider.py`、
  `lease.py`（租约）、`command_scope.py`（命令范围）、`env_policy.py`（环境变量策略）、
  `security.py`、`prewarm.py`（预热）、`artifact_snapshot.py`、`file_operation_lock.py`、
  `read_file_contract.py`、`middleware.py`。
- **8.4 Provisioner / K8s 模式**：8002 端口 Provisioner 的职责与 PVC 挂载（`user-data` 卷）。
- **8.5 配置详解**：`config.yaml → sandbox:` 段；上传/产物在沙箱内外的同步行为。
- 📎 参考锚点：`backend/docs/SANDBOX_MEMORY_PROFILING.md`、`backend/docs/PATH_EXAMPLES.md`。
- 🔧 **动手实验**：分别在 local 与 docker 沙箱下让 agent 跑 Python 分析脚本，观察路径映射与文件落盘位置。

### 第 9 章 Multi-Agent 路由与子代理委派（重点）
- **9.1 Lead Agent 组装**：`deerflow.agents.make_lead_agent()`（LangGraph Server 图工厂入口）。
- **9.2 子代理执行器**：`SubagentExecutor` 后台委派；服务端 `execution_id` ↔ provider
  `tool_call_id` 的关联链 → `ToolMessage` 回写 / SSE 事件 / 生命周期 / 持久化；
  checkpoint 命名空间继承。
- **9.3 subagents 模块深读**（`backend/packages/harness/deerflow/subagents/`）：`registry.py`、
  `capacity.py`（并发容量）、`turn_budget.py`（轮次预算）、`batch_*`（批处理运行时与租约）、
  `acceptance_checks.py` / `batch_acceptance.py`（验收）、`report_contract.py` / `status_contract.py`
  （`contracts/` 中的跨端契约）。
- **9.4 子代理路由与定义**：内置 subagents（`builtins/`）；如何在配置中定义与路由子代理；
  子代理 token 归集（`token_collector.py`）。
- **9.5 前端呈现**：`task_*` SSE 事件 → 子代理卡片；根命名空间订阅（前端不开 subgraph 流）。
- 📎 参考锚点：`contracts/` 子代理状态契约、`backend/packages/harness/deerflow/subagents/AGENTS.md`。
- 🔧 **动手实验**：配置"研究员 + 评审员"双子代理流水线，观察委派、验收与结果回写全链路。

### 第 10 章 记忆系统（Memory / DeerMem）
- **10.1 记忆模型**：事实抽取与写入时机；容量选择策略 `select_facts_for_capacity()`。
- **10.2 认知风格**：`backend/docs/MEMORY_COGNITIVE_STYLE.md`；记忆设置页与
  `memory-settings-sample.json`。
- **10.3 locale 与记忆**：`context.locale`（en-US/zh-CN）只影响回复与记忆写入语言，
  不落入 checkpoint。
- **10.4 配置**：`config.yaml → memory:` 段。
- 🔧 **动手实验**：跨会话让 agent 记住并复用用户偏好；用 `scripts/benchmark/deermem_eviction`
  观察淘汰策略差异。

### 第 11 章 上下文工程与长对话治理
- **11.1 自动摘要**：`SummarizationMiddleware` 按 tokens / 消息数 / 输入比例触发；
  保留近期消息、压缩历史。
- **11.2 手动压缩**：`POST /api/threads/{id}/compact`，复用同一中间件，写新 checkpoint。
- **11.3 防护体系**：`loop_detection`（循环检测）、`guardrails/`（`GUARDRAILS.md`）、
  `pii_redaction`（PII 脱敏）、`read_before_write`、`harness_guard`、`safety_finish_reason`。
- **11.4 Plan Mode**：`config.configurable.is_plan_mode` 启用 `write_todos` 多步任务跟踪
  （`backend/docs/plan_mode_usage.md`）。
- 🔧 **动手实验**：构造超长对话触发自动摘要，对比摘要前后 checkpoint 的 `messages`/`summary_text`。

### 第 12 章 定时任务与 IM 渠道
- **12.1 定时任务 MVP**：`scheduler.enabled` 总闸 + `scheduler.tool_enabled` 能力准入；
  `/workspace/scheduled-tasks` 页面；交互轮创建计划、计划轮只能停自己的计划。
- **12.2 非交互约束**：计划轮排除 `ask_clarification`；`non_interactive` /
  `disable_clarification` / `github_token` 只对内部认证调用方生效（run-context 信任边界）。
- **12.3 队列与租约**：`queued/launching/running` 生命周期、`uq_scheduled_task_run_active`
  唯一约束、`max_concurrent_runs`、`scheduler.queue_timeout_seconds`；重启后队列存活。
- **12.4 多实例调度**：`scheduler.multi_instance=true` 需要 Postgres + 心跳 + DB 事件后端。
- **12.5 IM 渠道**：`app/channels/`（飞书 / Slack / Telegram / Discord / 钉钉）；
  飞书选项澄清按钮卡片（`card_interaction_enabled`）；凭证暂存目录清理。
- 🔧 **动手实验**：创建一个每天 9 点运行的自动化任务，并从飞书/Slack 触发一次对话。

### 第 13 章 Gateway API 与编程接入
- **13.1 REST 路由全景**（`backend/docs/API.md`）：threads、runs、uploads、scheduled-tasks、
  mcp、knowledge…
- **13.2 LangGraph 兼容层**：标准 LangGraph SDK 无需单独 server 直连 DeerFlow。
- **13.3 文件上传协议**：`POST /api/threads/{thread_id}/uploads`；`.upload-*.part` 原子发布、
  markitdown 文档转换、重复文件 `_N` 后缀（`backend/docs/FILE_UPLOAD.md`）。
- **13.4 浏览器 WebSocket**：`/api/threads/{thread_id}/browser/stream`（Nginx 正则顺序约束）。
- **13.5 内嵌客户端**：`deerflow.client.DeerFlowClient` 程序化驱动同一 run 生命周期。
- 🔧 **动手实验**：写 Python 脚本用 `DeerFlowClient` 完成一次带上传与产物回收的 run。

---

## 第三篇 精通篇：二次开发与 MCP 集成

### 第 14 章 架构分层与开发规范（二次开发前必读）
- **14.1 Harness / App 单向依赖**：`deerflow.*`（可发布框架）⬅ `app.*`（Gateway + IM 渠道）；
  CI 由 `backend/tests/test_harness_boundary.py` 强制，`deerflow` 永不 `import app`。
- **14.2 第三层契约包**：`deerflow-extension-api`（`backend/packages/extension-api/`）——
  与宿主无关的扩展契约。
- **14.3 工程规范**：ruff（行宽 240）、TDD 强制（`backend/tests/`，四分片 `make test` +
  `make test-blocking-io` Blockbuster 门禁）、`make migrate-rev`（Alembic 迁移）。
- **14.4 轻量导入纪律**：`deerflow.agents` / `deerflow.subagents` 包根的懒加载设计及原因。
- 🔧 **动手实验**：在 harness 中定位一处中间件并跑通 `make test` 全绿。

### 第 15 章 MCP 集成（重点）
- **15.1 配置 MCP 服务器**：`extensions_config.json → mcpServers`；`stdio`（command/args/env）
  与 `http`（url/headers）两种类型；`$GITHUB_TOKEN` 风格运行时环境变量解析；
  `tool_name_prefix`、`session_init_timeout`、`tool_call_timeout`。
- **15.2 进程隔离与开关**：每个 MCP server 独立进程、独立启停；工具与内置/配置工具合并注入。
- **15.3 运行时热编辑与并发安全**：Gateway 写 `extensions_config.json` 的双锁
  （`extensions_config_write_lock` + 文件锁）与原子写（临时文件替换）；Compose 中该文件
  可写而 `config.yaml` 只读。
- **15.4 长任务运行时**：`McpTaskService`（租约行、DB 为真相源）把远端任务 ID/轮询挡在
  Agent 循环之外；通知重试、死信、取消端点的 worker-stopped 503（`backend/packages/harness/deerflow/mcp/AGENTS.md`）。
- **15.5 拦截器**：`mcpInterceptors`（如自定义鉴权 `my_package.mcp.auth:build_auth_interceptor`）。
- **15.6 实战**：接入 GitHub MCP server；用官方 SDK 自建一个查询内部业务系统的 stdio MCP
  server 并在对话中调用。
- 🔧 **动手实验**：完整走通"自建 MCP server → 配置注入 → 工具调用 → 长任务取消"闭环。

### 第 16 章 扩展（Extensions）开发
- **16.1 扩展优先哲学**：新功能优先做成扩展而非改核心；扩展可贡献 middleware、lifecycle
  observers、Gateway services、FastAPI routers、实验性 full-stack plugins
  （`backend/packages/harness/deerflow/extensions/AGENTS.md`）。
- **16.2 生命周期管理**：`make extension-install/upgrade/list/enable/disable/remove`（或
  `deerflow extensions` CLI）；每次变更后重启 Gateway。
- **16.3 官方示例走读**：`examples/deerflow-extension-example`（最小骨架）、
  `deerflow-extension-bookmarks`、`deerflow-extension-agent-teams`、
  `deerflow-extension-knowledge-{management,platform}`（含 scoped AGENTS.md 与 CONTRACT.md）、
  `deerflow-extension-workflows`（AgentRuns 公共语义：POSIX、审批、会话授权恢复）。
- **16.4 两条配置通道**：`config.yaml → plugins:`（代码导入，operator 专属）vs
  `extensions_config.json`（API 可写：middlewares / mcpInterceptors / mcpServers / skills）。
- **16.5 安全提醒**：扩展代码以 Gateway 权限运行，只用可信来源。
- 🔧 **动手实验**：开发一个"团队周报收集"扩展（router + service + middleware 各一），
  安装、启用、验证贡献点，再卸载。

### 第 17 章 业务二次开发实战（综合案例）
- **17.1 需求分流决策树**：什么进 Skill（提示词+脚本的领域流程）、什么走 MCP（外部系统
  工具化）、什么做扩展（平台能力）、什么改核心（仅限 agent loop/记忆/压缩/认证等bug 修复）。
- **17.2 实战 A：企业知识库问答** —— `config.yaml → knowledge_base` + 只读知识契约
  （`backend/docs/KNOWLEDGE.md`）+ `deerflow-extension-knowledge-*` 检索扩展；空间策略与
  上游授权边界。
- **17.3 实战 B：数据分析平台** —— sandbox（Docker 隔离）+ `data-analysis` /
  `chart-visualization` 技能 + artifacts 产物流 + 前端展示。
- **17.4 实战 C：深度研报自动化** —— `deep-research` 技能 + 子代理批处理（`subagent_batches`）
  + `verification` + 定时任务调度 + 飞书推送。
- **17.5 实战 D：IM 智能客服** —— `app/channels` 接入、owner 归属与文件存储、
  `card_interaction_enabled` 交互卡片、记忆个性化。
- **17.6 实战 E：自定义模型供应商** —— `create_chat_model()` 接入私有模型网关，
  vision / 深度思考能力位配置。
- 🔧 **动手实验**：完成实战 B 并沉淀为可复制的业务模板（配置 + 技能 + 扩展三件套）。

### 第 18 章 前端二次开发
- **18.1 技术栈与结构**：Next.js 16 / React 19 / Tailwind v4 / TanStack Query；
  `app/`（路由）+ `core/`（业务域：threads、api、agents、artifacts、skills、mcp、memory、
  integrations、i18n）+ `components/`。
- **18.2 流式数据流**：`core/threads/` 订阅 LangGraph run 流 → SSE 归一化 → TanStack Query
  状态 → 组件渲染；子任务进度走根命名空间 `task_*` 事件。
- **18.3 注册表红线**：`ui/` 与 `ai-elements/` 为 Shadcn / Vercel AI SDK 注册表生成物，禁止手改。
- **18.4 新增页面实操**：参照 `/workspace/scheduled-tasks` 增加一个 workspace 页面。
- **18.5 工程工作流**：`pnpm dev`（Webpack 默认 / `DEER_FLOW_DEV_BUNDLER=turbo`）、
  `pnpm check`（lint + 类型）、`pnpm rstest run`。
- 🔧 **动手实验**：为 artifacts 新增一种自定义预览卡片（含测试）。

### 第 19 章 可观测性、测试与质量保障
- **19.1 日志与追踪**：`logging` 配置、`tracing/` 与 `trace_context.py`。
- **19.2 成本控制**：`token_usage` / `token_budget`；子代理 token 归集。
- **19.3 测试体系**：`make test` 四分片、`make test-blocking-io`（Blockbuster 严格门禁）、
  `make test-live`（真实 API，`DEER_FLOW_RUN_LIVE_TESTS=1`）、`make test-shard`。
- **19.4 基准测试**：`scripts/benchmark/`（`deermem_eviction`、`concurrency` SQLite vs
  Postgres、`context_snapshot`）；数据集不可变 pin + SHA-256 纪律。
- **19.5 技能测试纪律**：YAML/body 保真、UTF-8 显式编码（读 `utf-8-sig`、写 `utf-8`）、
  离线子进程 CLI 校验。
- 🔧 **动手实验**：修复一个带 bug 的小问题（TDD：先写失败测试再修复），并跑全量门禁。

### 第 20 章 生产部署与运维
- **20.1 持久化选型**：SQLite（单机）vs Postgres（多实例必须，见 concurrency benchmark）；
  Alembic 迁移与 `migrate-rev`；`database` / `run_events` / `agent_storage` 配置段。
- **20.2 多实例部署**：`deployment.multi_instance` 启动门禁；scheduler 租约恢复、
  `max_concurrent_runs` 全局共享预算（Postgres advisory lock）。
- **20.3 Helm 生产部署**：Chart 版本锁步（`backend/pyproject.toml`、
  `backend/packages/harness/pyproject.toml`、`frontend/package.json`、Chart.yaml 四处一致；
  `scripts/bump_version.sh` / `verify_versions.sh`，`v*` tag CI 阻断漂移）。
- **20.4 安全清单**：回环默认绑定与 `BIND_HOST`、认证/SSO（`AUTH_DESIGN.md` / `SSO.md`）、
  run-context 信任边界（内部调用方才认 `non_interactive` 等）、MCP 进程隔离、沙箱隔离。
- **20.5 故障排查**：`make doctor`、`make support-bundle`（脱敏诊断包 + AI issue 草稿）、
  `make docker-logs`；Windows 下 `scripts/pnpm.py` 的 pnpm/corepack 顺序回退。
- 🔧 **动手实验**：完成一次 Postgres + 多实例 + Helm 的完整演练，并生成 support bundle。

---

## 附录

- **附录 A 命令速查**：根 Makefile 全表（dev/start/stop/up/down/docker-*/extension-*/doctor/
  support-bundle…）+ backend / frontend 模块命令。
- **附录 B 配置项速查**：`config.yaml` 关键段位一览（models、tools、sandbox、subagent_runtime、
  subagent_batches、verification、skills、summarization、memory、database、run_events、scheduler…）
  与 `extensions_config.json` 四键（middlewares / mcpInterceptors / mcpServers / skills）。
- **附录 C 术语表**：thread、run、checkpoint、harness、lead agent、subagent、sandbox、skill、
  extension、MCP、artifact、lease…
- **附录 D 学习验收清单**：每篇末尾的自测题与"你应该能…"检查点。
- **附录 E 常见问题 FAQ**：端口冲突、模型 Key 报错、沙箱启动失败、pnpm 版本、
  配置不生效（忘记重启 Gateway）、Windows 特有问题。
- **附录 F 官方文档索引**：`docs/` 与 `backend/docs/` 全量文档 → 教程章节映射表。

---

## 写作约定（供后续逐章撰写时遵循）

1. 每章遵循固定骨架：**学习目标 → 概念讲解 → 源码走读 → 动手实验 → 常见坑**。
2. 所有代码引用使用可点击的 `路径:行号` 形式，指向当前仓库实际文件。
3. 实验必须可离线复现；涉及外部 API 时提供 mock/替代方案。
4. 与官方 `AGENTS.md` / `docs/` 冲突时以官方文档为准，教程只做引导不做复写。
5. 入门篇重"跑通与直觉"，进阶篇重"机制与源码"，精通篇重"决策与实战"。
