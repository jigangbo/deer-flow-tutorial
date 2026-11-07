# 第 19 章 可观测性、测试与质量保障

> **本章源码锚点**
>
> | 锚点 | 作用 |
> | --- | --- |
> | `backend/Makefile:22` | `test` 四分片并行；`:35` `test-blocking-io`；`:49` `test-shard` 耗时均衡 |
> | `backend/tests/blocking_io/conftest.py:26` | Blockbuster 严格门禁的 hookwrapper |
> | `backend/pyproject.toml:63` | `blockbuster>=1.5.26,<1.6` 依赖声明 |
> | `backend/packages/harness/deerflow/trace_context.py:1` | 请求级 trace id 的唯一来源 |
> | `backend/packages/harness/deerflow/logging_config.py:9` | 日志格式与 trace 字段注入 |
> | `config.example.yaml:96` / `:106` | `token_usage:` 与 `token_budget:` 配置段 |
> | `backend/scripts/benchmark/` | deermem_eviction / concurrency / context_snapshot 基准目录 |
> | `frontend/rstest.config.ts:22` | 前端 node / happy-dom 双测试项目 |

## 19.0 学习目标

读完本章，你应该能够：

1. 描述 DeerFlow 的可观测性三件套：请求级 trace id（`X-Trace-Id`）如何绑定与传播、日志增强格式、Monocle/LangSmith/Langfuse 三条追踪通道如何开启。
2. 用 `token_usage` / `token_budget` 配置把一次 run 的成本控制在预算内，并说明超预算时"警告注入"与"强制收尾"两种干预的差异。
3. 读懂后端测试的完整分层：`make test` 四个耗时均衡分片、`make test-blocking-io` 的 Blockbuster 门禁、`make test-live` 的 opt-in 协议、`make test-shard` 的 `.test_durations` 基线。
4. 说清基准测试目录的纪律：数据集不可变 pin + SHA-256、禁止静默下载、合成用例自报身份。
5. 在前端 `pnpm check` / `rstest` / Playwright 与 `.pre-commit-config.yaml` 的约束下完成一次符合 TDD 要求的 bug 修复。

---

## 19.1 日志与追踪

### 19.1.1 请求级 trace id：唯一来源是 ContextVar

`backend/packages/harness/deerflow/trace_context.py` 的模块文档（1–31 行）把规则讲得非常透，值得整段读：

```text
// backend/packages/harness/deerflow/trace_context.py:1-9（docstring 节选）
"""Request trace context helpers.

The value stored here is DeerFlow's request-level correlation id. It is
separate from Langfuse's own trace id and from DeerFlow run ids.

**This ContextVar is the only source of a trace id.** Every path that reaches a
run binds one first: the Gateway ``TraceMiddleware`` for HTTP, and
:func:`ensure_trace_context` for the entry points that never touch ASGI --
scheduled occurrences, MCP task notification runs, IM channel messages, and the
embedded :class:`~deerflow.client.DeerFlowClient`.
```

设计的几个关键决定（原文都在 docstring 里）：

- **trace id ≠ run id ≠ Langfuse trace id**：它是纯关联 ID，用来把"同一次请求"在日志、响应头、run 元数据之间串起来。
- **所有下游载体都是"派生输出，永不回读"**（`trace_context.py:14-20`）：`X-Trace-Id` 响应头、`runtime.context` 里的 `deerflow_trace_id`、run 记录元数据、日志字段，全部只写不读。如果调用方在请求里塞了 `metadata.deerflow_trace_id`，会被替换而不是采纳——"一个你无法确信与日志一致的 trace id，比没有更糟"。跨服务想固定关联 ID 的正确做法是发送 `X-Trace-Id` 头。
- **跨执行边界用数据携带**：ContextVar 是 task-local 的，裸线程跳跃不会保留；定时任务、MCP 通知、IM 消息这些不经过 ASGI 的入口各自先 `ensure_trace_context()` 重新绑定。

### 19.1.2 日志增强：默认关、开了才带 trace 字段

`backend/packages/harness/deerflow/logging_config.py:9-11` 定义了两种格式：

```python
// backend/packages/harness/deerflow/logging_config.py:9-11
DEFAULT_LOG_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"
DEFAULT_LOG_FORMAT = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
TRACE_TEXT_LOG_FORMAT = "%(asctime)s - %(name)s - %(levelname)s - [trace_id=%(trace_id)s] - %(message)s"
```

