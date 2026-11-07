# 第 14 章 架构分层与开发规范（二次开发前必读）

> 精通篇从本章开始。前两篇你一直在"用"DeerFlow；从本章起你要"改"它。改代码之前
> 必须先回答三个问题：代码分几层、依赖朝哪边流、CI 用什么门禁拦住违规改动。
> 本章用真实源码回答：Harness/App 两条层的单向依赖（CI 强制）、第三层契约包
> `deerflow-extension-api`、TDD/分片测试/Alembic 迁移的工程规范，以及包根懒加载
> 的导入纪律。读完再动手，你会少踩 90% 的"改一行、CI 全红"的坑。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 分层总览 | `docs/ARCHITECTURE.md` §3、`backend/AGENTS.md`（Harness / App Split 节） |
| 边界 CI 门禁 | `backend/tests/test_harness_boundary.py`（47 行，精读） |
| 契约包 | `backend/packages/extension-api/deerflow_extension_api/__init__.py` |
| 契约包元数据 | `backend/packages/extension-api/pyproject.toml` |
| Harness 包元数据 | `backend/packages/harness/pyproject.toml` |
| App 包元数据 / uv workspace | `backend/pyproject.toml` |
| 懒加载包根 ① | `backend/packages/harness/deerflow/agents/__init__.py` |
| 懒加载包根 ② | `backend/packages/harness/deerflow/subagents/__init__.py` |
| 后端命令 | `backend/Makefile` |
| 测试布局 | `backend/tests/`（约 1340 个文件）+ `backend/tests/conftest.py` |
| 迁移示例 | `backend/packages/harness/deerflow/persistence/migrations/versions/0047_mcp_oauth_tokens.py` |
| 导入约定（权威） | `backend/AGENTS.md` "Import conventions" 与 "Package import hygiene" 节 |

## 14.0 学习目标

读完本章，你应该能够：

1. 画出后端三层结构（`app.*` → `deerflow.*` ← `deerflow_extension_api.*`）并解释
   每一层的发布属性：谁是可发布框架、谁是 unpublished 应用、谁是宿主无关契约；
2. 说清 `test_harness_boundary.py` 如何用 AST 扫描在 CI 里强制"Harness 永不
   `import app`"，以及违规 import 长什么样、报错长什么样；
3. 遵守工程规范跑通一个完整后端改动闭环：TDD 写测试 → `make test` 四分片 →
   `make test-blocking-io` Blockbuster 门禁 → `make migrate-rev` 生成迁移；
4. 解释 `deerflow.agents` / `deerflow.subagents` 包根为什么必须懒加载，写出
   "轻量导入"风格的内部模块 import；
5. 独立完成一次"harness 内定位一处中间件 + 跑绿全部门禁"的演练（动手实验）。

## 14.1 概念讲解：三层结构与依赖方向

### 14.1.1 两层主干 + 一层契约

`docs/ARCHITECTURE.md` §3 给出主干规则：

> **Harness**（`backend/packages/harness/deerflow/`，import 前缀 `deerflow.*`）——
> 可发布的 agent 框架：编排、工具、沙箱、模型、MCP、技能、记忆、配置，即"构建和
> 运行 agent 所需的一切"。
> **App**（`backend/app/`，import 前缀 `app.*`）——unpublished 应用代码：FastAPI
> Gateway 与 IM 渠道集成。

在这两层之间还有一个"第三层"：`deerflow-extension-api`
（`backend/packages/extension-api/`），它定义与宿主无关的扩展契约。三者的依赖
关系是严格单向的：

```
        app.*  ──import──▶  deerflow.*  ◀──import──  扩展(extension)代码
          │                     ▲                        │
          └──import──▶ deerflow_extension_api ◀──import──┘
                    （deerflow 宿主实现这份契约，
                      契约包自己谁也不 import）
```

三个关键性质，每个都有源码证据：

- **App 可以 import Harness**：`backend/pyproject.toml:8` 把
  `deerflow-harness` 声明为 `deer-flow` 的第一个运行时依赖。
