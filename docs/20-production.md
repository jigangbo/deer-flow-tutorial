# 第 20 章 生产部署与运维

> **本章源码锚点**
>
> | 锚点 | 作用 |
> | --- | --- |
> | `config.example.yaml:2733` / `:2805` / `:2844` | `database:` / `run_events:` / `agent_storage:` 三个持久化段 |
> | `config.example.yaml:2895` / `:2956` / `:2981` | `scheduler:` / `deployment:` / `run_ownership:` 多实例相关段 |
> | `backend/docs/CONFIGURATION.md:782` | 多 worker / 多实例的启动门禁清单 |
> | `backend/AGENTS.md:16` | `scheduler.multi_instance=true` 的租约恢复契约 |
> | `deploy/helm/deer-flow/Chart.yaml:5` | Chart 版本（锁步五处之一） |
> | `scripts/bump_version.sh:7` | 版本五源联动更新脚本 |
> | `docker/docker-compose.yaml:152` | `init: true` 与配置挂载（config 只读 / extensions 可写） |
> | `scripts/doctor.py:1` | `make doctor` 健康检查；`scripts/support_bundle.py:1` 脱敏诊断包 |

## 20.0 学习目标

读完本章，你应该能够：

1. 按部署形态正确选型三个存储段：`database`（应用数据）、`run_events`（事件持久化）、`agent_storage`（自定义 Agent 定义），并说出"多实例必须 Postgres"背后的并发证据。
2. 配置一套多实例部署：`deployment.multi_instance` 启动门禁的四项前置条件、scheduler 租约恢复、`max_concurrent_runs` 如何经 Postgres advisory lock 变成全局共享预算。
3. 用 `scripts/bump_version.sh` / `verify_versions.sh` 维护五处版本锁步，理解 `v*` tag CI 如何阻断漂移。
4. 过一遍生产安全清单：回环默认绑定、认证/SSO、run-context 信任边界、MCP 与沙箱隔离、Compose 挂载的读写面。
5. 在故障时刻熟练使用 `make doctor`、`make support-bundle`、`make docker-logs` 完成诊断闭环。

---

## 20.1 持久化选型：三个存储段各管什么

### 20.1.1 `database:`：应用数据库

`config.example.yaml:2733-2735`：

```yaml
// config.example.yaml:2733-2735
database:
  backend: sqlite
  sqlite_dir: .deer-flow/data
```

可选项 `memory | sqlite | postgres`。**单机默认 SQLite 即可**；什么时候必须换 Postgres，`backend/docs/CONFIGURATION.md:782` 给出了不可协商的清单（原文节选）：

> Multi-worker deployments (`GATEWAY_WORKERS > 1`) and declared multi-instance deployments (`deployment.multi_instance: true` / `DEER_FLOW_MULTI_INSTANCE=1` ...) must use the Postgres database backend, enable run ownership heartbeats, set `run_events.backend: db`, and use the Redis stream bridge. SQLite silently ignores row-level locks, while memory and JSONL run-event stores are process-local and cannot enforce singleton delivery receipts across workers; startup rejects these combinations.

关键句是 "SQLite silently ignores row-level locks"——SQLite 不执行行级锁，多进程并发写会在应用层"看起来成功"实则互相覆盖。这不是推测：第 19 章的 `scripts/benchmark/concurrency/` 用 N 个独立 OS 进程实测了这个场景（`backend/AGENTS.md:84-98`）。

Postgres 侧还有几处生产调优项（`config.example.yaml:2760-2790`）：`pool_recycle: 300`（在环境空闲切断前回收 ORM 连接）、`command_timeout: 30`、`checkpoint_channel_mode: full | delta`（**所有共享同一数据库的进程必须一致**，重启生效）、`checkpoint_delta.snapshot_frequency: 10`，以及可选的 Redis checkpoint 缓存（`checkpoint_cache.type: redis`，带 `DEER_FLOW_CHECKPOINT_CACHE_REDIS_URL` 环境变量回退）。若要收拢 schema，`postgres_schema:` 支持 DeerFlow 专属 schema（2720-2732 行给了完整的 `ALTER TABLE ... SET SCHEMA deerflow` 迁移剧本，注意 alembic_version 表必须一起搬）。

