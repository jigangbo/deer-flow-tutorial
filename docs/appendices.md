# 附录

> 本附录汇总全书散落的命令、配置、术语与排查经验。所有引用均指向当前仓库真实文件，
> 行号以源文件实际内容为准。

---

## 附录 A 命令速查

### A.1 根目录 Makefile（仓库根执行）

来源：`Makefile:26-69`（help 全表）。完整 target 定义见 `Makefile:71-246`。

| 命令 | 作用 | 锚点 |
| --- | --- | --- |
| `make setup` | 交互式安装向导（新用户推荐） | `Makefile:72-73` |
| `make doctor` | 配置 + 系统要求健康检查 | `Makefile:75-76` |
| `make support-bundle` | 生成脱敏 issue 摘要、AI 草稿与证据包（含 `--include-doctor`） | `Makefile:78-79` |
| `make config` | 从 example 生成两份 gitignored 配置（已存在则中止） | `Makefile:87-88` |
| `make config-upgrade` | 把 example 的新字段合并进现有 config.yaml | `Makefile:90-91` |
| `make check` | 检查必备工具链 | `Makefile:97-98` |
| `make check-agent-guidance` | 校验 scoped AGENTS.md 与链路预算 | `Makefile:100-101` |
| `make detect-thread-boundaries` | 盘点后端 executor/线程/事件循环边界 | `Makefile:81-82` |
| `make detect-blocking-io` | 静态盘点可能阻塞事件循环的 IO | `Makefile:84-85` |
| `make install` | 安装前后端依赖 + pre-commit 钩子 | `Makefile:104-112` |
| `make extension-install SOURCE=...` | 安装并启用受信 Python 扩展 | `Makefile:122-125` |
| `make extension-upgrade SOURCE=...` | 替换扩展并保留其配置 | `Makefile:127-130` |
| `make extension-list` | 列出已配置扩展 | `Makefile:132-133` |
| `make extension-enable NAME=...` / `disable` / `remove` | 启用 / 停用 / 卸载（均需重启 Gateway） | `Makefile:135-148` |
| `make setup-sandbox` | 预拉取沙箱容器镜像 | `Makefile:151-152` |
| `make dev` / `make dev-daemon` | 全栈开发模式（热重载）/ 后台守护 | `Makefile:155-169` |
| `make start` / `make start-daemon` | 本地生产模式（`SKIP_FRONTEND_BUILD=1` 复用上次构建）/ 守护 | `Makefile:162-174` |
| `make nginx` | 仅前台启动 nginx（本地配置） | `Makefile:177-178` |
| `make stop` | 停止本地全部服务 | `Makefile:181-182` |
| `make dev-multi` / `dev-multi-check` / `dev-multi-down` | 双 Gateway 多实例演练：启动 / 跨实例检查 / 拆除 | `Makefile:185-192` |
| `make clean` | 停服务并**删除** `backend/.deer-flow` 运行时数据与日志 | `Makefile:196-202` |
| `make docker-init` / `docker-start` / `docker-stop` | Docker 开发栈初始化 / 启动 / 停止 | `Makefile:209-218` |
| `make docker-logs`（`-frontend` / `-gateway` / `-redis`） | Docker 开发栈日志（可按服务） | `Makefile:221-230` |
| `make up` / `down` / `prod-logs` | 生产 Docker 栈构建启动（localhost:2026）/ 停止移除 / 跟日志 | `Makefile:237-246` |

### A.2 后端（`cd backend` 后执行）

来源：`backend/Makefile`。