开关在 `config.example.yaml:52-55`：

```yaml
# config.example.yaml:52-55
logging:
  enhance:
    enabled: false
    format: text
```

注意两点（`config.example.yaml:48-51` 注释原文）：trace id **永远**会签发并通过 `X-Trace-Id` 响应头返回——`logging.enhance` 只控制日志记录里是否带 `trace_id` 字段，不控制 id 的存在；该开关是 restart-required 的（走 `reload_boundary.py`）。

这个文件里还藏着一个安全细节：`httpx` 会在 INFO 级打印完整请求 URL，而入库媒体的 URL 是带签名凭证的，所以模块内置了一个 URL 脱敏正则（`logging_config.py:19-31`），把 host 之后的部分（含 basic-auth 用户信息）整体改写——这是"日志即泄露面"意识的实例。

### 19.1.3 三条 LLM 追踪通道

`backend/packages/harness/deerflow/tracing/` 目录有四个文件：`factory.py`、`monocle.py`、`metadata.py` 与 `AGENTS.md`。`factory.py:17-30` 按 trace 提供者构造回调：

```python
// backend/packages/harness/deerflow/tracing/factory.py:17-30（节选）
def _create_langsmith_tracer(config) -> Any:
    from langchain_core.tracers.langchain import LangChainTracer

    return LangChainTracer(project_name=config.project)


def _create_langfuse_handler(config) -> Any:
    from langfuse import Langfuse
    from langfuse.langchain import CallbackHandler as LangfuseCallbackHandler

    # langfuse>=4 initializes project-specific credentials through the client
    # singleton; the LangChain callback then attaches to that configured client.
    Langfuse(
        secret_key=config.secret_key,
```

即 **LangSmith / Langfuse 走 `config.yaml` 的 trace 配置段**（工厂从 `get_enabled_tracing_providers()` 读取并校验），而 **Monocle 走环境变量**——`config.example.yaml:85-88` 写明：`MONOCLE_TRACING`、`MONOCLE_EXPORTERS`、`OKAHU_API_KEY`，默认关闭，README 的 "Monocle Tracing" 一节说明每个 exporter 捕获什么、数据落到哪。三条通道互不冲突，生产上通常只开一条。

---

## 19.2 成本控制：`token_usage` 与 `token_budget`

### 19.2.1 计量开关与预算 enforcement

`config.example.yaml` 相邻两段给出了"只计量"与"硬限制"的两档：

```yaml
// config.example.yaml:96-97
token_usage:
  enabled: true

// config.example.yaml:106-112
token_budget:
  enabled: false                # Set to true to activate budget enforcement
  max_tokens: 200000            # Total token limit (input + output) per run
  max_input_tokens: null        # Optional separate input-only limit
  max_output_tokens: null       # Optional separate output-only limit
  warn_threshold: 0.8           # Warn at 80% of the budget
  hard_stop_threshold: 1.0      # Force stop at 100% of the budget
```

语义（`config.example.yaml:99-105` 注释）：`warn_threshold` 被跨越时，agent 会在上下文里收到一条**警告消息**（模型可以自己收敛）；`hard_stop_threshold` 被跨越时，挂起的 `tool_calls` 被剥除、agent 被迫立刻产出最终答案。默认 `enabled: false`——计量常开（`token_usage.enabled: true`），限流要显式打开。

### 19.2.2 递归上限：服务端硬顶

成本失控的另一路径是无限递归。`config.example.yaml:120-125`：

```yaml
// config.example.yaml:120-125
recursion_limit: 100

# The Gateway never trusts a configured or client-supplied value above this
# ceiling, preventing runaway API cost / DoS. Raise it only if you legitimately
# run very deeply nested subagent graphs.
max_recursion_limit: 1000
```

客户端可以按请求覆盖 `recursion_limit`，但非法或非正值回落到配置默认；任何值超过 `max_recursion_limit: 1000` 一律被网关钳制——这是"不信任客户端"的又一例（与第 20 章 run-context 信任边界同源）。调度轮在分发时读取 `scheduler.recursion_limit`（默认 1000，与 Web UI 一致），同样被这个硬顶约束（`backend/AGENTS.md:14`）。

### 19.2.3 子代理 token 归集