- **Harness 永不 import App**：这是 CI 强制规则（下一节精读测试）。
- **契约包不 import 任何人**：`backend/packages/extension-api/pyproject.toml:8`
  的 `dependencies = []`——它连 `deerflow` 都不依赖（14.2 节精读）。

### 14.1.2 为什么要分层

一句话：**框架要能独立发布，应用才有自由重构的权利**。

- `deerflow-harness` 是 `backend/packages/harness/pyproject.toml:1-4` 里一个
  正式的 PyPI 风格包（name `deerflow-harness`，version `2.3.0-dev`）。它可以被
  任何第三方项目 `uv add deerflow-harness` 后单独用来构建 agent——不需要 Gateway、
  不需要 IM 渠道。`backend/pyproject.toml:114-119` 把两个包登记进 uv workspace：

  ```toml
  [tool.uv.workspace]
  members = ["packages/harness", "packages/extension-api"]

  [tool.uv.sources]
  deerflow-harness = { workspace = true }
  deerflow-extension-api = { workspace = true }
  ```

  （`backend/pyproject.toml:114-119`）workspace 内源码引用让 monorepo 开发时
  三个包共享同一份源码，发布时又能各自独立出包。

- `app.*` 里的 Gateway 拼装了 FastAPI 路由、IM 渠道、调度器等"部署形态"的代码。
  这一层**不发布**。把产品逻辑写进 `deerflow.*` 会让框架背上产品包袱；写进
  `app.*` 又无法被其他 DeerFlow 复用——所以有了第三层的扩展契约：平台能力
  （第 16 章的扩展系统）通过 `deerflow_extension_api` 的稳定接口注入，实现
  代码住在扩展包里，宿主与扩展可以分别演进。

### 14.1.3 依赖方向的正反例（import 约定）

`backend/AGENTS.md` "Import conventions" 节（`backend/AGENTS.md:159-173`）给出
权威示例，逐条对照源码：

**正确写法 ①：Harness 内部互相引用**

```python
# Harness internal
from deerflow.agents import make_lead_agent
from deerflow.models import create_chat_model
```

**正确写法 ②：App 内部互相引用**

```python
# App internal
from app.gateway.app import app
from app.channels.service import start_channel_service
```

**正确写法 ③：App → Harness（唯一允许的跨层方向）**

```python
# App → Harness (allowed)
from deerflow.config import get_app_config
```

真实例子随手可查：Gateway 的服务层取配置就是这条路径（第 13 章里
`start_run` 读 `get_app_config()` 即属此类）。

**错误写法：Harness → App（CI 直接拒绝）**

```python
# Harness → App (FORBIDDEN — enforced by test_harness_boundary.py)
# from app.gateway.routers.uploads import ...  # ← will fail CI
```

假设你想在 harness 的某个工具里"顺手"调 Gateway 的上传路由——这个 import 一旦
落盘，`make test`（本地）与 CI（远端）都会在 `test_harness_boundary.py` 失败，
报错信息会把违规文件与行号列出来（见下一节摘录）。正确的改法是把需要的能力
抽象成 harness 内的接口，或走扩展契约注入（第 16 章）。

还有一条容易被忽略的**反向纪律**：契约包不 import 宿主。`deerflow_extension_api`
的模块里找不到任何 `from deerflow...`——如果扩展作者在契约层"借"了宿主的实现，
契约包的独立性就名存实亡。

## 14.2 源码走读：边界如何被 CI 强制

### 14.2.1 精读 `test_harness_boundary.py`

整个测试只有 47 行，没有 mock、没有网络、没有 fixture——它就是一次纯静态的
AST 扫描。先看扫描范围与禁用前缀（`backend/tests/test_harness_boundary.py:13-16`）：

```python
HARNESS_ROOT = Path(__file__).parent.parent / "packages" / "harness" / "deerflow"

BANNED_PREFIXES = ("app.",)
```

`HARNESS_ROOT` 从测试文件位置反推出 `packages/harness/deerflow`，即 Harness 层
的完整源码树；`BANNED_PREFIXES` 目前只有一个成员 `"app."`。注意元组的设计：
未来若出现新的禁用方向（比如禁止契约包 import 宿主），加一个前缀即可。