| 命令 | 作用 | 锚点 |
| --- | --- | --- |
| `make install` | `uv sync --locked` 安装依赖 | `backend/Makefile:5-6` |
| `make dev` | Gateway 热重载（8001；预建并排除 `.deer-flow` 与 `sandbox` 的 reload 监听） | `backend/Makefile:8-17` |
| `make gateway` | Gateway 不带 reload | `backend/Makefile:19-20` |
| `make test` | 四个耗时均衡分片并行（`TEST_JOBS=1` 串行） | `backend/Makefile:22-27` |
| `make test-live` | live 测试（真实 API，`DEER_FLOW_RUN_LIVE_TESTS=1`） | `backend/Makefile:32-33` |
| `make test-blocking-io` | Blockbuster 严格门禁（`tests/blocking_io/`） | `backend/Makefile:35-36` |
| `make test-shard SPLITS=4 GROUP=2` | 跑第 2/4 分片（`least_duration` 算法，读 `.test_durations`） | `backend/Makefile:49-52` |
| `make test-shard-durations` | 重建耗时基线并提交 | `backend/Makefile:57-58` |
| `make lint` / `make format` | `ruff check` + `ruff format --check` / 修复并格式化 | `backend/Makefile:60-65` |
| `make detect-blocking-io` | 静态扫描输出 JSON 清单 | `backend/Makefile:67-68` |
| `make migrate-rev MSG="..."` | 自动生成 Alembic 迁移（升级在 Gateway 启动时自动跑） | `backend/Makefile:77-79` |
| `python -m pytest tests/test_x.py::test_y -q` | 跑单个测试文件/函数 | 根 AGENTS.md |
| `PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction validate-contracts` | 记忆淘汰基准离线校验 | `backend/AGENTS.md:71-78` |
| `uv run python scripts/benchmark/concurrency/run_concurrency_bench.py --backend sqlite --workers 2,4,8,16 --ops-per-worker 50 --read-ratio 0.7` | SQLite/Postgres 并发争用基准 | `backend/AGENTS.md:94-97` |

### A.3 前端（`cd frontend` 后执行；host 调用经 `../scripts/pnpm.py`）

来源：`frontend/package.json:6-23`。

| 命令 | 作用 |
| --- | --- |
| `pnpm dev` | 开发服务器（Webpack 默认；`DEER_FLOW_DEV_BUNDLER=turbo` 切 Turbopack） |
| `pnpm build` / `pnpm start` | 生产构建（含文档搜索索引）/ 生产服务器 |
| `pnpm check` | ESLint + `tsc --noEmit`（提交前必跑） |
| `pnpm lint` / `pnpm lint:fix` | 单独 lint / 自动修复 |
| `pnpm typecheck` | 仅 `tsc --noEmit` |
| `pnpm format` / `pnpm format:write` | Prettier 检查 / 写入 |
| `pnpm test` | Rstest 单元测试（node + happy-dom 双 project） |
| `pnpm rstest run <pattern>` | 跑匹配的单测 |
| `pnpm test:e2e` | Playwright Chromium E2E |
| `pnpm perf:check` | 路由资源体积对照性能预算 |
| `pnpm catalog:sync` | 变更能力目录后刷新静态 demo 快照 |
| `pnpm search:index` | 重建文档搜索索引（`pnpm build` 末尾自动跑） |

---

## 附录 B 配置项速查

### B.1 `config.yaml` 顶层键（`grep "^[a-z_]*:" config.example.yaml` 实测行号）

| 段 | 行号 | 管什么 |
| --- | --- | --- |
| `config_version` | 23 | 配置 schema 版本（升级合并用） |
| `log_level` / `logging` | 46 / 52 | 日志级别；`enhance.enabled` 日志带 trace_id（重启生效） |
| `token_usage` / `token_budget` | 96 / 106 | 计量显示 / 每 run 硬预算（warn 0.8、hard_stop 1.0） |
| `recursion_limit` / `max_recursion_limit` | 120 / 125 | 每 run 超步上限（100）/ 服务端硬顶（1000） |
| `models` | 157 | 模型供应商与能力位（vision / 深度思考 / context_window） |
| `knowledge_base` | 825 | 知识库（只读检索契约） |
| `tool_groups` / `tools` / `tool_search` / `tool_output` / `tool_artifacts` | 836 / 849 / 1396 / 1422 / 1462 | 工具组、工具行为、搜索、输出、产物 |
| `suggestions` / `input_polish` | 1480 / 1490 | 建议与输入润色 |
| `loop_detection` / `pii_redaction` / `read_before_write` / `harness_guard` / `safety_finish_reason` | 1505 / 1538 / 1586 / 1604 / 1680 | 防护体系（第 11 章） |
| `projects` / `uploads` / `sandbox` | 1625 / 1705 / 1732 | 项目、上传、沙箱（第 8 章） |
| `subagent_runtime` / `subagent_batches` | 2011 / 2102 | 子代理运行时与批处理（第 9 章） |
| `verification` | 2122 | 结果校验 |
| `skills` / `skill_scan` | 2173 / 2205 | 技能与扫描（第 7 章） |
| `title` / `task_continuity` | 2223 / 2236 | 自动标题 / 任务连续性 |
| `summarization` | 2242 | 上下文摘要触发与保留（第 11 章） |
| `memory` | 2353 | DeerMem 记忆（第 10 章） |
| `blob_storage` / `agents_api` / `skill_evolution` | 2586 / 2603 / 2610 | 对象存储 / Agents API / 技能演化 |
| `database` / `run_events` / `agent_storage` | 2733 / 2805 / 2844 | 三大持久化段（第 20 章） |
| `scheduler` | 2895 | 定时任务（enabled / tool_enabled / multi_instance / 预算） |
| `mcp_tasks` | 2925 | 长任务 MCP 运行时（第 15 章） |
| `deployment` / `run_ownership` | 2956 / 2981 | 多实例声明 / run 租约心跳 |
| `stream_bridge`（注释示例） | 2999-3015 | `memory | redis` 事件桥（多 worker 必须 redis） |
| `authorization` | 3478 | 授权 |
| `plugins`（operator 专属） | —— | 第三方扩展导入列表，只允许 operator 手改，永不进 API 可写文件 |

