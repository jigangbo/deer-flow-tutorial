# 第 16 章 扩展（Extensions）开发

## 16.0 学习目标

读完本章，你应该能够：

1. 复述 DeerFlow 的**扩展优先哲学**：新功能优先做成打包扩展而不是改核心，核心只保留
   bug 修复与 agent loop / 记忆 / 上下文压缩 / 认证这类属于框架本身的变更；
2. 说出九大贡献点（middleware、task lifecycle、system-model observer、agent-assembly
   observer、context-compaction observer、Gateway service、router、full-stack plugin、
   knowledge provider）分别"钩在宿主的哪个位置"，以及它们各自的注册方法名；
3. 读懂一个扩展的三件套结构：PEP 621 入口（`deerflow.extensions` 组）、`@extension`
   版本戳、`install(registry, config)` 注册函数，并能独立写出一个最小扩展；
4. 走通扩展的完整生命周期：`make extension-install → list → enable → restart → 验证
   → disable → remove`，并理解每一步在 `pyproject.toml` / `uv.lock` / `config.yaml` /
   `backend/extensions/sources/` 里各改了什么；
5. 分清两条配置通道的边界：operator 专属的 `config.yaml → plugins:`（会导入代码）与
   API 可写的 `extensions_config.json`（middlewares / mcpInterceptors / mcpServers /
   skills），以及为什么这条边界是安全边界。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 扩展规则权威文档 | `backend/packages/harness/deerflow/extensions/AGENTS.md:171`（九大贡献点） |
| 注册契约（协议） | `backend/packages/extension-api/deerflow_extension_api/contracts.py:190`（`ExtensionRegistry`） |
| `@extension` 版本戳 | `backend/packages/extension-api/deerflow_extension_api/contracts.py:248` |
| 中间件语义位置 | `backend/packages/extension-api/deerflow_extension_api/placement.py:20`（`Placement`）、`:43`（`AgentScope`）、`:59`（`MiddlewarePlacement`） |
| 任务生命周期协议 | `backend/packages/extension-api/deerflow_extension_api/contracts.py:75`（`TaskLifecycleContributor`） |
| 系统模型调用观察者 | `backend/packages/extension-api/deerflow_extension_api/contracts.py:138`（`SystemModelCallObserver`） |
| 服务与运行时依赖 | `backend/packages/extension-api/deerflow_extension_api/contracts.py:178`（`ExtensionService`）、`:166`（`ExtensionRuntimeDeps`） |
| 最小示例入口 | `examples/deerflow-extension-example/deerflow_extension_example/__init__.py:21` |
| 五个贡献实现 | `examples/deerflow-extension-example/deerflow_extension_example/plugin.py:96/136/151/172/184/204` |
| 打包清单 | `examples/deerflow-extension-example/pyproject.toml:14`（entry point） |
| 扩展管理器 | `backend/packages/harness/deerflow/extensions/manager.py:153`（`ExtensionManager`）、`:168`（install）、`:257`（uv add）、`:546`（跨进程锁）、`:1125`（uv sync） |
| 操作员 CLI | `backend/packages/harness/deerflow/extensions/cli.py:19`（`build_parser`）、`:63`（`main`） |
| 根 Makefile 包装 | `Makefile:122`–`Makefile:148`（`extension-*` targets） |
| 宿主加载与注册表 | `backend/packages/harness/deerflow/extensions/loader.py:160`（`load_extensions`）、`backend/packages/harness/deerflow/extensions/registry.py:70` |
| 中间件组合点 | `backend/packages/harness/deerflow/extensions/stack.py`、`ordering.py`、`isolation.py`（IsolatedMiddleware 包装） |
| `plugins:` 配置块 | `config.example.yaml:3674`–`config.example.yaml:3709` |
| API 可写配置通道 | `extensions_config.example.json:1`–`extensions_config.example.json:5` |
| 全栈插件契约 | `backend/packages/extension-api/deerflow_extension_api/plugins.py:95`（`PluginContribution`）、`:56`（`ModelTool`）、`docs/full-stack-plugins.md` |
| 书签全栈示例 | `examples/deerflow-extension-bookmarks/deerflow_extension_bookmarks/__init__.py:139` |
| 知识提供者示例 | `examples/deerflow-extension-knowledge/deerflow_extension_knowledge/__init__.py:48` |
| 打包检查脚本 | `scripts/check_extension.py`、`examples/README.md` |

---

## 16.1 概念讲解：扩展优先哲学

根目录 `AGENTS.md` 的 **Extension-first evaluation** 段写得很直接：在动手改核心代码实现
一个功能之前，先评估它能不能作为一个打包扩展交付。只有两类情况留在核心——bug 修复，以及
agent loop、记忆、上下文压缩、认证这类"改了就是框架行为"的变更。如果现有钩子表达不了这个
功能，正确做法是给扩展契约加一个**通用**钩子，再写一个使用它的扩展，而不是把业务逻辑
硬编码进核心。

为什么要有这条哲学？看 DeerFlow 的三层包结构就明白了：

```
backend/packages/extension-api/   → deerflow_extension_api（扩展公共契约，零框架依赖）
backend/packages/harness/         → deerflow.*（可发布的 agent 框架）
backend/app/                      → app.*（FastAPI Gateway + IM 渠道，不发布）
```

扩展只依赖第一层的公共契约，永不导入 `deerflow.*` 或 `app.*` 的内部模块。这样核心可以
独立重构升级，扩展却不用跟着改——这是把业务装进 DeerFlow 而不被核心版本绑架的前提。

扩展能"钩"进宿主的九个位置（`backend/packages/harness/deerflow/extensions/AGENTS.md:171`）：