子代理在后台并行运行，其用量必须归到主 run 的账上。相关约定见 `backend/AGENTS.md:13`：终端用量从**当前 run 的 `ToolMessage.additional_kwargs` 与消息状态**取，"never a global provider-ID cache"——因为 provider 的 `tool_call_id` 跨父 run 可能碰撞，全局缓存会把别的 run 的用量记到本 run 头上。你在第 9 章见过的 `token_collector.py` 负责具体的归集。

---

## 19.3 测试体系：四分片、Blockbuster 门禁与 live 测试

### 19.3.1 命令矩阵

`backend/Makefile` 的测试 target 是理解质量闸门的第一手材料：

```makefile
// backend/Makefile:22-36（节选）
# Run all four duration-balanced shards locally; wait for every shard on failure.
TEST_JOBS ?= 4
TEST_SHARD_TARGETS := test-shard-1 test-shard-2 test-shard-3 test-shard-4
test:
	$(MAKE) --no-print-directory -k -j$(TEST_JOBS) $(TEST_SHARD_TARGETS)

$(TEST_SHARD_TARGETS):
	$(MAKE) --no-print-directory test-shard SPLITS=4 GROUP=$(patsubst test-shard-%,%,$@)

test-live:
	DEER_FLOW_RUN_LIVE_TESTS=1 PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest -m live tests/ -v -s

test-blocking-io:
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest tests/blocking_io -q --tb=short
```

再往下是分片本体（`backend/Makefile:49-52`）：

```makefile
// backend/Makefile:49-52
test-shard:
	@test -f "$(DURATIONS_FILE)" || \
		(echo "error: $(DURATIONS_FILE) is missing; run 'make test-shard-durations' to regenerate the duration baseline" >&2; exit 1)
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest -m "not live" --ignore=tests/blocking_io --splits $(SPLITS) --group $(GROUP) --splitting-algorithm least_duration --durations-path=$(DURATIONS_FILE) tests/ -q
```

四条注释级事实：

1. **`make test` = 四个耗时均衡分片并行**（`TEST_JOBS=4`，`-k` 保证任一分片失败后其余仍跑完），等价于 CI 的 `backend-unit-tests.yml` 切法；`TEST_JOBS=1` 串行。
2. **耗时均衡算法是 `least_duration`**：分片只**读** `.test_durations` 基线（没有 `--store-durations`），避免并发 CI 写竞争；改了测试集后用 `make test-shard-durations`（`backend/Makefile:57-58`）重建基线并提交。
3. **离线是默认**：`-m "not live"` 排除 live 测试，`--ignore=tests/blocking_io` 把阻塞 IO 门禁单列；live 测试必须显式 `DEER_FLOW_RUN_LIVE_TESTS=1`（`backend/AGENTS.md:226-227`），POSIX-only 标记还要用 `os.name` 守护 Windows 收集。
4. **依赖与分片库**：`backend/pyproject.toml:69` 的 `pytest-split>=0.11.0` 提供 `--splits/--group`，`:63` 的 `blockbuster>=1.5.26,<1.6` 提供运行时门禁。

### 19.3.2 Blockbuster：把"阻塞事件循环"变成红灯

DeerFlow 后端是全异步的，一行同步文件 IO 就能卡住整个 Gateway 事件循环。防线有三层，最硬的一层是 `tests/blocking_io/` 专用 conftest：

```python
// backend/tests/blocking_io/conftest.py:26-33
@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_protocol(item: pytest.Item, nextitem: pytest.Item | None) -> Generator[None, None, None]:
    if not _is_blocking_io_item(item) or item.get_closest_marker("allow_blocking_io") is not None:
        yield
        return

    with detect_blocking_io_strict():
        yield
```

三个细节（`backend/tests/blocking_io/conftest.py:1-12` docstring）：

- 门禁包住**整个 pytest item 协议（setup + call + teardown）**，所以异步 fixture 与 lifespan 代码里的阻塞 IO 也逃不掉，不只测试函数体。
- hookwrapper 是全局注册的，因此必须有显式路径过滤（`_is_blocking_io_item`）防止普通测试被误伤。
- 逃生舱是 `@pytest.mark.allow_blocking_io` 标记——用它要给出理由，review 会追问。