收集 import 的函数把源码解析成 AST，遍历两种节点（`backend/tests/test_harness_boundary.py:18-34`）：

```python
def _collect_imports(filepath: Path) -> list[tuple[int, str]]:
    """Return (line_number, module_path) for every import in *filepath*."""
    source = filepath.read_text(encoding="utf-8")
    try:
        tree = ast.parse(source, filename=str(filepath))
    except SyntaxError:
        return []

    results: list[tuple[int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                results.append((node.lineno, alias.name))
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                results.append((node.lineno, node.module))
    return results
```

三个细节值得学：

1. **`ast.parse` 而不是正则**——`from app import x`、`import app.gateway`、
   字符串拼接的动态 import（`importlib.import_module("app.x")` 除外）都能被
   语法层面覆盖，注释里的假 import 不会误报；
2. **同时覆盖 `ast.Import` 与 `ast.ImportFrom`**——`import app.gateway.routers`
   和 `from app.gateway.routers import x` 是两种不同的 AST 节点；
3. **SyntaxError 静默跳过**——边界测试不为语法错误负责，那是 ruff 的职责，
   分层测试保持单一职责。

断言本体在 `backend/tests/test_harness_boundary.py:37-46`：

```python
def test_harness_does_not_import_app():
    violations: list[str] = []

    for py_file in sorted(HARNESS_ROOT.rglob("*.py")):
        for lineno, module in _collect_imports(py_file):
            if any(module == prefix.rstrip(".") or module.startswith(prefix) for prefix in BANNED_PREFIXES):
                rel = py_file.relative_to(HARNESS_ROOT.parent.parent.parent)
                violations.append(f"  {rel}:{lineno}  imports {module}")

    assert not violations, "Harness layer must not import from app layer:\n" + "\n".join(violations)
```

- `rglob("*.py")` 扫到 Harness 的每一个 Python 文件（包括子包），`sorted()`
  保证报错顺序稳定、diff 可读；
- 匹配规则是 `module == prefix.rstrip(".") or module.startswith(prefix)`——
  两个分支分别捕获 `import app`（裸模块名，`module == "app"`）与
  `import app.gateway.routers`（子模块，`startswith("app.")`）两种形态，
  都拦；
- 失败消息逐行列出 `相对路径:行号 imports 模块`，你 push 之后在 CI 日志里
  能直接定位到行。

> 注意这个测试跑在 `backend/tests/` 里，属于四分片离线套件的一员——它不需要
> 任何运行时环境，几毫秒完成。**边界是"测试"而不是 lint 插件**是有意为之：
> ruff 的规则是风格约束，这个测试是架构约束，放在 pytest 里意味着它和功能
> 测试一起跑，绕不过去。

### 14.2.2 第三层契约包：`deerflow-extension-api`

打开 `backend/packages/extension-api/deerflow_extension_api/__init__.py:1-6`，
包级 docstring 把规则写在第一行：

```python
"""Public contracts for DeerFlow extensions.

This package MUST NOT import `deerflow`. Every host contract an extension
needs lives here, while framework imports remain direct extension dependencies;
extensions can therefore be released independently of the host.
"""
```

"This package MUST NOT import `deerflow`" —— 契约包的独立性是**文档声明的
不变量**（第 14.1.3 节的"反向纪律"）。文件随后用 100 余行 re-export 列出全部
公开契约（`backend/packages/extension-api/deerflow_extension_api/__init__.py:10-101`）：
`ExtensionRegistry` / `ExtensionService` / `MiddlewareContributor` /
`TaskLifecycleContributor` / `SystemModelRequest`…… 这些名字是第 16 章扩展
开发时的完整词汇表。版本号管理在第 103-105 行：

```python
#: Contract version. Before 1.0, minors may break and patches are additive.
#: From 1.0 on, bump the major for breaking changes.
API_VERSION = "0.2.11"
```

1.0 之前 minor 可破坏、patch 只做增量——宿主与扩展的兼容性由此协商。
Harness 侧对这份契约用**精确 pin**（`backend/packages/harness/pyproject.toml:12-16`）：