### 20.1.2 `run_events:`：run 事件存哪

`config.example.yaml:2805-2817`：

```yaml
// config.example.yaml:2805-2817
run_events:
  backend: memory
  max_trace_content: 10240
  track_token_usage: true
  # With a fencing-capable SQL RunStore and DB event store:
  # off: host-authorized writes still check Run incarnation, epoch and state;
  #      stale Journal flushes after takeover or deletion may be rejected.
  # strict: additionally checks raw SQL and unaware legacy writers via the
  #         database trigger after an offline cutover.
  # Restart-required; strict requires database.backend: postgres and backend: db.
  producer_fencing: "off"
  # producer_cutover_id: deployment-2026-10-27
```

三档 backend：`memory`（默认，重启即失）、`db`（走 ORM 全查询能力，**生产推荐**）、`jsonl`（追加写文件，轻量单机持久化）。`track_token_usage: true` 把 token 计数累积进 `RunRow`——这正是工作台用量页（第 19 章 19.2）的数据源之一。`producer_fencing` 从 `off` 到 `strict` 是一次**离线切换**流程：停全部 Gateway → 激活数据库策略 → 带着切换 ID 重启（`strict` 还要求 Postgres）。Webhook 入站去重（`dedupe_storage`，`config.example.yaml:2737-2758`）同理：多副本必须 Postgres，`auto` 会按 `database.backend` 自动落位。

### 20.1.3 `agent_storage:`：自定义 Agent 定义存哪

`config.example.yaml:2844-2845`：

```yaml
// config.example.yaml:2844-2845
agent_storage:
  backend: file
```

`file`（默认）把自定义 Agent 的 config 与 SOUL.md 存每用户文件、托管子代理定义存 `{base_dir}/managed-subagents/` 下——**节点本地**，没有共享挂载就看不见彼此。`db` 则走共享 SQL 层（要求 `database.backend` 是 sqlite/postgres，memory 拒启）。从 file 切到 db 有官方迁移脚本（`config.example.yaml:2835-2840`）：

```bash
uv run --no-sync --project backend python backend/scripts/migrate_agents_to_db.py --dry-run
```

先 `--dry-run` 看预览，源文件保留原地，回滚即改回 `file`。

### 20.1.4 Alembic 迁移：只有一个入口

`backend/Makefile:71-79`：

```makefile
// backend/Makefile:71-79（注释节选）
# Generate a new alembic revision by autogenerating the diff against the live
# ORM models. Usage: make migrate-rev MSG="add foo column to runs"
# The Gateway runs `alembic upgrade head` automatically at startup via
# `bootstrap_schema`, so there is intentionally no `migrate` / `migrate-stamp`
# target -- the single execution path keeps ops mistakes off the table.
migrate-rev:
	@if [ -z "$(MSG)" ]; then echo 'usage: make migrate-rev MSG="describe the change"'; exit 1; fi
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run python scripts/_autogen_revision.py "$(MSG)"
```

设计意图写在注释里：**Gateway 启动时自动 `alembic upgrade head`，所以故意不提供手动 `migrate` target**——单一执行路径让"忘了升级 schema"这类运维事故失去生存空间。脚本在干净 checkout 上也不需要现存数据库：它会先在临时 SQLite 打到 head 再对 ORM 模型做 diff。

---

## 20.2 多实例部署：门禁、租约与共享预算

### 20.2.1 启动门禁：宁可拒绝启动

`config.example.yaml:2956-2957` 只有两行：

```yaml
// config.example.yaml:2956-2957
deployment:
  multi_instance: false
```

但把它设为 `true`（或导出 `DEER_FLOW_MULTI_INSTANCE=1`，Helm 会按副本数自动设置）就触发一组启动期硬校验（`backend/docs/CONFIGURATION.md:819`）：