| 贡献点 | 注册方法 | 钩在哪里 |
| --- | --- | --- |
| 中间件贡献者 | `registry.middlewares(contributor)` | lead agent / subagent 的中间件链 |
| 任务生命周期 | `registry.task_lifecycle(contributor)` | 每次 run / subagent 的 start/stop |
| 系统模型调用观察者 | `registry.system_model_observer(observer)` | 目标评估、记忆抽取、标题、摘要这四类不经中间件的模型调用 |
| Agent 组装观察者 | `registry.agent_assembly_observer(observer)` | `assemble_lead_agent()` 组装完成时 |
| 上下文压缩观察者 | `registry.context_compaction_observer(observer)` | `compact_state()` 摘要替换历史的那一刻 |
| Gateway 常驻服务 | `registry.service(service)` | Gateway 启动/停止生命周期 |
| HTTP 路由 | `registry.routers(...)` | 挂在所有宿主路由**之后**的 FastAPI 路由 |
| 全栈插件（实验性） | `registry.plugin(PluginContribution(...))` | 浏览器页面 + 后端 action + 模型工具 三位一体 |
| 只读知识提供者 | `registry.knowledge_provider(name, provider)` | `deerflow.knowledge` 检索层 |

注意契约的设计取向（`contracts.py` 模块注释）：每个 Protocol 方法都带默认实现、每个
dataclass 字段都带默认值，因此契约新增方法/字段对老扩展是**可加性**的——老扩展不用改一行
代码就能在新宿主上继续跑。

## 16.2 源码走读 A：契约包 `deerflow-extension-api`

### 16.2.1 注册面：`ExtensionRegistry`

`install()` 函数拿到的第一个参数就是它（`backend/packages/extension-api/deerflow_extension_api/contracts.py:190`）：

```python
@runtime_checkable
class ExtensionRegistry(Protocol):
    """The write-only registration surface handed to ``install()``.

    Structural and minimal on purpose. ...
    """

    def plugin(self, contribution: PluginContribution) -> bool:
        """Return True when accepted; False means this host lacks plugin UI support."""
        return False

    def knowledge_provider(self, name: str, provider: Any) -> bool:
        ...
        return False

    def middlewares(self, contributor: MiddlewareContributor) -> None:
        return None

    def task_lifecycle(self, contributor: TaskLifecycleContributor) -> None:
        return None

    def system_model_observer(self, observer: SystemModelCallObserver) -> None:
        return None

    def agent_assembly_observer(self, observer: AgentAssemblyObserver) -> None:
        return None

    def context_compaction_observer(self, observer: ContextCompactionObserver) -> None:
        return None

    def service(self, service: ExtensionService) -> None:
        return None

    def routers(self, routers: Sequence[Any]) -> None:
        return None
```

三个细节值得咀嚼：

1. **`plugin()` / `knowledge_provider()` 返回 `bool`**：老宿主不认识这两种贡献时返回
   `False` 而不是抛错。扩展必须检查返回值——后面书签示例里那句
   `raise RuntimeError("This example requires the full-stack plugin host contract")`
   就是标准姿势：宿主太老就**显式失败**，而不是静默丢功能。
2. **`routers()` 的类型是 `Sequence[Any]`**：契约包刻意不依赖 FastAPI。路由对象是什么
   形状由宿主在挂载时校验，契约包保持"零框架依赖"。
3. **它是 write-only 的**：`install()` 只能注册、不能反查宿主状态，运行期能力通过
   `ExtensionService` 的 `start(deps)` 注入（见 16.2.3）。

### 16.2.2 版本戳：`@extension` 装饰器

`backend/packages/extension-api/deerflow_extension_api/contracts.py:248`：

```python
def extension(*, api: str, name: str | None = None) -> Callable[[F], F]:
    """Stamp an install function with the API version it was written against.

    Optional. pip's dependency resolution is the primary compatibility
    mechanism; this covers `--no-deps` installs and editable monorepo checkouts
    where versions can skew, and turns a deep AttributeError into an
    actionable startup diagnostic.
    """

    def _decorate(func: F) -> F:
        func.__deerflow_api__ = api  # type: ignore[attr-defined]
        func.__deerflow_name__ = name  # type: ignore[attr-defined]
        return func

    return _decorate
```

正常情况下，`pyproject.toml` 里的 `deerflow-extension-api>=0.2,<0.3` 依赖范围才是
兼容性的第一道闸；`@extension(api="0.2.0")` 是第二道保险——当有人用 `--no-deps` 安装、
或可编辑安装导致版本错位时，加载器把"深层 AttributeError"提前变成一句能看懂的启动诊断。

### 16.2.3 中间件的"语义位置"而不是"列表下标"

`backend/packages/extension-api/deerflow_extension_api/placement.py:20`：

```python
class Placement(StrEnum):
    MODEL_LOGICAL = "model_logical"
    """Model axis, outer end. Guarantee: outer of retry and error handling.
    Fires once per logical decision regardless of how many times the host
    retries underneath."""

    MODEL_PHYSICAL = "model_physical"
    """Model axis, inner end. ... Fires once per physical provider call; retries re-enter it."""

    TOOL_VISIBLE = "tool_visible"
    """Tool axis, outer end. Guarantee: outer of truncation, sanitization and
    error wrapping. Observes what the model finally sees."""

    TOOL_RAW = "tool_raw"
    """Tool axis, inner end. Guarantee: adjacent to the real callable
    boundary. Observes the tool's raw return before any processing."""

    STANDARD = "standard"
    """No before/after-processing requirement. Relative order against other
    STANDARD contributors is not guaranteed."""
```