```toml
# Exact pin by design (extension-system version contract): the host pins
# the contract version it implements, extensions declare ranges. A range
# here would let pip resolve a newer contract package than this harness
# implements, making newer extensions look supported at runtime.
"deerflow-extension-api==0.2.11",
```

注释解释了 pin 的理由：**宿主钉死它实现的契约版本，扩展声明范围**。如果宿主
声明范围，pip 可能解析出比宿主实现更新的契约包，让"新扩展"在运行时才炸出
"宿主不认识这个接口"。

契约包自身的 `backend/packages/extension-api/pyproject.toml:6-8` 则用空依赖
兑现了 docstring 的承诺：

```toml
# Keep the contract package import-light and independent from the host. Public
# values are stdlib-based; concrete middleware types are validated by DeerFlow.
dependencies = []
```

零依赖意味着"import 这个包不会有任何传递安装"，扩展作者可以放心把它作为
自己包的轻量依赖。

App 层对契约包也显式声明依赖，`backend/pyproject.toml:9-15` 的注释同样值得
精读（这是本仓库注释文化的代表）：

```toml
    # Direct dependency on purpose, even though deerflow-harness already pulls
    # it in: app/gateway/app.py and app/gateway/services.py import the public
    # contract package themselves (the extension principal resolver, and the
    # provenance key set the state route strips). Those are the app layer's own
    # imports of a package whose whole point is a stable public surface, so the
    # app declares them rather than relying on the harness to keep supplying it.
    "deerflow-extension-api",
```

"自己 import 的包自己声明，而不是搭 Harness 传递依赖的便车"——否则哪天
Harness 内部不再 import 契约包，App 会无声地丢依赖。

### 14.2.3 版本锁步

三个包的版本由仓库级约定锁步（根 `AGENTS.md` "Version lockstep" 节）：
`backend/pyproject.toml:3`（`2.3.0-dev`）、`backend/packages/harness/pyproject.toml:3`
（`2.3.0-dev`）、`frontend/package.json` 的 `version` 字段（`2.3.0-dev`）、
`deploy/helm/deer-flow/Chart.yaml` 的 `version`/`appVersion`（均为
`2.3.0-dev`）四处必须一致，`backend/uv.lock` 必须同步。改版本统一用
`scripts/bump_version.sh <ver>`，`v*` tag 的 CI 会跑 `scripts/verify_versions.sh`
阻断漂移。手改其中一处版本号是新人最常见的 CI 红灯来源之一。

## 14.3 源码走读：轻量导入纪律

### 14.3.1 问题：包根 import 会引爆依赖图

`deerflow.agents` 和 `deerflow.subagents` 是 Harness 里两个"重灾区"：
`agents` 包根连接着 lead agent 的整张工具图（进而拖出沙箱、MCP、技能……），
`subagents` 包根连接着子代理执行器。如果包根 `__init__.py` 把它们 eager import，
那么任何"只想读一个轻量类型"的模块（例如运行时配置类）都会连锁拉起整张依赖图。
`backend/AGENTS.md` "Package import hygiene" 节
（`backend/AGENTS.md:175-183`）总结了这条纪律：

> the `deerflow.agents` and `deerflow.subagents` package roots expose
> heavyweight graph/executor entrypoints lazily. The
> `deerflow.agents:make_lead_agent` LangGraph Server entrypoint is a concrete
> thin module-level function because the server resolves graph factories
> directly from the module dictionary; the wrapper keeps the lead-agent and
> skill-cache imports inside the function so importing the package remains
> lightweight. Internal modules that only need lightweight types, config, or
> registries should import the concrete submodule instead of adding eager
> package-root imports that pull in the tool graph or subagent executor during
> state/schema imports.

### 14.3.2 精读 `agents/__init__.py`

`backend/packages/harness/deerflow/agents/__init__.py:20-31`：

```python
def make_lead_agent(config: "RunnableConfig") -> Any:
    """Build the lead graph while keeping package-root imports lightweight.

    LangGraph Server resolves configured graph factories directly from a
    module's ``__dict__``, so this entrypoint must be a concrete module-level
    function rather than a value supplied only through ``__getattr__``.
    """
    from .lead_agent import make_lead_agent as factory
    from .lead_agent.prompt import prime_enabled_skills_cache

    prime_enabled_skills_cache()
    return factory(config)
```