重启策略速记：`scheduler` 的 poller 字段、`run_ownership`、`agent_storage`、`logging.enhance`、`stream_bridge`、`checkpoint_channel_mode` 为 restart-required；`scheduler.recursion_limit` 在分发时读取（下次 run 生效，无需重启，`backend/AGENTS.md:14`）。

### B.2 `extensions_config.example.json` 四键

文件路径：`extensions_config.example.json`。四键语义见大纲附录 B 与第 15/16 章。

| 键 | 示例内容 | 说明 |
| --- | --- | --- |
| `middlewares` | `[]` | API 可写的 AgentMiddleware 类列表 |
| `mcpInterceptors` | `["my_package.mcp.auth:build_auth_interceptor"]` | `模块路径:工厂函数` 形式的拦截器 |
| `mcpServers` | `github`（stdio，`command/args/env`，`$GITHUB_TOKEN` 运行时解析）、`parallel-search`（http，`url/headers`）、`postgres`（含 `routing` 关键词路由）、`long-running-reports`（含 `task_toolsets` 长任务契约） | 每服务器独立启停；公共字段 `enabled`、`tool_name_prefix`、`session_init_timeout`、`tool_call_timeout` |
| `skills` | `{}` | API 可写的技能配置 |

两个文件的通道差异（第 16 章）：`config.yaml → plugins:` 触发代码导入、必须 operator 控制；`extensions_config.json` 由 Gateway API 运行时热写（双锁 + 原子替换），Compose 中前者只读、后者可写。

---

## 附录 C 术语表