扩展声明的是**语义保证**（"我要看模型最终看到的工具返回"），不是"把我插到第 3 层"。
宿主因此保留了重构自己中间件栈的自由。配套的 `AgentScope`（`placement.py:43`）用 Flag
声明这个中间件作用于 lead、subagent 还是两者（`LEAD | SUBAGENT = BOTH`）；
`MiddlewarePlacement`（`placement.py:59`）把三者打包成一条贡献记录：

```python
@dataclass(frozen=True)
class MiddlewarePlacement:
    middleware: Any          # 契约包不 import LangChain，宿主在注入时校验类型
    placement: Placement
    scope: AgentScope = AgentScope.BOTH
    order: int = 0
```

宿主侧的规则（`backend/packages/harness/deerflow/extensions/AGENTS.md:179` 附近）：
`extensions/stack.py` 是唯一的最终组合点；贡献的中间件会被 `IsolatedMiddleware`
（`extensions/isolation.py`）包裹——扩展抛出的异常只会变成一条诊断并 fail-open，不会
炸掉整个 run，也不会重复触发下游的模型/工具副作用。

### 16.2.4 服务与运行时依赖注入

路由在 `install()` 时就要构建，但那时 Gateway 的数据库、会话工厂都还没就绪。怎么办？
把"注册期"和"运行期"分开（`backend/packages/extension-api/deerflow_extension_api/contracts.py:166`）：

```python
@dataclass(frozen=True)
class ExtensionRuntimeDeps:
    """Host capabilities bound after Gateway infrastructure is ready."""

    app_store: ExtensionData | None = None
    policy: HostPolicySnapshot = field(default_factory=HostPolicySnapshot)
    session_factory: Any | None = None
    run_evidence_reader: RunEvidenceReader | None = None
    model_invoker: ModelInvoker | None = None
    completed_run_evidence: CompletedRunEvidenceReader | None = None
    skill_mutations: SkillMutationService | None = None


class ExtensionService(Protocol):
    async def start(self, deps: ExtensionRuntimeDeps) -> None:
        return None

    async def stop(self) -> None:
        return None
```

`ExtensionData` 是扩展自己拥有的键值存储（应用作用域 + 每任务作用域两份），`policy` 是
宿主策略的窄投影（`HostPolicySnapshot`，刻意不暴露完整 `AppConfig`，避免扩展被 harness
的发版节奏绑死），`session_factory` 给需要查数据库的服务，`model_invoker` 只在
`host_access.model_invocation` 授权后才有值。

## 16.3 源码走读 B：解剖 `deerflow-extension-example`

`examples/deerflow-extension-example/` 是官方推荐的起点（`examples/README.md:8`：
"Start here for backend extensions"）。它用最小代码演示五个贡献点。目录结构：

```
deerflow-extension-example/
├── pyproject.toml                          # 打包清单 + entry point
├── README.md
├── deerflow_extension_example/
│   ├── __init__.py                         # install() 入口（带版本戳）
│   └── plugin.py                           # 五个贡献的实现
└── tests/
    ├── test_entry_point.py
    ├── test_plugin.py
    └── test_tool_stats.py
```

### 16.3.1 入口与注册

`examples/deerflow-extension-example/deerflow_extension_example/__init__.py:21`：

```python
@extension(api="0.2.0", name="example")
def install(registry: ExtensionRegistry, config: Mapping[str, Any]) -> None:
    """Register one middleware, task lifecycle, system-model observer, service, and router."""
    if config.get("enabled", True) is False:
        return

    service = ExampleService()
    registry.middlewares(ExampleMiddlewareContributor())
    registry.task_lifecycle(ExampleTaskLifecycle())
    registry.system_model_observer(ExampleSystemObserver())
    registry.service(service)
    registry.routers((build_router(service),))
```

注意三件事：

- **`config` 是这条插件记录里 `config:` 键的私有配置**（见 16.5 的 YAML 示例），扩展自己
  定义它的 schema 并自己解析——这里约定 `enabled: false` 时整个扩展不注册任何东西；
- **`service` 与 `router` 共享同一个对象**：路由通过 FastAPI 依赖调用
  `service.require_deps()`，保证"路由拓扑在 install 期固定，运行期能力后到"；
- 每条 `registry.*` 调用都被宿主**按位置记账与回滚**：安装失败时前面已注册的贡献会被
  一一撤销（宿主 registry 的 attribution/rollback 机制，见 `extensions/registry.py:70`）。

### 16.3.2 中间件：数工具调用

`examples/deerflow-extension-example/deerflow_extension_example/plugin.py:96`：

```python
class ExampleMiddleware(AgentMiddleware):
    @contextmanager
    def _observe(self, request: ToolCallRequest) -> Iterator[None]:
        task_store = task_store_from_runtime(getattr(request, "runtime", None))
        task_stats = task_store.get(ExampleStats) if task_store is not None else None
        if task_stats is None:
            yield
            return
        task_stats.note_tool_call()
        started = monotonic_ns()
        outcome = "returned"
        try:
            yield
        except CancelledError:
            outcome = "cancelled"
            raise
        except BaseException:
            # Includes graph interrupts; observation must not consume control flow.
            outcome = "raised"
            raise
        finally:
            task_stats.note_tool_outcome(outcome, monotonic_ns() - started)

    def wrap_tool_call(self, request, handler) -> Any:
        with self._observe(request):
            return handler(request)

    async def awrap_tool_call(self, request, handler) -> Any:
        with self._observe(request):
            return await handler(request)
```

这是观察类中间件的范本，四个要点：

1. **`task_store_from_runtime()`** 从 LangGraph runtime 里取回本任务的扩展数据存储；
   取不到就 yield 直通——中间件绝不因为自己的统计需求而改变行为；