两层设计意图：

1. **函数体内部 import**——`lead_agent`（以及它拖出的整张工具图）只在真正
   构建 lead agent 的那一刻才被加载；`import deerflow.agents` 本身是廉价的。
2. **为什么不能全用 `__getattr__` 懒加载**——docstring 写明：LangGraph Server
   解析 graph factory 时是**直接查模块 `__dict__`**，`__getattr__` 只在属性
   访问路径上生效，Server 的工厂查找不会触发它。所以 `make_lead_agent` 必须
   是一个真实的模块级函数（薄壳），内部再做懒 import。这是"懒加载纪律"与
   "外部框架解析约定"的折中，值得记住：**懒加载不是无脑全懒，要尊重消费方
   的发现机制**。

其余重符号走 `__getattr__`（`backend/packages/harness/deerflow/agents/__init__.py:34-50`）：

```python
def __getattr__(name: str):
    if name == "create_deerflow_agent":
        from .factory import create_deerflow_agent

        globals()[name] = create_deerflow_agent
        return create_deerflow_agent
    if name in {"DeltaThreadState", "SandboxState", "ThreadState"}:
        from .thread_state import DeltaThreadState, SandboxState, ThreadState

        exports = {
            "DeltaThreadState": DeltaThreadState,
            "SandboxState": SandboxState,
            "ThreadState": ThreadState,
        }
        globals().update(exports)
        return exports[name]
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
```

注意 `globals().update(exports)` 这一行：首次懒加载后把符号写回模块字典，
后续访问不再走 `__getattr__` 分支——一次付费，之后免费。

### 14.3.3 精读 `subagents/__init__.py`

同样的模式在 `backend/packages/harness/deerflow/subagents/__init__.py:1-12`
先给出一个反差：**轻量符号是 eager 的**——

```python
from .config import SubagentConfig
from .registry import get_available_subagent_names, get_subagent_config, list_subagents

__all__ = [
    "SubagentConfig",
    "SubagentExecutor",
    "SubagentResult",
    "SubagentRuntime",
    "get_available_subagent_names",
    "get_subagent_config",
    "list_subagents",
]
```

`config`（Pydantic 配置模型）和 `registry`（名字注册表）是轻量模块，eager
import 无伤大雅；`__all__` 里的 `SubagentExecutor` / `SubagentResult` /
`SubagentRuntime` 才是重量级，走懒加载（`backend/packages/harness/deerflow/subagents/__init__.py:15-30`）：

```python
def __getattr__(name: str):
    if name in {"SubagentExecutor", "SubagentResult"}:
        from .executor import SubagentExecutor, SubagentResult

        exports = {
            "SubagentExecutor": SubagentExecutor,
            "SubagentResult": SubagentResult,
        }
        globals().update(exports)
        return exports[name]
    if name == "SubagentRuntime":
        from .runtime import SubagentRuntime

        globals()[name] = SubagentRuntime
        return SubagentRuntime
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
```

### 14.3.4 写代码时怎么遵守

- **内部模块**只依赖轻量类型/配置/注册表时，直接 import 具体子模块
  （`from deerflow.subagents.config import SubagentConfig`），不要通过包根
  拉执行器；