| 术语 | 释义 | 详见 |
| --- | --- | --- |
| **thread** | 会话线程：一次对话的容器，拥有隔离的数据目录 `backend/.deer-flow/threads/{thread_id}/` | 第 2、6 章 |
| **run** | 对 thread 的一次执行（agent loop 调用）；run 历史的状态过滤是"发生态"不是任务态 | 第 6、12 章 |
| **checkpoint** | LangGraph 在每个超步后持久化的图状态快照；承载 `sandbox/artifacts/todos/goal` 等扩展字段 | 第 6 章 |
| **harness** | 可发布的 agent 框架包 `deerflow-harness`（import 前缀 `deerflow.*`），App 永不反向依赖 | 第 14 章 |
| **App（Gateway）** | 未发布的应用层 `backend/app/`：FastAPI Gateway + IM 渠道 | 第 0、14 章 |
| **lead agent** | 由 `make_lead_agent()` 组装的主 agent，LangGraph Server 图工厂入口 | 第 6、9 章 |
| **subagent** | 由 `SubagentExecutor` 后台委派的子代理；`execution_id` ↔ `tool_call_id` 关联链贯穿 ToolMessage/SSE/持久化 | 第 9 章 |
| **sandbox** | 沙箱执行抽象：`LocalSandboxProvider`（开发）与 `AioSandboxProvider`（Docker 生产隔离） | 第 8 章 |
| **skill** | `SKILL.md` frontmatter + 资源目录的领域技能；public/custom/集成三来源 | 第 7 章 |
| **extension** | 通过贡献点（middleware/observer/service/router）装进平台的打包扩展 | 第 16 章 |
| **MCP** | Model Context Protocol：外部工具接入协议，每 server 独立进程 | 第 15 章 |
| **artifact** | agent 产出的文件/代码产物，经 `present_files` 呈现、前端面板预览 | 第 2、7、18 章 |
| **lease** | 租约：带心跳续期的认领凭据，覆盖 run 所有权、调度认领、渠道 leader、MCP 任务 | 第 12、20 章 |
| **SSE** | Server-Sent Events：run 流的传输形态（`messages-tuple` + 有界 `values` + 自定义事件） | 第 6 章 |
| **stream bridge** | Gateway worker 与 SSE 客户端之间的事件桥（`memory` 单进程 / `redis` 多进程） | 第 20 章 |
| **middleware** | 模型调用前依次执行的中间件链（ThreadData → Uploads → Sandbox → Summarization → …） | 第 6 章 |
| **provisioner** | 8002 端口的可选服务，K8s 沙箱模式下供给容器与 PVC | 第 8、20 章 |
| **DEER_FLOW_HOME** | 运行时主目录（默认 `backend/.deer-flow/`），存线程数据、数据库、secrets | 第 6 章 |
| **Blockbuster** | 检测异步上下文中阻塞 IO 的运行时工具；`tests/blocking_io/` 的严格门禁 | 第 19 章 |
| **Alembic** | 后端 schema 迁移工具；Gateway 启动自动 `upgrade head` | 第 20 章 |
| **run-context 信任边界** | `non_interactive` 等服务端键只认内部认证调用方，客户端副本一律剥离 | 第 12、20 章 |
| **trace id** | 请求级关联 ID（`X-Trace-Id`），ContextVar 为唯一来源，派生载体只写不读 | 第 19 章 |
| **TanStack Query** | 前端服务端状态管理器；线程状态归一化后的归属地 | 第 18 章 |
| **registry 生成物** | `ui/` 与 `ai-elements/`：Shadcn / MagicUI / React Bits / Vercel AI SDK 注册表拉取的组件，禁止手改 | 第 18 章 |

---

## 附录 D 学习验收清单

### D.1 入门篇（第 0–5 章）——你应该能

1. 不看文档说出四个服务的端口与角色，并解释为什么浏览器入口是 2026 而不是 3000/8001。
2. 从 `make config` 到 `make dev` 完成首次启动，并指出两份运行时配置文件的路径与 gitignored 属性。
3. 在 `logs/gateway.log` 与 `logs/frontend.log` 中定位一次报错。
4. 切换默认模型供应商并验证新会话生效；写坏配置后能读懂启动报错并恢复。
5. 分别用 `make dev` 与 `make up` 跑通，对比进程结构与日志获取方式。
6. 说出 `BIND_HOST` 的默认值与 `test_compose_default_bind_host.py` 钉住的约定。

### D.2 进阶篇（第 6–13 章）——你应该能

1. 画出一次请求的端到端时序（前端 → Nginx → RunManager/run_agent/StreamBridge → SSE 回流），并标注八个中间件的生效点。
2. 说清工具三来源的合并逻辑，并解释 `stream_subgraphs` 的 `values|<ns>` 帧与根命名空间 `task_*` 事件的区别。
3. 在 local 与 docker 两种沙箱下追踪同一个 Python 脚本的虚拟路径映射与落盘位置。
4. 配置"研究员 + 评审员"双子代理流水线，观察委派、验收与回写全链路。
5. 构造长对话触发自动摘要，对比前后 checkpoint 的 `messages`/`summary_text`。
6. 创建一个定时任务并解释 `queued → launching → running` 生命周期与 `uq_scheduled_task_run_active` 约束。
7. 用 `DeerFlowClient` 写脚本完成一次带上传与产物回收的 run。
8. 接入一个 GitHub MCP server 并解释 `$GITHUB_TOKEN` 的运行时解析与工具名前缀。

### D.3 精通篇（第 14–20 章）——你应该能