2. **同步/异步成对实现**：`wrap_tool_call` 与 `awrap_tool_call` 是同一个能力在两条执行
   路径上的投影，只实现一边就只能观察到一条路径（`extensions/AGENTS.md` 明确了这一约定）；
3. **异常透传**：`except BaseException: raise`——观察者必须把 GraphInterrupt 这类控制流
   原样上抛，统计完就放手；
4. **`cancelled` / `raised` / `returned` 三分**：README 里特意说明 `returned` 不代表业务
   成功——下游把异常转成错误 `ToolMessage` 也算 `returned`。

中间件如何进入宿主？通过贡献者对象（`plugin.py:136`）：

```python
class ExampleMiddlewareContributor:
    def contribute_middlewares(
        self,
        app_store: ExtensionData,
        ctx: AgentBuildContext,
    ) -> Sequence[MiddlewarePlacement]:
        return (
            MiddlewarePlacement(
                ExampleMiddleware(),
                Placement.TOOL_VISIBLE,
                AgentScope.BOTH,
            ),
        )
```

`ctx: AgentBuildContext` 里带着本次组装的 scope、agent 名、模型名与宿主策略快照，扩展可以
据此决定"这个 agent 要不要加我的中间件"。`contribute_middlewares` 在**每次 agent 组装**
时调用，所以同一扩展可以为不同 agent 返回不同的中间件集合。

### 16.3.3 任务生命周期：把任务统计折叠回应用作用域

`plugin.py:151`：

```python
class ExampleTaskLifecycle:
    async def on_task_start(
        self, app_store: ExtensionData, task_store: ExtensionData, info: TaskInfo,
    ) -> None:
        task_store.set(ExampleStats())

    async def on_task_stop(
        self, app_store: ExtensionData, task_store: ExtensionData,
        info: TaskInfo, outcome: TaskOutcome,
    ) -> None:
        task_stats = task_store.remove(ExampleStats)
        if task_stats is not None:
            _stats(app_store).absorb_task(task_stats, outcome)
```

每次 run（lead 或 subagent）开始时在任务作用域放一个全新统计对象，结束时移出并合并进
应用作用域。`TaskInfo`（`contracts.py:63`）携带 `task_id / run_id / thread_id / kind`
（`"lead"` 或 `"subagent"`）/ `parent_task_id`，`TaskOutcome` 只有三档保守值：
`completed / aborted / failed`。注意生命周期钩子是 **awaited** 的（在 run 启动后、完成
持久化后执行），失败只记日志不炸 run。

### 16.3.4 系统模型调用观察者

`plugin.py:172`：

```python
class ExampleSystemObserver:
    async def on_system_model_call(
        self, app_store: ExtensionData, task_store: ExtensionData,
        kind: SystemOperationKind, request: SystemModelRequest, result: SystemModelResult,
    ) -> None:
        _stats(app_store).note_system_call(kind, failed=result.error is not None)
```

DeerFlow 有四类**不经中间件**的宿主自有模型调用：目标评估（goal）、记忆抽取（memory）、
标题生成（title）、摘要（summarization）——对应 `SystemOperationKind` 的四个枚举值
（`contracts.py:97`）。想在成本审计里看到这些"隐形调用"，就得用这个观察者。它拿到的是
请求/结果快照（`SystemModelRequest.messages` 已规范化为 tuple）加耗时，拿不到原始模型对象。

### 16.3.5 服务 + 路由：一套对象，两个阶段

`plugin.py:184` 与 `plugin.py:204`：

```python
class ExampleService:
    def __init__(self) -> None:
        self._deps: ExtensionRuntimeDeps | None = None

    async def start(self, deps: ExtensionRuntimeDeps) -> None:
        self._deps = deps

    async def stop(self) -> None:
        self._deps = None

    async def require_deps(self) -> ExtensionRuntimeDeps:
        deps = self._deps
        if deps is None or deps.app_store is None:
            raise HTTPException(status_code=503, detail="extension-example is not running")
        return deps


def build_router(service: ExampleService) -> APIRouter:
    """Build paths during registration, before runtime dependencies exist."""
    router = APIRouter(prefix="/api/extension-example", tags=["extension-example"])

    @router.get("/stats")
    async def read_stats(
        deps: ExtensionRuntimeDeps = Depends(service.require_deps),
    ) -> dict[str, Any]:
        ...
        return {
            "scope_id": deps.app_store.scope_id,
            "session_factory_available": deps.session_factory is not None,
            "host_policy": {"max_subagents_per_run": deps.policy.max_subagents_per_run},
            **_stats(deps.app_store).snapshot(),
        }

    return router
```

路由在 `install()` 期就构建好（路径拓扑固定），但每个 handler 通过
`Depends(service.require_deps)` 在请求期才解析运行时依赖——Gateway 未运行/未就绪时
统一返回 503。这就是 16.2.4 说的"注册期 vs 运行期"分离的标准实现。

宿主对路由还有几条硬约束（`backend/packages/harness/deerflow/extensions/AGENTS.md:383` 附近）：

- 挂载在**所有宿主路由之后**，同名路径宿主永远赢；冲突可被证明时整条路由**原子拒绝**；
- 贡献路由**强制走会话认证**，不能退出；要区分管理员用
  `deerflow_extension_api.auth.resolve_principal(request)` / `require_admin(request)`；
- `Mount`、WebSocket 路由、自定义 lifespan 一律拒绝——长生命周期资源必须放进
  `ExtensionService`。

### 16.3.6 打包清单：唯一的 entry point