- **循环导入的自救**：如果确实无法避免生产代码里的循环链，测试侧可以在
  `backend/tests/conftest.py` 注入 `sys.modules` mock。仓库里现成的例子
  （`backend/tests/conftest.py:21-40`）把这条链注释得一清二楚：

  ```python
  # Break the circular import chain that exists in production code:
  #   deerflow.subagents.__init__
  #     -> .executor (SubagentExecutor, SubagentResult)
  #       -> deerflow.agents.thread_state
  #         -> deerflow.agents.__init__
  #           -> lead_agent.agent
  #             -> subagent_limit_middleware
  #               -> deerflow.subagents.executor  <-- circular!
  #
  # By injecting a mock for deerflow.subagents.executor *before* any test module
  # triggers the import, __init__.py's "from .executor import ..." succeeds
  # immediately without running the real executor module.
  _executor_mock = MagicMock()
  _executor_mock.SubagentExecutor = MagicMock
  _executor_mock.SubagentResult = MagicMock
  _executor_mock.SubagentStatus = MagicMock
  _executor_mock.MAX_CONCURRENT_SUBAGENTS = 3
  _executor_mock.get_background_task_result = MagicMock()

  sys.modules["deerflow.subagents.executor"] = _executor_mock
  ```

  注意顺序：mock 必须在任何测试模块触发真实 import **之前**注入——conftest
  在收集阶段执行，正好满足这个时机。`backend/AGENTS.md:224` 明确说：轻量
  配置/工具模块遇到循环导入问题时，照这个现有例子加 `sys.modules` mock。

## 14.4 源码走读：TDD 门禁与测试布局

### 14.4.1 测试目录全景

`backend/tests/` 约 1340 个文件，布局规则（`backend/AGENTS.md` TDD 节 +
目录实况）：

| 位置 | 内容 | 运行方式 |
| --- | --- | --- |
| `backend/tests/test_<feature>.py` | 常规单元/集成测试（默认离线） | `make test` 四分片 |
| `backend/tests/blocking_io/` | Blockbuster 严格门禁套件（阻塞 I/O 检测） | `make test-blocking-io` |
| `backend/tests/fixtures/`、`conftest.py`、`_*.py` 辅助模块 | 共享 fixture 与 helper | 被上述两者引用 |
| 标记 `live` 的测试 | 真实外部 API，需 `DEER_FLOW_RUN_LIVE_TESTS=1` 显式开启 | `make test-live` |

`backend/pyproject.toml:86-92` 用 pytest markers 固化了这套语言：

```toml
[tool.pytest.ini_options]
markers = [
    "no_auto_user: disable the conftest autouse contextvar fixture for this test",
    "allow_blocking_io: opt out of the strict Blockbuster gate in tests/blocking_io/",
    "integration: tests that require an external service (e.g. Redis); skipped when unavailable",
    "live: tests that call real external APIs and require explicit opt-in",
]
```

### 14.4.2 精读 `backend/Makefile` 的测试 target

TDD 是**强制**的（`backend/AGENTS.md:216-222`："Every new feature or bug fix
MUST be accompanied by unit tests. No exceptions."）。落地命令在
`backend/Makefile:22-36`：

```makefile
# Run all four duration-balanced shards locally; wait for every shard on failure.
TEST_JOBS ?= 4
TEST_SHARD_TARGETS := test-shard-1 test-shard-2 test-shard-3 test-shard-4
.PHONY: test test-shard $(TEST_SHARD_TARGETS)
test:
	$(MAKE) --no-print-directory -k -j$(TEST_JOBS) $(TEST_SHARD_TARGETS)

$(TEST_SHARD_TARGETS):
	$(MAKE) --no-print-directory test-shard SPLITS=4 GROUP=$(patsubst test-shard-%,%,$@)

test-live:
	DEER_FLOW_RUN_LIVE_TESTS=1 PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest -m live tests/ -v -s

test-blocking-io:
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest tests/blocking_io -q --tb=short
```

三个看点：

1. **四分片并行**——`make test` 用 `-j4` 同时跑四个 `test-shard-N`，分片不是
   按目录切，而是**按时长均衡**；
2. **时长基线文件**——`backend/Makefile:46-52` 的 `test-shard`：

   ```makefile
   SPLITS ?= 1
   GROUP ?= 1
   DURATIONS_FILE ?= .test_durations
   test-shard:
   	@test -f "$(DURATIONS_FILE)" || \
   		(echo "error: $(DURATIONS_FILE) is missing; run 'make test-shard-durations' to regenerate the duration baseline" >&2; exit 1)
   	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest -m "not live" --ignore=tests/blocking_io --splits $(SPLITS) --group $(GROUP) --splitting-algorithm least_duration --durations-path=$(DURATIONS_FILE) tests/ -q
   ```

   pytest-split 按 `.test_durations` 里记录的真实耗时做 `least_duration`
   分桶；文件缺失直接报错（而不是退化成不分片），避免 CI 分片意外失衡。
   刷新基线用 `make test-shard-durations`（`backend/Makefile:57-58`），它会
   `--store-durations --clean-durations` 重测全量离线套件。