> Set `multi_instance: true` ... on every instance that shares one database. Startup then enforces the same prerequisites as `GATEWAY_WORKERS > 1`: `database.backend: postgres`, `run_events.backend: db`, `run_ownership.heartbeat_enabled: true`, and a Redis stream bridge (`stream_bridge.type: redis` or `DEER_FLOW_STREAM_BRIDGE_REDIS_URL`). It refuses an explicit `sandbox.ownership.type: memory`, process-local browser tools, and `scheduler.enabled: true` without `scheduler.multi_instance: true`.

也就是说，声明多实例后，四项前置 + 三类禁止项由启动门禁逐项把关。`backend/AGENTS.md:17` 补充：多进程启动门禁同样对 `GATEWAY_WORKERS > 1` 生效，契约在 `docs/CONFIGURATION.md`。相关"进程内"组件在多实例下会换实现：登录限流 `auth.local.throttle_storage` 默认 `auto`（DB 计数器让 N 个实例共享同一把锁）、IM 会话绑定进 `channel_thread_bindings` 表（迁移 `0038`）、凭证加密需要共享 `DEER_FLOW_CREDENTIALS_KEY`（`CONFIGURATION.md:825-826,903`）。

### 20.2.2 run 租约与心跳

`config.example.yaml:2981-2986`：

```yaml
// config.example.yaml:2981-2986
run_ownership:
  lease_seconds: 30           # Seconds before a run lease expires if not renewed.
                              # Heartbeat renews every lease_seconds / 3.
  grace_seconds: 10           # Extra seconds past expiry before reclaiming an orphaned run.
                              # Also the cross-worker clock-skew budget — see note above.
  heartbeat_enabled: false    # Set to true for GATEWAY_WORKERS > 1
```

多 worker 时每个 worker 用租约认领 run：心跳每 `lease_seconds / 3` 续租一次，对账协程从崩溃 worker 手里回收孤儿 run。注意 `grace_seconds` 的双重身份——它既是"过期后再等多久才回收"，也是**跨 worker 时钟偏移预算**（`config.example.yaml:2966-2974` 的 CLOCK-SYNC REQUIREMENT：各节点必须 NTP 同步，最坏情况下偏移超过 grace 的 peer 可能把还活着的 run 误判为孤儿）。而持有者自己不把 grace 当执行时间：续租确认失败就主动取消本地 run。

### 20.2.3 scheduler 多实例：租约恢复 + 全局预算

`config.example.yaml:2895-2905` 的 scheduler 段在生产多实例下的关键字段：

```yaml
// config.example.yaml:2895-2905
scheduler:
  enabled: false
  tool_enabled: false          # Offer schedule tools to authorized Gateway conversations
  multi_instance: false       # Opt into lease-aware recovery across Gateway instances
  poll_interval_seconds: 5
  lease_seconds: 120
  max_concurrent_runs: 3
  max_concurrent_runs_per_user: 2
  queue_timeout_seconds: 3600
  min_once_delay_seconds: 60
  recursion_limit: 1000
```

`backend/AGENTS.md:16` 是权威契约（原文节选）：

> `scheduler.multi_instance=true` opts into lease-aware recovery across Gateway instances and requires shared Postgres, `run_ownership.heartbeat_enabled: true`, and `run_events.backend: db`; otherwise startup rejects the configuration. ... expired launch claims return to the durable queue, expired run leases are atomically taken over, stale launch writes are fenced by lease ownership, and the Postgres advisory-locked budget makes `max_concurrent_runs` a shared global cap for `launching`/`running` rows.

要点拆解：

- **恢复语义**：peer 启动时保活中的运行不被打断；过期的 launch 认领回到持久队列；过期的 run 租约被原子接管；陈旧写入用租约所有权围栏（fencing）。
- **`max_concurrent_runs: 3` 为什么是全局的**：认领时的计数+更新在同一条 Postgres advisory lock 下串行化（SQLite 用 `BEGIN IMMEDIATE`），所以"3 个执行槽"是跨所有 Pod 共享的硬顶；`max_concurrent_runs_per_user: 2` 在同一次原子认领里生效，被拒的行保持 `queued`（`CONFIGURATION.md:769,777`）。
- **升级提醒**（`CONFIGURATION.md:779-781`）：`GATEWAY_WORKERS > 1` 且 `scheduler.enabled: true` 的旧部署必须二选一——scheduler 只跑在一个 worker 上，或打开 `scheduler.multi_instance` 全家桶；这些字段全部 restart-required，改完要**所有 Pod 一起重启**，ConfigMap 更新不同步重启会让服务停留在旧模式。