`examples/deerflow-extension-example/pyproject.toml:14`：

```toml
[project.entry-points."deerflow.extensions"]
example = "deerflow_extension_example:install"
```

三条规则：

1. 必须放在 `deerflow.extensions` 组——管理器靠它发现扩展，且**只认恰好一个**入口；
2. 入口名 `example` 是操作员视角的稳定名字，`enable/disable/remove NAME=example` 用的
   就是它（也接受发行包名或 `module:install` 值）；
3. 依赖里**必须显式声明框架**——契约包没有 FastAPI/LangChain/LangGraph 依赖，本例自己
   声明了 `fastapi`、`langchain`、`langgraph`（`pyproject.toml:7-12`）。

## 16.4 源码走读 C：安装与管理——`ExtensionManager` 与 CLI

### 16.4.1 命令面

根 Makefile 的五个包装（`Makefile:122`–`Makefile:148`）：

```makefile
extension-install: export DEER_FLOW_EXTENSION_SOURCE := $(value SOURCE)
extension-install:
	$(if $(and $(filter command line,$(origin SOURCE)),...),,$(error usage: make extension-install SOURCE=<package|git-url|dir>))
	@cd backend && uv run --frozen --no-group extensions deerflow extensions install --source-env __deerflow_extension_source__
```

等价的直接 CLI（从 `backend/` 执行，见 `examples/deerflow-extension-example/README.md:150`）：

```text
uv run --frozen --no-group extensions deerflow extensions install <source> [--yes] [--required]
uv run --frozen --no-group extensions deerflow extensions list [--json]
uv run --frozen --no-group extensions deerflow extensions enable <name>
uv run --frozen --no-group extensions deerflow extensions disable <name>
uv run --frozen --no-group extensions deerflow extensions remove <name>
```

命令解析在 `backend/packages/harness/deerflow/extensions/cli.py:19`（`build_parser`），
主流程在 `cli.py:63`（`main`）。`install`/`upgrade` 在没有 `--yes` 时会先打印警告并
交互确认（`cli.py:72-80`）——因为扩展的构建钩子与运行时代码都以 Gateway 权限执行，
这是刻意的信任闸门。Makefile 包装用 `DEER_FLOW_EXTENSION_SOURCE` / `DEER_FLOW_EXTENSION_NAME`
环境变量传参（`cli.py:15-16`），并从 `backend/` 目录执行，所以**文档一律建议 SOURCE 用
绝对路径**。

### 16.4.2 install 的事务

`ExtensionManager.install`（`backend/packages/harness/deerflow/extensions/manager.py:168`）
是一次跨四个文件的受控事务。以本地目录安装为例，它按顺序做五件事：

1. **校验源与配置**：拒绝符号链接、路径逃逸的发行名、疑似凭证文件；校验 `config.yaml`
   可写（因为 `uv add` 会执行包的构建后端，配置必须先验证后执行）；
2. **快照**：把目录拷贝到 `backend/extensions/sources/<distribution>/`（本地安装是
   快照，不是可编辑链接——后续改源码要 `make extension-upgrade` 重新快照）；
3. **依赖事务**：执行
   `uv add --project <backend> --group extensions --no-workspace --no-sync -- <source>`
   （`manager.py:257`–`manager.py:262`），更新 `pyproject.toml` 的
   `[dependency-groups].extensions` 与 `uv.lock`，随后一次
   `uv sync --locked --all-packages`（`manager.py:1125`）落到环境；
4. **锁审计**：`uv add` 后审计新锁，凡 stock 后端镜像构建无法复现的本地引用
   （绝对路径、`file:` URL、越界相对路径）直接让整个事务失败并回滚；
5. **写回配置**：在 `config.yaml` 里插入或收编一条托管 `plugins:` 记录
   （`name/package/use/enabled/required/config`），新记录一律 `required: false`。

整个 checkout 上的所有变更共享一把跨进程锁 `.deer-flow/extension-manager.lock`
（`manager.py:546`），失败回滚会恢复 `pyproject.toml` 与 `uv.lock` 并重新同步环境。
`required: true` 是 `install --required` 的显式选项——它把"以后某次加载失败"升级成
"Gateway 启动中止"，默认的 fail-open（记录诊断并跳过）才是托管安装的默认。

### 16.4.3 为什么每次变更都要重启 Gateway

`create_app()` 在**构建应用时**一次性加载 `plugins:` 列表：导入入口模块、调用
`install()`、把不可变注册表存到 `app.state`、最后挂载贡献路由。加载只在启动时发生——
所以 install/upgrade/enable/disable/remove 以及手工改 `plugins:` 之后都必须重启
Gateway 才生效（`backend/packages/harness/deerflow/extensions/AGENTS.md:162` 附近：
"Every install, upgrade, enable, disable, remove, or config mutation also requires a
Gateway restart because plugin loading is startup-only"）。

## 16.5 源码走读 D：两条配置通道

### 16.5.1 operator 专属：`config.yaml → plugins:`

`config.example.yaml:3674`：

```yaml
# plugins:
#   - name: example                       # PEP 621 entry-point name
#     package: deerflow-extension-example # Python distribution managed by uv
#     use: deerflow_extension_example:install
#     enabled: true                       # false skips import and registration
#     required: false                     # true makes load failure abort Gateway startup
#     host_access:                        # optional host-owned grants (restart required)
#       ...（此处省略 evidence / skill_mutations 授权示例数行）
#       model_invocation:
#         roles:
#           default: my-configured-model
#         max_concurrency: 2
#     table_prefix: example_ext_          # optional: table-name prefix this extension owns
```