3. **两套门禁都要跑**——提交前 `make test` + `make test-blocking-io` 一起过
   （`backend/AGENTS.md:222`）。`tests/blocking_io/` 里跑的是 Blockbuster：
   事件循环上出现未授权的阻塞 I/O（同步文件、同步网络）直接判红。第 15 章
   会看到 `tests/blocking_io/test_mcp_oauth_token_store.py` 这样的成对回归。

代码风格同样有门禁：ruff，行宽 240（`backend/AGENTS.md` Code Style 节，
"Line length: 240 characters"）；`backend/Makefile:60-62` 的 `lint` 同时跑
`ruff check` 与 `ruff format --check`，CI 后者强制。

### 14.4.3 数据库迁移：`make migrate-rev` 与一个真实迁移

迁移系统是 Alembic，目录在 Harness 侧：
`backend/packages/harness/deerflow/persistence/migrations/`。`backend/Makefile:77-79`：

```makefile
migrate-rev:
	@if [ -z "$(MSG)" ]; then echo 'usage: make migrate-rev MSG="describe the change"'; exit 1; fi
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run python scripts/_autogen_revision.py "$(MSG)"
```

`backend/Makefile:70-76` 的注释解释了为什么**没有** `make migrate` / 
`migrate-stash` 之类的 target：Gateway 启动时通过 `bootstrap_schema` 自动
`alembic upgrade head`——唯一执行路径，把运维失误挡在门外。自动生成的算法
是"先在一个临时 SQLite 上升到 head，再把 live ORM 模型与它做 diff"，所以
干净 checkout（没有现成 `./data/deerflow.db`）也能用。

一个真实的版本文件长什么样？看 `backend/packages/harness/deerflow/persistence/migrations/versions/0047_mcp_oauth_tokens.py:32-41`（这张表正是第 15 章
MCP OAuth token 存储的底座，此处先看迁移结构）：

```python
revision: str = "0047_mcp_oauth_tokens"
down_revision: str | Sequence[str] | None = "0046_skill_mutations"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_TABLE = "mcp_oauth_tokens"


def _has_table() -> bool:
    return sa.inspect(op.get_bind()).has_table(_TABLE)
```

`revision` / `down_revision` 组成链表——这就是"为什么迁移文件不能重命名、
不能跳号"的原因。再看它的幂等守卫（`0047_mcp_oauth_tokens.py:44-47`）：

```python
def upgrade() -> None:
    if _has_table():
        return
    op.create_table(
```

docstring（`0047_mcp_oauth_tokens.py:18-23`）解释了守卫的必要性：升级时如果
表已存在（早前中断的尝试，或空库 bootstrap 已跑过 `create_all`），直接完成；
降级时如果表已消失，也要继续移动版本行。**迁移必须可在任意中间状态下重放**
——这是多实例部署（第 20 章）的地基。

## 14.5 动手实验：定位一处中间件并跑通全部门禁

目标：在 Harness 中找到并读懂一个真实中间件，然后体验完整的改动闭环。
全程离线，约 15 分钟。

**步骤 1：定位中间件。** 第 6 章见过 `ClarificationMiddleware` 在中间件链的
位置。它住在 Harness：

```bash
cd backend
grep -rn "class ClarificationMiddleware" packages/harness/deerflow/
# → packages/harness/deerflow/agents/middlewares/clarification_middleware.py:75
```

读 `clarification_middleware.py` 的类定义与其 `AgentMiddleware` 基类用法，
确认它只 import 了 `deerflow.*` 与第三方库——没有任何 `from app...`。

**步骤 2：验证边界测试只扫静态结构（跑一次它）。**

```bash
cd backend
uv run pytest tests/test_harness_boundary.py -v
# → test_harness_does_not_import_app PASSED
```