### 20.2.4 本机演练：`make dev-multi`

不用集群就能体验双实例拓扑（`Makefile:184-192` + `CONFIGURATION.md:834-848`）：

```bash
make dev-multi        # scripts/dev_multi_instance.sh up：Docker 起 Postgres+Redis，然后 Gateway A、B 与 nginx
make dev-multi-check  # 自动跨实例检查（注册/发消息/run 历史互通等）
make dev-multi-down   # 拆掉并删除数据
```

脚本会基于你自己的 `config.yaml` 生成一份多实例配置（自动加 `deployment.multi_instance: true`、`database.backend: postgres`、`run_events.backend: db`、心跳、Redis stream bridge），并**拒绝/改写**门禁不兼容项（移除进程内浏览器工具、scheduler 自动加 multi_instance、默认禁用 IM 机器人连接）。`stop b --kill` 可以模拟 B 实例崩溃来观察租约接管。

---

## 20.3 Helm 部署与版本锁步

### 20.3.1 Chart 结构

`deploy/helm/deer-flow/Chart.yaml:1-6`：

```yaml
// deploy/helm/deer-flow/Chart.yaml:1-6
apiVersion: v2
name: deer-flow
description: DeerFlow — LangGraph-based AI super-agent (gateway + frontend + nginx + sandbox provisioner) deployed to Kubernetes.
type: application
version: 2.3.0-dev
appVersion: "2.3.0-dev"
```

`templates/` 共 26 个模板，拓扑与第 0 章的四服务一致，外加生产件：`gateway-deployment.yaml` + `gateway-pdb.yaml` + `gateway-service.yaml`、`frontend-deployment.yaml` / `nginx-deployment.yaml`（两者各带 service）、`postgres-statefulset.yaml` + `postgres-secret.yaml` + `postgres-service.yaml`、`redis-statefulset.yaml` 三件套、`provisioner-*` 四件（K8s 沙箱模式才需要）、`pvc-home.yaml`、`ingress.yaml`、`configmap-{config,extensions,nginx}.yaml` 与 `secret-{app,provider}.yaml`。

配置注入方式遵循第 15 章讲过的读写面规则：Helm 把 `config.yaml` 播种为 **home 卷上的可写副本**（`backend/AGENTS.md:22`："Helm seeds a writable home-volume copy"），`extensions_config.json` 保持 Gateway 可写；`DEER_FLOW_MULTI_INSTANCE=1` 让部署工具按副本数声明多实例（`CONFIGURATION.md:819`）。

### 20.3.2 版本锁步：五处必须一致

发布版本必须同时出现在五个文件：`backend/pyproject.toml`、`backend/packages/harness/pyproject.toml`、`frontend/package.json`、`deploy/helm/deer-flow/Chart.yaml`（`version` + `appVersion`），以及 `backend/uv.lock`（root 与 harness 两个包的 PEP 440 版本）。`scripts/bump_version.sh:7-12` 的头部注释就是清单：

```text
// scripts/bump_version.sh:7-12
# Updates:
#   backend/pyproject.toml                      (version = "...")
#   backend/packages/harness/pyproject.toml     (deerflow-harness version = "...")
#   backend/uv.lock                             (root + harness package versions, via `uv lock`)
#   frontend/package.json                       ("version": "...")
#   deploy/helm/deer-flow/Chart.yaml            (version: + appVersion:)
```