1. 说出 harness/app 的依赖方向由哪个测试强制（`backend/tests/test_harness_boundary.py`），并解释为什么 `deerflow.agents` 包根要保持懒加载。
2. 自建一个 stdio MCP server 并走通"配置注入 → 工具调用 → 长任务取消"闭环。
3. 为一个新功能做出 Skill / MCP / 扩展 / 核心的分流决策，并给出理由。
4. 在前端新增一个 workspace 页面（页面组合 + core 纯函数域 + 组件族 + 双环境测试）。
5. 解释 `make test` 的分片为什么按耗时均衡、Blockbuster 门禁包住哪些阶段、live 测试如何 opt-in。
6. 配置一套 Postgres + 心跳 + DB 事件的多实例 scheduler，并说出 `max_concurrent_runs` 如何成为全局共享预算。
7. 用 `bump_version.sh` 升版本并解释 `v*` tag CI 的阻断逻辑。
8. 生成一份 support bundle，指出其中哪些字段被 `SECRET_KEY_RE` 脱敏。

---

## 附录 E 常见问题 FAQ

**Q1：端口冲突——2026/3000/8001 被占用怎么办？**
先 `make stop`（本地栈）或 `make down`（生产栈）释放。Docker 入口端口由根 `PORT` 环境变量控制（仅影响 Compose 发布端口）；本地 Next.js 固定 3000、Gateway 固定 8001，`.env` 改动不会影响 `make dev` 的端口等待（根 `AGENTS.md`）。注意 Windows 上 `0.0.0.0` 绑定可能撞 Hyper-V/winnat 保留段（见 Q6）。

**Q2：模型 API Key 报错如何排查？**
确认 `config.yaml → models:` 段对应供应商的 `api_key` 已填、供应商未 disable；跑 `make doctor`，它专门检查 LLM provider 连通性（`scripts/doctor.py:3-8`）。密钥类环境变量看 `.env.example`。模型能力位（`supports_vision`、深度思考、`context_window`）错配的症状是功能静默降级而非报错（`config.example.yaml:132-143`）。

**Q3：沙箱启动失败？**
三步：确认 Docker daemon 在跑；`make setup-sandbox` 预拉镜像（`Makefile:151-152`）；确认 `config.yaml → sandbox:` 选择的 provider 与运行形态匹配（local 直执行仅开发用，Docker 生产用 `AioSandboxProvider`，K8s 模式才需要 8002 Provisioner）。Compose 默认不挂 Docker socket，DooD 沙箱要显式加 overlay（`docker/docker-compose.yaml:161-166`）。

**Q4：pnpm 版本不对 / Corepack 不生效？**
仓库锁定 `pnpm@10.26.2`（`frontend/package.json:133`），要求 Node 22+。host 调用统一走 `scripts/pnpm.py`：native Windows 先试 `pnpm.cmd`、POSIX 先试 `pnpm`，Corepack 回退按同序尝试 `corepack.cmd`/`corepack`，并从 `frontend/` 目录运行以对齐锁定的包管理器版本（根 `AGENTS.md`）。

**Q5：改了配置不生效？**
分三类：① 经 Gateway API 改的两份配置立即生效；② 直接改 `config.yaml`，`make dev` 的 uvicorn 监听 `*.yaml` 会自动重启（`backend/Makefile:12-13`）；③ **restart-required 字段**（`scheduler` poller 字段、`run_ownership`、`agent_storage`、`logging.enhance`、`stream_bridge`、`checkpoint_channel_mode`）必须重启 Gateway，且多实例下所有 Pod 一起重启（`CONFIGURATION.md:777-781`）。`scheduler.recursion_limit` 例外：分发时读取，下次 run 生效（`backend/AGENTS.md:14`）。

**Q6：Windows 特有问题合集？**
① 前端 dev server 绑定 `127.0.0.1` 避开 Hyper-V/winnat `EACCES`（#2870，`frontend/AGENTS.md:34`）；② root Makefile 在 Windows 用 `cmd.exe` 执行并借 `scripts/run-with-git-bash.cmd` 跑 shell 脚本（`Makefile:9-13`），所以需要安装 Git Bash；③ 后端进程统一注入 `PYTHONIOENCODING=utf-8 PYTHONUTF8=1` 防控制台乱码（`backend/Makefile:33-36`）；④ POSIX-only 的 live 测试用 `os.name` 守护收集（`backend/AGENTS.md:226-227`）；⑤ 技能文本一律显式 UTF-8（读 `utf-8-sig`、写 `utf-8`），别依赖系统 locale。

**Q7：非本机访问 dev server 登录页 403？**
Next 的 `allowedDevOrigins` 会挡住未声明来源的 `/_next/*`、字体与 HMR 请求，症状是 403 且页面无法交互（含登录）。设置 `DEER_FLOW_DEV_ALLOWED_ORIGINS` 为逗号分隔主机列表；生产构建忽略此设置（`frontend/AGENTS.md:224-227`）。