这条通道**会触发代码导入**，所以永远只留在 operator 手工控制的 `config.yaml`，绝不放进
API 可写的 `extensions_config.json`（根 `AGENTS.md` 与 `config.example.yaml:3664` 的
注释都反复强调这一点）。`config:` 之外的几个键值得认识：

- `host_access.model_invocation`：给扩展服务绑定一个宿主代理的模型调用器（并发/超时/
  输入输出字符上限都由宿主把关，见 `backend/docs/extension-model-invocation.md`）；
- `host_access.evidence` / `skill_mutations`：运行证据读取与技能变更授权（0.2.7 新增）；
- `table_prefix`：扩展自带 Alembic 迁移链时的表名前缀，避免 autogenerate 误删扩展的表。

### 16.5.2 API 可写：`extensions_config.json`

`extensions_config.example.json:1`：

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
      ...
```

四个顶层键：`middlewares`（配置声明的中间件类路径，等价于 `config.yaml → extensions.middlewares`
的固定槽位，见 `config.example.yaml:74`–`config.example.yaml:80`）、`mcpInterceptors`、
`mcpServers`（第 15 章的主角）、`skills`。这份文件 Gateway 可以通过 HTTP 端点在运行时
改写——因为它**不导入新代码**（中间件类路径除外，那条仍算受信 operator 配置）。

一句话记住边界：**`plugins:` = 装新代码，只进 `config.yaml`；`extensions_config.json` =
换配置，API 可写**。

### 16.5.3 宿主加载链路

`backend/packages/harness/deerflow/extensions/loader.py:160` 的 `load_extensions()` 把
`plugins:` 每条记录解析成 `ExtensionSpec`，做 API 版本兼容检查，然后导入入口并调用
`install()`，产出 `LoadedExtensions`（不可变快照）+ 诊断列表。诊断 fail-open：可选插件
加载失败只记录诊断；`required: true` 的插件加载失败则让 Gateway 构建直接失败。

## 16.6 官方示例全景：选对起点

`examples/README.md:6` 的选型表：

| 起点示例 | 演示内容 | 适合场景 |
| --- | --- | --- |
| `deerflow-extension-example` | 中间件、任务生命周期、模型观察、服务、HTTP 路由 | 后端扩展入门 |
| `deerflow-extension-bookmarks` | 浏览器页面 + 会话动作 + 后端 action + 打包资源 + 模型工具 | 全栈插件 |
| `deerflow-extension-agent-teams` | 完整 Agent 编排（团队任务队列、@提及中间件、产物捕获） | 熟悉基础模式之后 |
| `deerflow-extension-workflows` | 脚本工作流：多步 Agent 任务、审批、会话授权恢复（`AGENTS.md` 定义 AgentRuns 公共语义：POSIX、单进程/存储、审批、不确定 admissions 需对账、无多 Gateway 故障切换） | 持久化多步业务流 |
| `deerflow-extension-knowledge` | 合成只读知识提供者 | 知识检索接入 |
| `deerflow-extension-knowledge-{management,platform}` | 知识管理（各自带 scoped `AGENTS.md` 与 `CONTRACT.md`，管理契约是扩展自有、实验性的） | 企业知识库运营 |

### 16.6.1 全栈插件：bookmarks

`examples/deerflow-extension-bookmarks/deerflow_extension_bookmarks/__init__.py:139`：

```python
@extension(api="0.2.3", name="bookmarks")
def install(registry, config):
    enabled = config.get("enabled", False)
    if type(enabled) is not bool or not isinstance(config.get("storage_path"), str):
        raise ValueError(
            "Configure boolean enabled and an absolute storage_path at deployment"
        )
    store = Bookmarks(config["storage_path"])
    search = store.handler("search")
    if (
        registry.plugin(
            PluginContribution(
                namespace="community.bookmarks",
                title="会话书签 / Bookmarks",
                description="收藏有用的回答，在独立页面查找与整理。每位用户只访问自己的书签。",
                enabled=enabled,
                frontend=BrowserAssets("bookmarks.v1", Path(__file__).parent),
                backend=tuple(
                    BackendAction(name, store.handler(name))
                    for name in ("save", "search", "get", "rename", "delete")
                ),
                tools=(
                    ModelTool("search_bookmarks", "...", {...json-schema...}, search),
                ),
            )
        )
        is not True
    ):
        raise RuntimeError("This example requires the full-stack plugin host contract")
```

一条贡献装下三块：`frontend=BrowserAssets(...)`（由 `ui_manifest.json` 声明的原生 ES
模块与静态资源，见 `examples/deerflow-extension-bookmarks/deerflow_extension_bookmarks/ui_manifest.json:1`：

```json
{
  "schema_version": 1,
  "entry": "static/dist/index.mjs",
  "files": ["static/dist/index.mjs", "static/dist/chunks/bookmarks.mjs",
            "static/dist/styles.css", "static/dist/bookmark.svg"]
}
```

）、`backend=BackendAction(...)` 元组（浏览器经
`POST /api/plugins/{namespace}/actions/{name}` 调用，宿主注入已认证的
`ActionContext.principal`）、`tools=ModelTool(...)`（挂进模型工具面）。宿主对浏览器 JS
做哈希校验，action 强制认证，且**没有在线设置写 API**——代码可信但不沙箱，权限面是
白名单式的。每个 action 里那句"SQL 参数 + 每条数据操作强制 owner 谓词"是全栈插件的
多租户铁律。

### 16.6.2 知识提供者：一行注册

`examples/deerflow-extension-knowledge/deerflow_extension_knowledge/__init__.py:48`：

```python
@extension(api="0.2.7", name="knowledge-example")
def install(registry, config):
    if not registry.knowledge_provider("synthetic-example", SyntheticKnowledgeProvider()):
        raise RuntimeError("This host does not support knowledge provider registration")