`tests/blocking_io/` 下有约 90 个专属测试文件，覆盖路由、沙箱、渠道、技能、persistence 等高危面。CI 由 `.github/workflows/backend-blocking-io-tests.yml` 单独跑这个目录。第二层防线是静态扫描：`make detect-blocking-io`（`backend/Makefile:67-68`）调用 `scripts/detect_blocking_io_static.py` 输出 JSON 清单。第三层是运行时兜底——`deerflow.utils.file_io.run_file_io`（ContextVar 保留式）与 `asyncio.to_thread` 是写新代码时的正确姿势（`backend/AGENTS.md:139-145` 列出的 HTTPX 客户端同步 TLS 构造都按此办理）。

**为什么这条门禁值得专门一节**：它把"异步纪律"从 code review 的口头约定变成可执行的 CI 断言。这是后端 TDD（`backend/AGENTS.md:216-227` 要求每个 feature/bugfix 必须带测试，跑 `make test` 与 `make test-blocking-io` 两个目标）之外，DeerFlow 最有特色的质量机制。

### 19.3.3 测试规模与组织

`backend/tests/` 顶层有 1340 个条目（绝大多数是 `test_<feature>.py`，另有 `fixtures/`、`support/`、`monocle/` 子目录与若干 `_*.py` 共享 helper）。组织规则（`backend/AGENTS.md:219-224`）：命名 `test_<feature>.py`；轻量配置/工具模块用纯单测；模块在测试中引发循环导入时在 `tests/conftest.py` 加 `sys.modules` mock（现有范例是 `deerflow.subagents.executor`）。前端 E2E 还有专门的回放形态：`replay_provider.py` + `.github/workflows/replay-e2e.yml` 支持"录一次、回放跑"。

---

## 19.4 基准测试：`scripts/benchmark/` 的纪律

`backend/scripts/benchmark/` 下现有：`checkpoint/`、`concurrency/`、`context_snapshot/`、`deermem_eviction/`、`deermem_scope_isolation/`、`goal_loop_stop/`、`sandbox/`、`scheduled_tasks/` 与 `skill_export.py`。大纲点名的三个：

### 19.4.1 `deermem_eviction`：记忆淘汰策略评估

`backend/scripts/benchmark/deermem_eviction/README.md:1-5` 开宗明义：

```text
// backend/scripts/benchmark/deermem_eviction/README.md:1-5
# DeerMem Capacity-Eviction Evaluation

This directory makes the controlled comparison behind DeerMem's opt-in `hybrid-v1` capacity policy reproducible. It depends on [deer-flow#4789]...

The evaluation calls the production `select_facts_for_capacity()` function. It does not copy the scoring implementation and does not introduce another eviction strategy.
```

它的"输入钉死"表是全仓库基准纪律的范本（`README.md:24-31`）：

| Input | Value |
| --- | --- |
| Dataset | `xiaowu0162/longmemeval-cleaned` |
| Revision | `98d7416c24c778c2fee6e6f3006e7a073259d48f` |
| File | `longmemeval_oracle.json` |
| SHA-256 | `821a2034d219ab45846873dd14c14f12cfe7776e73527a483f9dac095d38620c` |
| Official cases | 40 fixed IDs: 20 `knowledge-update`, 20 `temporal-reasoning` |

数据集**不下载**（"The CLI never downloads LongMemEval"），调用方自己准备本地路径；离线校验不依赖网络、凭证或数据集本体，测试 fixture 必须是合成并自报身份的。运行命令（`backend/AGENTS.md:71-78`）：

```bash
PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction validate-contracts
PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction validate --dataset "$LONGMEMEVAL_ORACLE_PATH"
PYTHONPATH=. uv run pytest tests/test_bench_deermem_eviction_*.py -q
```

### 19.4.2 `concurrency`：SQLite vs Postgres 的多进程争用

这个基准直接回答第 20 章"为什么多实例必须 Postgres"：它测的是 `users` 表上的**N 个独立 OS 进程**争用（不是 asyncio 任务），即 `CONFIGURATION.md` 要求 Postgres 的那个场景（`backend/AGENTS.md:84-88`）。`worker.py` 绕过编排器已完成的 Alembic 引导、直连 SQLAlchemy 并镜像应用的每连接 SQLite PRAGMA；`run_concurrency_bench.py` 为 Postgres 播种一次性 schema、用 READY/GO 屏障同步计时起点，**任何崩溃、操作数不足或 `errors > 0` 都以非零码退出**（`backend/AGENTS.md:89-92`）。Postgres 运行需要 `--pg-url` 指向一次性库，绝不触碰 `public`。