**Q8：`uv lock --check` 失败 / CI 报版本漂移？**
改过 `backend/pyproject.toml` 或 harness pyproject 但没刷新 `backend/uv.lock`。补跑 `uv lock`；若是发版，直接用 `scripts/bump_version.sh <ver>`（它会顺带刷新锁并自检，`bump_version.sh:108-113`）。pre-commit 的 `uv-lock-check` 钩子本来能本地拦住，别用 `--no-verify` 绕过（`.pre-commit-config.yaml:17-22`）。

**Q9：Docker 里 `extensions_config.json` 写不进 / 更新丢失？**
生产 Compose 故意以读写挂载该文件（`config.yaml` 只读）；Gateway 写它时持双锁（进程锁 + sidecar advisory 文件锁）并临时文件原子替换。挂载点 `EBUSY` 才允许非原子原地覆盖（可能因崩溃截断）——出现这种情况要检查挂载方式（`backend/AGENTS.md:22`）。

**Q10：跑 `make test-shard` 报 `.test_durations` 缺失？**
分片基线文件不在就拒绝运行（防并发写竞争）。执行 `make test-shard-durations` 重建并提交（`backend/Makefile:50-58`）。日常全量测试直接 `make test`。

**Q11：live 测试意外调用了真实 API？**
`DEER_FLOW_RUN_LIVE_TESTS=1` 是全局开关，跑完记得取消；离线分片本身带 `-m "not live"` 排除（`backend/Makefile:52`）。同理，基准评测命令永不静默下载数据集，数据集路径由你提供（第 19 章 19.4）。

**Q12：上传 Excel/Word 后 agent 读不到内容？**
文档转换走 markitdown、每请求单转换 worker；目录会被拒绝（上传全有或全无），同请求重名文件自动加 `_N` 后缀（`backend/AGENTS.md:286`）。先看 Gateway 日志里该上传请求的转换错误，再确认文件类型在支持列表内。

**Q13：定时任务的队列里的 run 一直不动？**
查三个预算：全局 `max_concurrent_runs: 3`、每属主 `max_concurrent_runs_per_user: 2`、排队上限 `queue_timeout_seconds: 3600`（超时的发生被跳过且不发通知，`config.example.yaml:2859-2867`）。多实例下这些是跨 Pod 共享预算；单实例则是本进程预算。

---

## 附录 F 官方文档索引（docs/ 与 backend/docs/ → 教程章节映射）

### F.1 仓库根 `docs/`

| 文档 | 内容 | 对应章节 |
| --- | --- | --- |
| `docs/ARCHITECTURE.md` | 顶层架构总览（拓扑/分层/安全模型） | 第 0、6、14 章 |
| `docs/capability-center.md` | 能力中心完整契约与扩展示例 | 第 4、18 章 |
| `docs/full-stack-plugins.md` | 实验性全栈插件（前端不变量） | 第 16 章 |
| `docs/task-continuity.md` | 任务连续性 | 第 11、12 章 |
| `docs/database-forward-revision-recovery.md` | 数据库前向版本恢复 | 第 20 章 |
| `docs/RELEASE_SOP.md` | 发布 SOP | 第 20 章 |
| `docs/skill-usage-ui.md` | 技能使用 UI | 第 7、18 章 |
| `docs/skill-evolution-host.md` | 技能演化宿主 | 第 7、16 章 |
| `docs/OPENVIKING.md` | OpenViking 记忆/资源后端 | 第 10、15 章 |
| `docs/tui/` | 终端 UI 文档目录 | 第 5 章 |
| `docs/agents/`、`docs/plans/`、`docs/experiments/`、`docs/superpowers/` | 过程文档与设计笔记 | —— |
| `docs/tutorials/` | 本教程 | 全书 |

### F.2 `backend/docs/`