脚本的工作流（`bump_version.sh:54-58,108-113`）：先检查 `uv` 在 PATH 上（缺失就**在改任何文件之前**失败，避免留下半更新的树），然后用 Python 正则原地改四个文件、跑 `uv lock` 刷新锁文件，最后**自动调用 `scripts/verify_versions.sh "$VERSION"` 做后验**——失败即报错退出。`verify_versions.sh:5-9` 列出全部五个校验源，`v*` tag 触发的发布工作流（`chart.yaml` / `container.yaml`，经可复用的 `verify-versions.yml`）在发布前强制执行，任何漂移阻断全部发布（根 `AGENTS.md` 版本锁步节）。`uv lock --check` 也在 lint CI 里跑，所以"改了 pyproject 忘了 lock"根本活不过本地 pre-commit（第 19 章 19.5.2）。

**实践纪律**：永远 `scripts/bump_version.sh <ver>`，不要手改五处——`CHANGELOG.md` 与打 tag 保持手动，其余交给脚本。

---

## 20.4 安全清单

生产前的逐项自查：

1. **回环默认绑定**。两个 Compose 文件发布 nginx 为 `"${BIND_HOST:-127.0.0.1}:${PORT:-2026}:2026"`——**默认只绑回环**；裸 `"${PORT}:2026"`（绑 0.0.0.0）被仓库约定与 CI 拒绝（`backend/tests/test_compose_default_bind_host.py` 钉住每个服务，`docs/ARCHITECTURE.md:44-49`）。Gateway 的 `8001` 永远不对外发布。新增发布端口必须显式写 bind 地址。任何非回环部署前先读 `README.md` 的 Security Notice。
2. **认证与 SSO**。`backend/docs/AUTH_DESIGN.md:1-19`：DeerFlow 默认强制认证（健康检查/文档/auth bootstrap 除外），**服务端持有所有权**（客户端 metadata 不能声明 `user_id` / `owner_id`），隔离默认开启（仓储、文件路径、memory、agent 配置都按当前用户解析），角色只有 `admin`/`user`，首初始化密码不进日志（`reset_admin` 只写 0600 凭据文件）。企业 SSO 走 `backend/docs/SSO.md`：任意 OIDC 2.0 提供商（Keycloak/Google Workspace/Azure AD/Okta…），Authorization Code + PKCE(S256) + nonce 校验。
3. **run-context 信任边界**。`non_interactive`、`disable_clarification`、`github_token` 只对内部认证调用方（scheduler、IM/webhook 渠道）生效，来自普通客户端 `body.context` / `body.config` 的同名键一律被剥离（`docs/ARCHITECTURE.md:177-182`、`backend/AGENTS.md:189-199`）。身份与沙箱生命周期字段无条件清空并按认证状态重盖。`context.locale` 是运行时语言偏好，永不落入 checkpoint。
4. **MCP 隔离**。每个 MCP server 独立进程、独立启停，`$VAR` 风格的凭证在运行时解析，不落配置明文（`docs/ARCHITECTURE.md:175-176`）。
5. **沙箱隔离**。生产必须 Docker `AioSandboxProvider`；local 直执行 provider 是开发专用（`docs/ARCHITECTURE.md:173-174`）。Compose **默认不挂 Docker socket**，纯 DooD 沙箱模式才通过 `docker-compose.dood.yaml` overlay 显式加入（`docker/docker-compose.yaml:161-166` 注释）。
6. **挂载读写面**。生产 Compose 中 `config.yaml` 以 `:ro` 挂载（没有 API 会写它），`extensions_config.json` **有意可写**（Gateway 运行时要改 MCP 开关、技能配置），双锁 + 临时文件原子替换防并发丢更新（`docker/docker-compose.yaml:153-158` 注释与 `backend/AGENTS.md:22`）。

```yaml
// docker/docker-compose.yaml:152-158
    init: true
    volumes:
      - ${DEER_FLOW_CONFIG_PATH}:/app/backend/config.yaml:ro
      # Writable on purpose: the Gateway edits this file at runtime (MCP
      # enable/disable, PUT/PATCH /api/mcp/config, skill updates). config.yaml
      # above stays read-only because no API writes it.
      - ${DEER_FLOW_EXTENSIONS_CONFIG_PATH}:/app/backend/extensions_config.json
```