### 19.4.3 `context_snapshot`：上下文交接快照评估

`backend/scripts/benchmark/context_snapshot/README.md:1-5`：8 个合成 JSON/Python 任务、51 条预声明检查，**不下载任何外部数据集**；`run-live` 是显式动作，不属于 pytest 或默认 CI：

```bash
export CONTEXT_SNAPSHOT_BASE_URL="https://provider.example/v1"
export CONTEXT_SNAPSHOT_MODEL="your-model-id"
uv run python -m scripts.benchmark.context_snapshot run-live --output-dir /tmp/context-snapshot-run
```

输出目录会拿到 `run.json`（记录模型、配置、种子、源码哈希、包版本、git revision 与 dirty 状态）——**可复现性的完整证据链**。

### 19.4.4 通用纪律

`backend/AGENTS.md:43-63` 把规矩写死：基准必须独立可复现、**导入生产函数而不是复制实现**；数据集按不可变 revision + SHA-256 pin；凭证只从具名环境变量读；模型 ID、推理参数、prompt、重试规则、时钟与随机种子全部版本化进评测配置；合成用例必须自报 synthetic；固定时钟与确定性排序用于离线选择。

---

## 19.5 前端测试与 CI 全景

### 19.5.1 前端测试矩阵

`frontend/package.json:20-21` 两个入口：`"test": "rstest"` 与 `"test:e2e": "playwright test"`。单测在 `tests/unit/` 下按 `src/` 镜像组织（现有子目录：`app/`、`components/`、`content/`、`core/`、`hooks/`、`lib/`、`scripts/`、`helpers/`），node 与 happy-dom 双 project 的切分规则已在第 18 章 18.5.2 讲过。E2E 目录四个：`tests/e2e/`（主套件，Chromium，CI 四分片）、`tests/e2e-auth/`、`tests/e2e-real-backend/`（连真实后端的契约测试，如 `auth-disabled-contract.spec.ts`）、`tests/e2e-record/`。注册权限路由时要同时更新 E2E 契约与后端 `backend/tests/test_auth_me_permissions.py`，两处共同钉死完整清单（`frontend/AGENTS.md:46-50`）。

### 19.5.2 pre-commit 与 CI 工作流

`.pre-commit-config.yaml` 定义了五个本地钩子（`make install` 时装好）：

```yaml
// .pre-commit-config.yaml:5-22（后端三钩子）
      - id: ruff
        name: ruff lint
        entry: bash -c 'cd backend && uv run ruff check --fix "${@/#backend\//}"' --
      - id: ruff-format
        name: ruff format
        entry: bash -c 'cd backend && uv run ruff format "${@/#backend\//}"' --
      - id: uv-lock-check
        name: uv lock check
        entry: bash -c 'cd backend && uv lock --check'
```

外加 `frontend-eslint` 与 `frontend-prettier` 两个前端钩子。注意 `uv-lock-check` 只在 `pyproject.toml` / `uv.lock` / harness `pyproject.toml` 变更时触发——这正是版本锁步（第 20 章）的本地第一道闸。

`.github/workflows/` 共 19 个工作流，按职责分组：

- **测试**：`backend-unit-tests.yml`（四分片）、`backend-blocking-io-tests.yml`（门禁）、`frontend-unit-tests.yml`、`e2e-tests.yml`、`replay-e2e.yml`、`backend-windows-live-policy.yml`（Windows 收集策略）。
- **发布**：`verify-versions.yml`（可复用）、`chart.yaml` 与 `container.yaml`（v* tag 触发，内部先跑版本校验）、`lark-cli-images.yaml`。
- **专项**：`skill-review-ci.yml`（技能评审 + `tests/skills/` 回归 + 豁免文件 `.github/skill-review-waivers.v1.json`，blocker 永不可豁免）、`extension-package-check.yml`、`sandbox-image-smoke.yml`、`sandbox-network-proxy-image.yaml`、`lint-check.yml`、`nightly.yaml`、`label-sync.yml`、`triage.yml`、`jev-plugin-package.yml`。