```

Provider 声明 `KnowledgeCapabilities`（支持哪些只读操作：`search/sources/catalog/
documents/dataset_filter/document_filter`），可选实现 `search_scoped(query, context)`
接收宿主下发的范围选择。完整的契约语义（能力表、范围准入、引用证据）见
`backend/docs/KNOWLEDGE.md:12`；这正是第 17 章实战 A 的地基。

### 16.6.3 安装后的形态

按 `examples/deerflow-extension-example/README.md` 的流程，`make extension-install
SOURCE="$PWD/examples/deerflow-extension-example"` 会让 `config.yaml` 多出：

```yaml
plugins:
  - name: example
    package: deerflow-extension-example
    use: deerflow_extension_example:install
    enabled: true
    required: false
    config: {}
```

重启后 `curl -s http://localhost:2026/api/extension-example/stats` 就能拿到扩展路由的
聚合统计（该路由走 Gateway 正常认证中间件，启用认证时需已登录会话）。

## 16.7 动手实验：写一个"团队周报收集"扩展并走完生命周期

目标：从零写一个最小扩展（路由 + 服务 + 中间件 + 一条生命周期折叠），打包检查 → 安装 →
重启 → 验证 → 卸载，全程不碰核心代码。

### 第 1 步：创建包骨架

在 DeerFlow 仓库**之外**建目录（练习用，避免污染仓库）：

```
weekly-report-extension/
├── pyproject.toml
└── weekly_report_extension/
    ├── __init__.py
    └── plugin.py
```

`pyproject.toml`（对照 `examples/deerflow-extension-example/pyproject.toml`）：

```toml
[project]
name = "weekly-report-extension"
version = "0.1.0"
description = "Tutorial extension: in-memory weekly report collection"
requires-python = ">=3.12"
dependencies = [
    "deerflow-extension-api>=0.2,<0.3",
    "fastapi>=0.115.0,<1",
    "langchain>=1.3,<2",
]

[project.entry-points."deerflow.extensions"]
weekly-report = "weekly_report_extension:install"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["weekly_report_extension"]
```

`weekly_report_extension/__init__.py`：

```python
from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from deerflow_extension_api import ExtensionRegistry, extension

from weekly_report_extension.plugin import (
    WeeklyReportService,
    WeeklyToolCounterContributor,
    WeeklyToolLifecycle,
    build_router,
)

__all__ = ["install"]


@extension(api="0.2.0", name="weekly-report")
def install(registry: ExtensionRegistry, config: Mapping[str, Any]) -> None:
    if config.get("enabled", True) is False:
        return
    service = WeeklyReportService()
    registry.middlewares(WeeklyToolCounterContributor())
    registry.task_lifecycle(WeeklyToolLifecycle())
    registry.service(service)
    registry.routers((build_router(service),))
```

`weekly_report_extension/plugin.py`：

```python
from __future__ import annotations

from dataclasses import dataclass, field
from threading import Lock
from typing import Any

from deerflow_extension_api import (
    AgentScope,
    ExtensionData,
    ExtensionRuntimeDeps,
    MiddlewarePlacement,
    Placement,
    task_store_from_runtime,
)
from fastapi import APIRouter, Depends, HTTPException
from langchain.agents.middleware import AgentMiddleware
from langgraph.prebuilt.tool_node import ToolCallRequest


@dataclass
class WeeklyStats:
    """任务作用域的工具计数；run 结束时折叠进应用作用域。"""

    tool_calls: int = 0


@dataclass
class WeeklyReportData:
    """应用作用域：已提交的周报 + 汇总统计。"""

    reports: list[dict[str, Any]] = field(default_factory=list)
    runs_observed: int = 0
    tool_calls_observed: int = 0
    _lock: Lock = field(default_factory=Lock, repr=False, compare=False)


def _report_data(store: ExtensionData) -> WeeklyReportData:
    return store.get_or_init(WeeklyReportData, WeeklyReportData)


class WeeklyToolCounter(AgentMiddleware):
    def wrap_tool_call(self, request: ToolCallRequest, handler) -> Any:
        store = task_store_from_runtime(getattr(request, "runtime", None))
        if store is not None:
            stats = store.get_or_init(WeeklyStats, WeeklyStats)
            stats.tool_calls += 1
        return handler(request)

    async def awrap_tool_call(self, request: ToolCallRequest, handler) -> Any:
        store = task_store_from_runtime(getattr(request, "runtime", None))
        if store is not None:
            stats = store.get_or_init(WeeklyStats, WeeklyStats)
            stats.tool_calls += 1
        return await handler(request)


class WeeklyToolCounterContributor:
    def contribute_middlewares(self, app_store: ExtensionData, ctx) -> tuple:
        return (MiddlewarePlacement(WeeklyToolCounter(), Placement.STANDARD, AgentScope.BOTH),)


class WeeklyToolLifecycle:
    async def on_task_start(self, app_store: ExtensionData, task_store: ExtensionData, info) -> None:
        task_store.set(WeeklyStats())

    async def on_task_stop(self, app_store: ExtensionData, task_store: ExtensionData, info, outcome) -> None:
        stats = task_store.remove(WeeklyStats)
        if stats is None:
            return
        data = _report_data(app_store)
        with data._lock:
            data.runs_observed += 1
            data.tool_calls_observed += stats.tool_calls


class WeeklyReportService:
    def __init__(self) -> None:
        self._deps: ExtensionRuntimeDeps | None = None

    async def start(self, deps: ExtensionRuntimeDeps) -> None:
        self._deps = deps

    async def stop(self) -> None:
        self._deps = None

    def _store(self) -> ExtensionData:
        deps = self._deps
        if deps is None or deps.app_store is None:
            raise HTTPException(status_code=503, detail="weekly-report is not running")
        return deps.app_store


def build_router(service: WeeklyReportService) -> APIRouter:
    router = APIRouter(prefix="/api/weekly-report", tags=["weekly-report"])

    @router.get("/health")
    async def health() -> dict[str, bool]:
        return {"running": service._deps is not None}

    @router.get("/stats")
    async def stats() -> dict[str, Any]:
        data = _report_data(service._store())
        with data._lock:
            return {"runs_observed": data.runs_observed, "tool_calls_observed": data.tool_calls_observed}

    @router.get("/reports")
    async def list_reports() -> dict[str, Any]:
        data = _report_data(service._store())
        with data._lock:
            return {"reports": list(data.reports)}

    return router
```