顺带解释 `init: true`（`docker-compose.yaml:145-152` 注释讲了 #6835 的完整事故链）：`sh -c` 方式启动会让无 SIGTERM 处理的 shell 占住 PID 1，内核丢掉停止信号，lifespan shutdown 永远不跑，每次 stop 都要等满宽限期再 SIGKILL；`init` 让 Docker 的 tini 做 PID 1，转发信号并收割孤儿进程。生产镜像同样用 `exec` 保证 SIGTERM 直达（`backend/tests/test_gateway_sigterm_delivery.py`）。

---

## 20.5 故障排查工具箱

### 20.5.1 `make doctor`：体检先行

`Makefile:75-76` 一行 target 背后是 `scripts/doctor.py`：

```python
// scripts/doctor.py:1-8
#!/usr/bin/env python3
"""DeerFlow Health Check (make doctor).

Checks system requirements, configuration, LLM provider, and optional
components, then prints an actionable report.

Exit codes:
  0 — all required checks passed (warnings allowed)
  1 — one or more required checks failed
"""
```

它检查系统要求、配置、LLM provider 连通性与可选组件，输出可操作的报告；退出码让它可以直接进 CI/巡检脚本。与第 1 章的 `make check`（纯工具链检查）配合使用：先 `check` 后 `doctor`。

### 20.5.2 `make support-bundle`：脱敏诊断包

`Makefile:78-79` → `scripts/support_bundle.py --include-doctor`。脚本头（`support_bundle.py:1`）："Create a redacted DeerFlow support bundle for community troubleshooting." 它的关键资产是密钥脱敏正则（`support_bundle.py:18-25`）：

```python
// scripts/support_bundle.py:18-25（节选）
SECRET_KEY_RE = re.compile(
    r"(api[_-]?key|access[_-]?key|private[_-]?key|(?<![a-zA-Z])key(?![a-zA-Z])"
    r"|token|secret|password|passwd|pwd|(?<![a-zA-Z])pass(?!port)"
    r"|authorization|cookie|credential|(?<![a-zA-Z])dsn(?![a-zA-Z]))",
    re.IGNORECASE,
)
```

注释说明这套裸词表镜像了沙箱 `env_policy.py` 的拒绝列表（`*KEY*/*SECRET*/*TOKEN*/*PASS*/*CREDENTIAL*/*DSN*`）——因为固定 allowlist 挡不住开放字典里换了名字的密钥（如 `guardrails.provider.config` 这种任意 kwargs dict）。`pass` 只排除 `passport` 尾缀。产物包括脱敏摘要、AI issue 草稿与可选 zip，让你直接贴到社区 issue 而不必手工擦密钥。

### 20.5.3 日志与进程

- **本地前台/守护**：`logs/gateway.log` + `logs/frontend.log`，`tail -f` 双跟随（根 `AGENTS.md`）。
- **Docker**：`make docker-logs`（开发栈）、`make prod-logs`（生产栈）、分服务 `docker-logs-{frontend,gateway,redis}`（`Makefile:221-230,245-246`）。
- **多实例**：`scripts/dev_multi_instance.sh logs a -f` / `b` / `nginx` / `all`（`CONFIGURATION.md:847`）。

### 20.5.4 Windows 运维注意

Windows 上 root `Makefile` 检测 `Windows_NT` 后把 SHELL 切到 `cmd.exe`，仓库 shell 脚本经 `scripts/run-with-git-bash.cmd` 借 Git Bash 执行（`Makefile:9-13`）；host 上的 pnpm 调用统一走 `scripts/pnpm.py`——native Windows 先试 `pnpm.cmd` 再 `corepack`，POSIX 相反，Corepack 回退按同样顺序尝试（根 `AGENTS.md`）。后端进程统一带 `PYTHONIOENCODING=utf-8 PYTHONUTF8=1`（`backend/Makefile:33-36`），避免 Windows 控制台编码把日志与测试输出弄成乱码。前端 dev server 的 winnat/EACCES 问题见第 18 章 18.5.3。

---