技能测试纪律（根 `AGENTS.md`）再强调一次，因为它最容易在自写技能时翻车：**保真**（测试不得改 YAML 值与正文）、**显式 UTF-8**（读 `SKILL.md` 用 `utf-8-sig` 剥 BOM、写用 `utf-8`，永不依赖平台 locale）、**离线**（非法元数据走子进程 CLI 校验；可选依赖不可用时演练降级；HTTP 用 mock transport）。

---

## 动手实验：TDD 修复一个带 bug 的小问题（含全量门禁）

以"给 `select_facts_for_capacity()` 的容量参数加一个非法值防御"为例走完整流程（离线、不需要任何 API key）。

**第 1 步：写失败测试。** 新建 `backend/tests/test_capacity_guard.py`：

```python
import pytest

from deerflow.memory.capacity import select_facts_for_capacity  # 按实际模块路径导入


def test_capacity_must_be_positive() -> None:
    with pytest.raises(ValueError):
        select_facts_for_capacity(facts=[], capacity=0)
```

**第 2 步：跑红灯。** `cd backend && python -m pytest tests/test_capacity_guard.py -q`——预期失败。

**第 3 步：最小修复。** 在生产函数入口加参数校验。同时确认导入路径是生产模块本体（基准纪律同样适用于测试：测真实实现，不测副本）。

**第 4 步：全量门禁。** 依次执行并全部转绿：

```bash
cd backend
make lint                 # ruff check + ruff format --check（行宽 240）
make test                 # 四个耗时均衡分片
make test-blocking-io     # Blockbuster 门禁
```

**第 5 步（加分项）：前端联动。** 如果你的修复影响 UI 展示（例如容量字段出现在记忆设置页），在 `frontend/tests/unit/` 镜像路径补一个 node 单测，跑 `cd frontend && pnpm check && pnpm rstest run memory`。

**复盘检查点**：红灯先于修复；测试断言的是行为而非实现；两个后端门禁都过了；没有引入任何 `allow_blocking_io` 标记；`uv lock --check` 没有抱怨（你没动依赖）。

---

## 常见坑

1. **live 测试被误触发或误收集**：离线分片已用 `-m "not live"` 排除，但自己裸跑 `pytest tests/` 时若环境变量 `DEER_FLOW_RUN_LIVE_TESTS=1` 还挂着，真实 API 会被调用。live 永远显式开、用完即关（19.3.1）。
2. **异步代码里写同步 IO**：`open()`、`time.sleep()`、同步 HTTP 调用出现在 async 路径，`make test-blocking-io` 直接红灯。正确姿势是 `run_file_io` / `asyncio.to_thread`；确有例外用 `@pytest.mark.allow_blocking_io` 并说明理由（19.3.2）。
3. **`make test-shard` 报缺基线**：`.test_durations` 不存在就拒绝运行——这是防并发写竞争的设计。先 `make test-shard-durations` 重建基线并随变更一起提交（19.3.1）。
4. **基准测试里"顺手下载"数据集**：违反 pin 纪律，评测命令永不静默下载；数据集路径由调用方提供、revision 与 SHA-256 提前钉死、合成用例自报身份（19.4.4）。
5. **`uv lock --check` 失败拖红 CI**：手改了 `pyproject.toml` 却忘了刷新 `backend/uv.lock`。pre-commit 的 `uv-lock-check` 钩子本来能拦住，跳过钩子提交（`--no-verify`）就会把问题推给 CI（19.5.2）。
6. **token 预算没生效**：`token_budget.enabled` 默认 `false`，只开 `token_usage` 是"只看账单不拦消费"；且 `max_tokens` 是整个 run 的输入+输出总和，与模型单次调用的 `max_tokens` 输出上限是两个概念（19.2.1，另见 `config.example.yaml:132-143` 对两个相似字段的辨析）。
7. **Windows 上 POSIX-only 测试炸收集**：live/POSIX 标记必须用 `os.name` 守护（`backend/AGENTS.md:226-227`），否则 Windows 贡献者在收集阶段就崩。

---

## 下一步

质量闸门的意义在"敢部署"。下一章（第 20 章 生产部署与运维）把镜头拉到线上：SQLite 还是 Postgres、单实例还是多实例、Helm Chart 与版本锁步如何配合、回环绑定与认证体系如何兜底安全、`make doctor` 与 `make support-bundle` 如何在故障时刻救你。你会把本章的测试纪律和基准证据，变成部署决策的依据。