| 文档 | 内容 | 对应章节 |
| --- | --- | --- |
| `API.md` | REST API 参考 | 第 13 章 |
| `ARCHITECTURE.md` | 后端架构细节 | 第 6、14 章 |
| `CONFIGURATION.md` | 配置项权威手册（database/多实例/deployment topology…） | 第 3、20 章 |
| `SETUP.md` | 安装指南 | 第 1 章 |
| `FILE_UPLOAD.md` | 文件上传协议 | 第 13 章 |
| `PATH_EXAMPLES.md` | 路径类型与用法 | 第 8 章 |
| `SANDBOX_MEMORY_PROFILING.md` | 沙箱内存画像 | 第 8 章 |
| `RUN_EVENT_STREAM.md` | run 事件流协议 | 第 6 章 |
| `STREAMING.md` | 流式协议细节 | 第 6 章 |
| `THREAD_LIFECYCLE.md` | 线程生命周期 | 第 6 章 |
| `middleware-execution-flow.md` | 中间件执行流 | 第 6 章 |
| `runtime-guidance-details.md` | 运行时引导细节 | 第 6 章 |
| `AUTO_TITLE_GENERATION.md` / `TITLE_GENERATION_IMPLEMENTATION.md` | 自动标题 | 第 6 章 |
| `RUN_INTERACTION_POLICY.md` | run 交互策略 | 第 6、12 章 |
| `summarization.md` | 上下文摘要契约 | 第 11 章 |
| `plan_mode_usage.md` | Plan Mode 用法 | 第 11 章 |
| `GUARDRAILS.md` / `LOOP_DETECTION.md` | 防护栏 / 循环检测 | 第 11 章 |
| `MEMORY_COGNITIVE_STYLE.md`、`MEMORY_IMPROVEMENTS*.md`、`MEMORY_SETTINGS_REVIEW.md`、`memory-settings-sample.json` | 记忆系统专题 | 第 10 章 |
| `TASK_TOOL_IMPROVEMENTS`（`task_tool_improvements.md`）与 `BATCH_CONTINUATION.md` | 子代理任务工具与批处理续跑 | 第 9 章 |
| `MCP_SERVER.md` / `mcp-control-leases.md` | MCP 服务端 / 控制租约 | 第 15 章 |
| `KNOWLEDGE.md` | 只读知识契约 | 第 17 章 |
| `IM_CHANNEL_CONNECTIONS.md` | IM 渠道连接 | 第 12 章 |
| `TUI.md` | 终端 UI | 第 5 章 |
| `BLOCKING_IO_DETECTION.md` | 阻塞 IO 检测机制 | 第 19 章 |
| `REPLAY_E2E.md` | 回放式 E2E | 第 19 章 |
| `AUTH_DESIGN.md` / `AUTH_UPGRADE.md` / `AUTH_TEST_PLAN.md` / `AUTH_TEST_DOCKER_GAP.md` | 认证设计/升级/测试 | 第 20 章 |
| `SSO.md` | OIDC 单点登录 | 第 20 章 |
| `blob-storage.md` / `checkpoint-retention-contract.md` | 对象存储 / checkpoint 保留契约 | 第 11、20 章 |
| `extension-agent-runs.md` / `extension-model-invocation.md` | 扩展的 AgentRuns / 模型调用契约 | 第 16 章 |
| `GITHUB_AGENTS.md` | GitHub 集成代理 | 第 16 章 |
| `APPLE_CONTAINER.md` | Apple 容器适配 | 第 5 章 |
| `TODO.md` / `README.md` / 各 `rfc-*.md` | 待办与历史设计 | —— |

### F.3 其他专题文档（非 docs/ 目录）

| 文档 | 对应章节 |
| --- | --- |
| `AGENTS.md`（根）/ `backend/AGENTS.md` / `frontend/AGENTS.md` / `src/AGENTS.md` 等 scoped 指南 | 全书随时参照 |
| `backend/packages/harness/deerflow/extensions/AGENTS.md`、`.../mcp/AGENTS.md`、`.../subagents/AGENTS.md`、`.../persistence/AGENTS.md`、`.../config/AGENTS.md`、`.../skills/AGENTS.md` | 第 7、9、12、15、16 章 |
| `contracts/`（子代理状态、技能评审、语言环境、调度错误等跨端契约） | 第 9、7、18 章 |
| `RELEASING.md` / `CONTRIBUTING.md` / `Install.md` / `SECURITY.md` | 第 1、20 章 |
| `examples/deerflow-extension-*/AGENTS.md` | 第 16 章 |

---

*全书完。教程基于仓库当前源码撰写；若源码演进导致行号漂移，请以 `grep` 与各 `AGENTS.md` 的最新内容为准。*