## 动手实验：Postgres + 多实例 + Helm 的完整演练

目标：在本机完成"从单机 SQLite 到多实例就绪"的全流程，并产出一份 support bundle。全程离线（不需要模型 Key 也能完成到第 6 步）。

1. **基线**：`make config && make doctor`，确认当前单机栈健康（`config.example.yaml` 默认 `database.backend: sqlite`）。
2. **多实例演练**：`make dev-multi` 启动双 Gateway + Postgres + Redis；`make dev-multi-check` 跑跨实例检查，逐项读懂它验证了什么（建号、双实例互访同一会话、run 历史一致）。
3. **模拟故障**：`scripts/dev_multi_instance.sh stop b --kill`（SIGKILL 模拟崩溃），等待 `lease_seconds` 过期后观察 A 实例接管队列；`start b` 恢复。
4. **门禁负向验证**：手工把生成配置里的 `run_events.backend` 改回 `memory` 再启动，观察启动门禁的拒绝信息——**读懂每一条被拒绝的组合**比背规则更有效。
5. **Helm 干跑**：`helm template deploy/helm/deer-flow`（或 `helm lint`）检查渲染产物：确认 `gateway-deployment.yaml` 的副本数、`DEER_FLOW_MULTI_INSTANCE` 注入、`pvc-home.yaml` 与 configmap 的挂载关系。
6. **支持包**：`make support-bundle`，打开产物检查两类内容：哪些字段被 `SECRET_KEY_RE` 脱敏了、doctor 的输出是否与你在第 1 步看到的一致。
7. **收尾**：`make dev-multi-down` 清理容器与数据。

验收：你能向同事完整回答——为什么多实例四件套缺一不可、`max_concurrent_runs: 3` 如何在两个 Gateway 间共享、Helm 如何保证 `extensions_config.json` 可写而 `config.yaml` 只读。

---

## 20.6 部署模式对比与就绪判定

### 20.6.1 四象限：选哪条路

`backend/AGENTS.md:237-245` 给出全部启动模式的权威矩阵：

| | **Local Foreground** | **Local Daemon** | **Docker Dev** | **Docker Prod** |
|---|---|---|---|---|
| **Dev** | `./scripts/serve.sh --dev`<br/>`make dev` | `./scripts/serve.sh --dev --daemon`<br/>`make dev-daemon` | `./scripts/docker.sh start`<br/>`make docker-start` | — |
| **Prod** | `./scripts/serve.sh --prod`<br/>`make start` | `./scripts/serve.sh --prod --daemon`<br/>`make start-daemon` | — | `./scripts/deploy.sh`<br/>`make up` |

选型口诀：

- **本地开发**：`make dev`（热重载、日志落 `logs/`）；想后台跑用 `dev-daemon`。
- **本地预演生产**：`make start`（优化构建、无热重载）；`SKIP_FRONTEND_BUILD=1` 复用上次前端构建（`Makefile:159-164`）。
- **容器化开发**：`make docker-start`（按 `config.yaml` 模式感知启动）。
- **容器化生产**：`make up`，这是 Compose 生产栈的唯一入口；`make down` 拆除。
- **K8s 生产**：Helm Chart（20.3），多实例声明由副本数驱动。

### 20.6.2 生产镜像的两个硬约定

根 `AGENTS.md` 的运行时约定在生产语境下必须理解：

1. **生产用镜像内 Python**：`uv run --no-sync`——容器里不做依赖解析，启动更快也更确定；配套 `exec` 让 SIGTERM 直达进程。
2. **`init: true` 是兜底**（`docker-compose.yaml:152`）：即便将来某个服务用 shell 包装启动，tini 也会转发信号并收割孤儿进程；回归测试在 `backend/tests/test_gateway_sigterm_delivery.py`。

### 20.6.3 `make up` 的就绪等待

`make up` 不是"启动完就返回"：它会等待 Gateway 的 `/health` 端点就绪，失败时打印 Compose 服务状态与 Gateway 日志片段（根 `AGENTS.md`）。这条就绪链意味着：