### 第 2 步：本地测试 + 打包检查

```bash
cd weekly-report-extension
uv venv --python 3.12
uv pip install -e <deerflow-checkout>/backend/packages/extension-api
uv pip install -e .
uv run --no-project python -c "from weekly_report_extension import install; print('ok')"
```

再从 DeerFlow 检出根目录跑官方打包检查（`examples/README.md:31`）：

```bash
uv run --project backend --no-sync python scripts/check_extension.py /absolute/path/to/weekly-report-extension
```

它会构建 wheel、校验恰好一个 entry point、解析包内 Python 语法、确认 API 依赖范围
接受当前契约版本。

### 第 3 步：安装 → 重启 → 验证

```bash
cd <deerflow-checkout>
make extension-install SOURCE=/absolute/path/to/weekly-report-extension
# 出现信任提示，输入 y（或加 --yes 的 CLI 等价命令）
make extension-list
# NAME            STATE     PACKAGE                     ENTRY POINT
# weekly-report   enabled   weekly-report-extension     weekly_report_extension:install
```

此时 `config.yaml` 末尾多了一条托管 `plugins:` 记录，`backend/extensions/sources/weekly-report-extension/`
出现了快照，`backend/pyproject.toml` 的 `extensions` 依赖组与 `uv.lock` 已更新。
重启加载：

```bash
make dev        # 或 make stop && make start
```

验证三个贡献点：

```bash
# 1) 路由贡献点：健康检查
curl -s http://localhost:2026/api/weekly-report/health
# {"running":true}

# 2) 服务贡献点：未启动时会 503（启动后返回应用作用域数据）
curl -s http://localhost:2026/api/weekly-report/stats
# {"runs_observed":0,"tool_calls_observed":0}

# 3) 中间件贡献点：到 Web 界面随便发一轮会触发工具的消息（如"列出当前目录文件"），
#    让模型调用一次工具，然后再看统计
curl -s http://localhost:2026/api/weekly-report/stats
# {"runs_observed":1,"tool_calls_observed":3}
```

（启用认证的部署请用已登录的浏览器会话访问；贡献路由强制走会话认证，不能退出。）

### 第 4 步：禁用 → 卸载

```bash
make extension-disable NAME=weekly-report
make extension-list          # STATE 变为 disabled
make stop && make dev        # 重启后 /api/weekly-report/* 消失

make extension-remove NAME=weekly-report
make stop && make dev
make extension-list          # 列表为空；config.yaml/plugins 记录、快照与依赖组条目全部移除
```

## 16.8 常见坑

1. **改了源码不生效**。本地安装是**快照**（`backend/extensions/sources/`），不是可编辑
   链接。改完源码必须 `make extension-upgrade SOURCE=/absolute/path/to/your-extension`
   重新快照，然后重启 Gateway。只 restart 不 upgrade 也不行。
2. **改了 `plugins:` 不重启**。插件加载是 startup-only，enable/disable/install/remove
   与手工编辑配置后都必须重启；这是最高频的"配置不生效"问题。
3. **SOURCE 用了相对路径**。`make extension-*` 从 `backend/` 目录执行包装命令，相对路径
   会指错位置。文档与示例一律使用绝对路径（`examples/README.md:43` 的注记）。
4. **扩展里 `import deerflow` / `import app`**。契约包 `deerflow_extension_api` 是唯一
   允许的 DeerFlow 依赖；框架（FastAPI/LangChain/LangGraph）要在自己的 `pyproject.toml`
   里显式声明。导入宿主内部模块会把扩展绑死在某一个核心版本上，还可能触发循环导入。
5. **中间件按"列表下标"思维设计**。扩展贡献的是语义 `Placement`，且 `STANDARD` 与其他
   `STANDARD` 贡献的相对顺序**没有保证**；不要在共享基础 builder 里注入，`stack.py`
   才是最终组合点。观察型中间件要同步/异步成对实现，且必须透传异常（包括
   `CancelledError` 与 GraphInterrupt 控制流）。
6. **`required: true` 的使用**。托管安装默认写 `required: false`（加载失败 = 记诊断并
   跳过）。`--required` 会让以后任何一次加载失败（wheel 损坏、native 库缺失、快照被删）
   直接中止 Gateway 启动，且只能进 shell 恢复——除非业务缺了它就错，否则别开。

---

## 下一步

扩展系统解决了"把业务装进平台"的机制问题；下一章我们把视角切换到真实业务，用五个
端到端案例演练**需求分流决策树**——什么该做成 Skill、什么走 MCP、什么做扩展、什么
才值得改核心。请继续阅读 [17-business-cases.md](17-business-cases.md)（第 17 章 业务
二次开发实战），其后的第 18 章将转向前端二次开发。