**步骤 3：制造一次违规，观察 CI 门的报错（在本地复现）。**
随便在 `clarification_middleware.py` 顶部加一行
`from app.gateway import app  # boundary demo, will remove`，再跑：

```bash
uv run pytest tests/test_harness_boundary.py -v
# FAILED — Harness layer must not import from app layer:
#   packages/harness/deerflow/agents/middlewares/clarification_middleware.py:1  imports app.gateway.app
```

报错精确到文件与行号——这正是将来 push 后 CI 给你的反馈。**删掉这行**，
确认恢复绿色。

**步骤 4：跑全量门禁（体会时长与分片）。**

```bash
cd backend
make test                 # 四分片并行；首次运行若缺 .test_durations 先跑步骤 5
make test-blocking-io     # Blockbuster 套件
make lint                 # ruff check + ruff format --check
```

**步骤 5（可选）：刷新时长基线。** 如果 `make test` 报
`.test_durations is missing`，执行 `make test-shard-durations` 生成基线后再
跑 `make test`。注意基线文件是提交进仓库的——不要顺手改了它内容。

**验收标准**：`make test`、`make test-blocking-io`、`make lint` 全绿；
你能口头说出 `ClarificationMiddleware` 所在文件、它在中间件链中的位置、
以及是谁保证它永远不会 `import app`。

## 常见坑

1. **把产品逻辑写进 Harness**。症状：harness 模块里出现了 `app.gateway`、
   `app.channels` 的 import 或对 Gateway 单例的引用。CI 红灯
   （`test_harness_boundary.py`）。正确姿势：抽象进 harness 接口、走
   `deerflow_extension_api` 契约注入（第 16 章），或直接放 `app.*`。
2. **改了版本号但只改一处**。`backend/pyproject.toml`、
   `backend/packages/harness/pyproject.toml`、`frontend/package.json`、
   `deploy/helm/deer-flow/Chart.yaml`（`version` 与 `appVersion`）四处 +
   `backend/uv.lock` 必须一致。手改必然漂移，用 `scripts/bump_version.sh <ver>`，
   验证用 `scripts/verify_versions.sh <ver>`。
3. **绕过 `make test` 直接跑单个 pytest**。四分片的意义是均衡 CI 时长；
   本地可以用 `uv run pytest tests/test_xxx.py -q` 快速迭代单文件，但提交前
   必须跑完整 `make test` + `make test-blocking-io`。缺
   `.test_durations` 时 `make test-shard` 会直接报错——先跑
   `make test-shard-durations`。
4. **在轻量模块里加包根 eager import**。`from deerflow.agents import ...`
   出现在配置/状态模块顶部会拉起整张工具图，测试里还可能触发循环导入
   （conftest 里那条注释链）。写"轻量导入"风格：直接 import 具体子模块，
   重符号延迟到函数体内。
5. **手写 Alembic 迁移不写幂等守卫**。迁移会在多实例、中断重放、
   空库 bootstrap 等各种中间状态下执行。照 `0047_mcp_oauth_tokens.py` 的
   样子：升级前 `_has_table()` 探测、降级同样探测；列级守卫用现成的
   `migrations/_helpers.py`。迁移文件一旦合入不要重命名——`revision` 链表
   会断。
6. **忘记 App 层"自己 import 的包自己声明"**。如果你在 `app.*` 新增了对
   `deerflow-extension-api`（或任何传递依赖）的直接 import，记得同步加进
   `backend/pyproject.toml` 的 `dependencies`——否则 Harness 侧重构传递
   依赖时会无声破坏 App。这个纪律的成文理由见 `backend/pyproject.toml:9-15`
   的注释。

## 下一步

分层与规范就位后，接下来是精通篇的重头戏：**MCP 集成**——DeerFlow 如何把
外部系统工具化、如何用进程隔离的 MCP server 扩展 agent 能力、以及第 15 章
动手"接入 GitHub MCP server + 自建 stdio MCP server"的两个实验。见
《第 15 章 MCP 集成》（`docs/tutorials/15-mcp.md`）；第 15 章之后的第 16 章
（`docs/tutorials/16-extensions.md`）再把本章的契约包落到扩展开发实战。