- 数据库迁移（Alembic `upgrade head`，20.1.4）在 `/health` 之前完成——启动失败优先怀疑迁移或门禁拒绝，而不是端口。
- 依赖服务（Postgres/Redis）未就绪时，Gateway 会继续重试而不是半死不活地"假启动"。
- CI 侧同样有 `container.yaml` 的镜像构建与 `sandbox-image-smoke.yml` 的沙箱镜像冒烟兜底。

### 20.6.4 上线前检查单（浓缩版）

1. `make doctor` 全绿；`make check` 工具链齐全。
2. `config.yaml`：`database.backend`、`run_events.backend`、`scheduler.*` 与部署形态匹配（单机/多实例对照 20.2.1 清单）。
3. 回环绑定：Compose 发布端口带显式 `BIND_HOST`，Gateway 8001 未发布（20.4.1）。
4. 认证就绪：管理员账号已初始化、（可选）OIDC/SSO 配置验证过（20.4.2）。
5. 密钥面：`.env` 的 `DEER_FLOW_INTERNAL_AUTH_TOKEN`、`DEER_FLOW_CREDENTIALS_KEY` 已设置；多实例共用同一凭证密钥（20.2.1）。
6. 观测就绪：`token_usage.enabled: true`、（可选）`logging.enhance`、trace 提供者三选一。
7. 版本锁步：`scripts/verify_versions.sh <tag>` 通过再打 `v*` tag（20.3.2）。
8. 故障预案：`make support-bundle` 流程演练过一次，团队知道日志在哪（20.5.3）。

---

## 常见坑

1. **多实例条件缺一**：`deployment.multi_instance: true` 但数据库还是 SQLite / 心跳没开 / `run_events` 不是 db → 启动门禁直接拒绝。这是**故意的**：静默带病启动的代价是跨 worker 数据不一致（20.2.1）。
2. **改了 restart-required 字段没重启**：scheduler 的 poller 字段、`run_ownership`、`agent_storage`、`logging.enhance` 都是启动期捕获；尤其 `scheduler.multi_instance` 相关设置要求**所有 Pod 一起重启**，ConfigMap 单独更新会让服务停留在旧模式（20.2.3）。
3. **多副本配 SQLite**：SQLite 忽略行级锁，webhook 去重、调度认领这些依赖"同一行同一时刻只被一个进程持有"的机制全部失效；benchmark `concurrency` 就是这个结论的实验证据（20.1.1）。
4. **手改版本号导致发布被阻断**：五处版本（含 `uv.lock`）任何一处漂移，`v*` tag CI 的 `verify_versions.sh` 就拒绝全部发布。用 `scripts/bump_version.sh`，它改完还会自检（20.3.2）。
5. **绑 0.0.0.0 图省事**：Compose 裸 `"${PORT}:2026"` 会把服务暴露到所有网卡，违反仓库回环默认约定且 CI 会拦；确需外部访问用 `BIND_HOST` 显式声明，并先读 Security Notice（20.4.1）。
6. **容器停不下来**：自定义启动命令用 `sh -c` 包住 uvicorn 又没开 `init: true`，SIGTERM 丢失，每次 stop 等满宽限期再 SIGKILL。仓库 Compose 已设 `init: true`，别在自定义编排里退回去（20.4.6）。
7. **`make clean` 当作普通清理**：它会**删除** `backend/.deer-flow` 下的运行时数据（database/users/threads/uploads/memory/secrets）与日志，且有防呆检查（`Makefile:194-202`）；只是想重启就别碰它。

---

## 下一步

至此正章完结。你的下一站是**附录**：附录 A 把全书散落的命令收成三张速查表；附录 B 汇总 `config.yaml` 全部关键段（带行号）与 `extensions_config.json` 四键；附录 C 术语表、附录 D 三篇学习验收清单、附录 E 十余条 FAQ（端口冲突、模型 Key、沙箱、pnpm、配置不生效、Windows 专题）、附录 F 是 `docs/` 与 `backend/docs/` 全量文档到教程章节的映射——把它当作你以后回到源码世界的地图。全书完。
