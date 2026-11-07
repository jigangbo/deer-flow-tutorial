# 第 8 章 沙箱与代码执行

> 进阶篇第 3 章。第 7 章我们看到了工具三来源里的 `bash`、`read_file`、`write_file`、
> `str_replace`、`ls`、`glob`、`grep`——这一组"文件与命令"工具全部跑在一个统一抽象
> **Sandbox** 之上。Agent 眼里的世界是 `/mnt/user-data/...` 这样的虚拟路径，而真实字节
> 落在 `backend/.deer-flow/users/{user_id}/threads/{thread_id}/user-data/...` 的线程目录里；
> 开发模式下它是宿主机的直接子进程，生产模式下它是 Docker 容器甚至 K8s Pod。
> 这一章拆解这条"虚拟路径 → Provider → 真实执行环境"的完整链路。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 沙箱模块总纲 | `backend/packages/harness/deerflow/sandbox/AGENTS.md` |
| Provider 抽象与单例 | `backend/packages/harness/deerflow/sandbox/sandbox_provider.py:17`、`sandbox_provider.py:222` |
| Sandbox 接口契约 | `backend/packages/harness/deerflow/sandbox/sandbox.py:45` |
| 执行租约 | `backend/packages/harness/deerflow/sandbox/lease.py:180` |
| Local Provider | `backend/packages/harness/deerflow/sandbox/local/local_sandbox_provider.py:36` |
| Local Sandbox 实现 | `backend/packages/harness/deerflow/sandbox/local/local_sandbox.py:331` |
| AIO Provider（Docker） | `backend/packages/harness/deerflow/community/aio_sandbox/aio_sandbox_provider.py` |
| AIO Sandbox 实现 | `backend/packages/harness/deerflow/community/aio_sandbox/aio_sandbox.py` |
| 沙箱中间件 | `backend/packages/harness/deerflow/sandbox/middleware.py:56` |
| 环境变量策略 | `backend/packages/harness/deerflow/sandbox/env_policy.py:108` |
| 命令范围（取消） | `backend/packages/harness/deerflow/sandbox/command_scope.py:32` |
| 预热 | `backend/packages/harness/deerflow/sandbox/prewarm.py:200` |
| 产物快照 | `backend/packages/harness/deerflow/sandbox/artifact_snapshot.py:135` |
| 路径掩码规则 | `backend/packages/harness/deerflow/sandbox/path_patterns.py:115` |
| 沙箱工具层 | `backend/packages/harness/deerflow/sandbox/tools.py:2112`、`tools.py:2834` |
| 虚拟路径常量与目录 | `backend/packages/harness/deerflow/config/paths.py:14`、`paths.py:364` |
| 隔离范围令牌 | `backend/packages/harness/deerflow/sandbox/identity.py:26` |
| config.yaml sandbox 段 | `config.example.yaml:1732` |
| Provisioner 服务 | `docker/provisioner/app.py`、`docker/provisioner/README.md` |
| 路径类型示例文档 | `backend/docs/PATH_EXAMPLES.md` |
| 内存剖析方法论 | `backend/docs/SANDBOX_MEMORY_PROFILING.md` |

## 8.0 学习目标

读完本章，你应该能够：

1. 说清 `SandboxProvider` / `Sandbox` 两级抽象的职责边界，以及 `LocalSandboxProvider` 与
   `AioSandboxProvider` 在隔离强度、路径映射实现和生命周期上的本质差异；
2. 走读 `/mnt/user-data/{workspace,uploads,outputs}` 虚拟路径的**正向解析**（命令/文件内容
   → 宿主路径）与**反向掩码**（输出 → 虚拟路径）双向机制；
3. 解释执行租约（`SandboxLeaseManager`）如何协调 lead agent、子代理、Gateway 请求与
   上传同步多个持有者，以及"最后一个持有者才释放"的语义；
4. 掌握 `config.yaml → sandbox:` 段每个配置键的作用，理解"生产必须容器沙箱"的安全理由；
5. 独立完成一次 local 与 docker 两种沙箱下的对照实验，观察路径映射与文件落盘位置。

## 8.1 概念：Agent 的代码执行为什么需要一层沙箱

DeerFlow 的核心能力之一是让模型**真的去执行**：写一个 Python 脚本跑数据分析、调
`pip` 装依赖、对上传的 Excel 做转换。这些操作天然危险——模型生成的代码不可信，
而 Gateway 进程持有平台凭据（`OPENAI_API_KEY`、数据库连接串、tracing key……）。

DeerFlow 的答案是把"执行"收拢在一个统一抽象后面：

- **`SandboxProvider`**（`backend/packages/harness/deerflow/sandbox/sandbox_provider.py:17`）
  回答"沙箱从哪来"：按 `user_id + thread_id` 获取/复用/释放一个执行环境；
- **`Sandbox`**（`backend/packages/harness/deerflow/sandbox/sandbox.py:45`）回答"沙箱能做什么"：
  `execute_command` / `read_file` / `write_file` / `download_file` / `list_dir` / `glob` /
  `grep` / `update_file` 八个原语。

`docs/ARCHITECTURE.md` §6 把隔离模型写得很直白：**生产环境应该用 Docker 的
`AioSandboxProvider`；local 沙箱只是开发期的直接执行，不是安全边界**。
`security.py:10` 里甚至内置了一句面向操作者的提示：

```python
LOCAL_HOST_BASH_DISABLED_MESSAGE = (
    "Host bash execution is disabled for LocalSandboxProvider because it is not a secure "
    "sandbox boundary. Switch to AioSandboxProvider for isolated bash access, or set "
    "sandbox.allow_host_bash: true only in a fully trusted local environment."
)
```

默认配置 `config.example.yaml:1733` 的 `use: deerflow.sandbox.local:LocalSandboxProvider`
配合 `config.example.yaml:1737` 的 `allow_host_bash: false`：开箱状态下 local 沙箱**没有
bash 工具**，只有文件读写类工具（它们走 `PathMapping` 边界）；想跑 shell 要么显式打开
host bash（仅在完全可信的本机环境），要么切到 AIO 容器沙箱。

一个容易忽略的点：DeerFlow 其实内置了**六种** Provider 实现，全部通过
`sandbox.use` 这个"class path"字段装配（`sandbox_provider.py:242` 的
`resolve_class(config.sandbox.use, SandboxProvider)`）：

| `sandbox.use` | 隔离形态 | 典型场景 |
| --- | --- | --- |
| `deerflow.sandbox.local:LocalSandboxProvider` | 宿主进程直接执行 | `make dev` 开发 |
| `deerflow.community.aio_sandbox:AioSandboxProvider` | Docker / Apple Container 容器 | 生产（本地容器） |
| 同上 + `provisioner_url` | K8s Pod（经 Provisioner 8002） | 生产（K8s） |
| `deerflow.community.e2b_sandbox:E2BSandboxProvider` | E2B 云端微 VM | 远程托管 |
| `deerflow.community.boxlite:BoxliteProvider` | BoxLite micro-VM | 需要 KVM/HVF |
| `deerflow.community.opensandbox:OpenSandboxProvider` / `deerflow.community.tenki:TenkiSandboxProvider` | 远程沙箱服务 | 可选集成 |

本章以默认的两个实现（Local / AIO）为主线，其余实现共享同一套抽象与租约机制。

## 8.2 源码走读：Provider 抽象与进程级单例

### 8.2.1 SandboxProvider 的五个生命周期方法

`backend/packages/harness/deerflow/sandbox/sandbox_provider.py:17` 起：

```python
class SandboxProvider(ABC):
    """Abstract base class for sandbox providers"""

    uses_thread_data_mounts: bool = False
    needs_upload_permission_adjustment: bool = True
    # Capability for enforcing a lead Agent's physical skill view across the
    # provider's current Agent-accessible tool surface. Host-backed providers
    # must return False whenever shell access can bypass managed path mappings.
    supports_agent_skill_isolation: bool = False
```

三个类级能力位值得逐个解释：

- `uses_thread_data_mounts`：线程的 `workspace/uploads/outputs` 是否通过**共享挂载**
  直接对容器可见。`LocalSandboxProvider` 置 `True`（`local_sandbox_provider.py:73`），
  因为虚拟路径和宿主目录本就指向同一份文件；AIO 本地容器模式由后端自动检测，
  远程/provisioner 模式默认 `False`——上传文件需要一次显式的 `acquire + sync`。
- `supports_agent_skill_isolation`：能否为"显式声明了技能白名单的 Agent"物理隔离
  `/mnt/skills` 视图。宿主型 Provider 只要 bash 能绕过路径映射就必须报 `False`，
  `local_sandbox_provider.py:77` 的 property 正是这样实现的——它动态读取
  `is_host_bash_allowed()`。
- `needs_upload_permission_adjustment`：上传后是否需要调整沙箱内文件权限。

核心方法签名（`sandbox_provider.py:31`）：

```python
    @abstractmethod
    def acquire(self, thread_id: str | None = None, *, user_id: str | None = None) -> str:
        """Acquire a sandbox environment and return its ID.
        ...
```

`acquire` 只返回一个 **sandbox_id 字符串**；`get(sandbox_id)` 才返回可操作的
`Sandbox` 对象。`get_scoped`（`sandbox_provider.py:89`）是身份安全的关键补充：
"只有当这个 sandbox_id 确实属于当前 `(user_id, thread_id)` 时才返回客户端，
否则返回 `None` 让调用方走规范 `acquire` 重建"。这防止了 checkpoint 里持久化的
`sandbox_id` 被另一个身份的会话捡走复用。

### 8.2.2 带锁的单例装配

Provider 是进程级单例，但构造函数是插件代码（可能很慢、可能有副作用、甚至可能重入
生命周期函数），所以装配逻辑把"换引用"和"跑构造"拆开（`sandbox_provider.py:222`）：

```python
def get_sandbox_provider(**kwargs) -> SandboxProvider:
    global _default_sandbox_provider
    # Fast path: a single locked read so a concurrent reset/shutdown can't null
    # the global between the check and the return.
    with _provider_lock:
        if _default_sandbox_provider is not None:
            return _default_sandbox_provider

    # Cold start. Resolve + construct outside the lock: the import and the
    # provider constructor are plugin code and must not run under a non-reentrant
    # lock. The construction may race another caller; we reconcile under the lock.
    config = get_app_config()
    cls = resolve_class(config.sandbox.use, SandboxProvider)
    provider = cls(**kwargs)

    with _provider_lock:
        if _default_sandbox_provider is None:
            _default_sandbox_provider = provider
            return provider
        # We lost the install race: another thread got there first. ...
        winner = _default_sandbox_provider

    # Discard the instance we just built (outside the lock). ...
    if hasattr(provider, "shutdown"):
        provider.shutdown()
    return winner
```

两个并发场景是这套设计的动因：Feishu 渠道线程跑着自己的事件循环，会与主循环同时
首次触碰 Provider；AIO 的构造函数会启动 idle-checker 守护线程，输掉安装竞争的那份
实例必须 `shutdown()` 掉，否则就是线程泄漏（源码注释指向 issue #3721）。

另一个细节：`hold_sandbox_shutdown_ownership()`（`sandbox_provider.py:191`）让 Gateway
lifespan 声明"由宿主负责关停"，在它内部构造的 Provider 跳过 SIGTERM/SIGINT 处理器——
避免 Provider 的信号处理器和 uvicorn 的优雅退出互相踩踏。

## 8.3 源码走读：Local vs Aio 两个 Provider（重点）

### 8.3.1 LocalSandboxProvider：每线程一个映射表

`backend/packages/harness/deerflow/sandbox/local/local_sandbox_provider.py:36` 的类注释
交代了它的演化：早期版本是全局单例 `id="local"`，但 `/mnt/user-data` 的宿主目录是
**按线程**划分的，单例无法兑现文档承诺的路径契约。现在的实现是：

- `acquire(thread_id)` 返回 `local:{user_id}:{thread_id}` 的每线程沙箱
  （`_sandbox_id_for_thread`，`local_sandbox_provider.py:320`）；
- `acquire(None)` 保留遗留的通用单例 `id="local"`，供没有线程上下文的调用方使用；
- 每线程实例放进 **LRU 缓存**，默认 256 条（`DEFAULT_MAX_CACHED_THREAD_SANDBOXES`，
  `local_sandbox_provider.py:33`），超限时最久未用条目被驱逐，下次 acquire 重建
  （只损失用于反向解析的 `_agent_written_paths` 提示）。

`acquire` 的主体（`local_sandbox_provider.py:458`）：

```python
    def acquire(self, thread_id: str | None = None, *, user_id: str | None = None) -> str:
        ...
        effective_user_id = self._effective_acquire_user_id(user_id)
        # Runs on every acquire, including cache hits, to self-heal drift — ...
        skill_projection = self._ensure_skills_projection(
            effective_user_id,
            thread_id=thread_id if self.supports_agent_skill_isolation else None,
        )
        key = self._thread_key(thread_id, effective_user_id)
        ...
        new_mappings = self._without_managed_skill_mappings(
            list(self._path_mappings),
            policy_scoped=policy_scoped,
        )
        new_mappings += self._build_thread_path_mappings(
            thread_id,
            user_id=effective_user_id,
            skill_projection=skill_projection,
        )

        with self._lock:
            cached = self._thread_sandboxes.get(key)
            if cached is None or cached.path_mappings != new_mappings:
                replacement = LocalSandbox(
                    self._sandbox_id_for_thread(thread_id, effective_user_id),
                    path_mappings=new_mappings,
                    environment=self._environment,
                )
                if cached is not None:
                    replacement._agent_written_paths.update(cached._agent_written_paths)
                cached = replacement
                self._thread_sandboxes[key] = cached
                self._evict_until_within_cap_locked()
            else:
                self._thread_sandboxes.move_to_end(key)
            return cached.id
```

三个值得注意的行为：

1. **每次 acquire 都重建映射表再与缓存比对**：技能投影、自定义挂载变化会在下一次
   acquire 时自动生效（`cached.path_mappings != new_mappings` 触发替换）；
2. `_agent_written_paths`（Agent 写过哪些文件的反向解析提示）跨替换保留；
3. `release()` 是**故意空实现**（`local_sandbox_provider.py:578`）——LocalSandbox 没有需要
   释放的外部资源，保留缓存实例让跨轮次复用成立，真正清理只发生在 LRU 驱逐和
   `reset()`。

### 8.3.2 AioSandboxProvider：容器 + 温热池 + 跨实例所有权

AIO（`backend/packages/harness/deerflow/community/aio_sandbox/aio_sandbox_provider.py`，
约 3000 行）把同一套抽象落到了 Docker 上。三个关键机制：

**（1）确定性容器标识。** 容器/Pod 的身份由
`derive_sandbox_scope_token(user_id, thread_id)`（`sandbox/identity.py:26`）决定：

```python
def derive_sandbox_scope_token(*, user_id: str, thread_id: str) -> str:
    return hashlib.sha256(f"{user_id}:{thread_id}".encode()).hexdigest()[:_TOKEN_HEX_LEN]
```

`sha256("{user_id}:{thread_id}")[:16]` 是一个**兼容性契约**：AIO、E2B、BoxLite、Tenki、
OpenSandbox 都靠它找回已存在的容器/VM。模块注释明确警告——改动分隔符、摘要、
大小写或截断长度都是破坏性迁移，已有远程资源会全部"失联"然后冷启动。

**（2）温热池（warm pool）。** `release` 不销毁容器，而是把它放回 `_warm_pool`
（`aio_sandbox_provider.py:276`），同一 `(user_id, thread_id)` 的下一轮对话直接"回收"
（`_reclaim_warm_pool_sandbox`，`aio_sandbox_provider.py:1827`），省掉数秒的容器冷启动。
共享的 `WarmPoolLifecycleMixin`（`community/warm_pool_lifecycle.py`）提供默认参数：
`DEFAULT_IDLE_TIMEOUT=600` 秒、`IDLE_CHECK_INTERVAL=60` 秒、`DEFAULT_REPLICAS=3`，
空闲检查器按 `idle_timeout` 过期温热条目、按 `replicas` 驱逐最旧的温热 VM。

**（3）跨实例所有权（issue #4206）。** 多个 Gateway 实例共享一个 Docker 后端时，
"谁可以回收这个容器"需要协调。`sandbox.ownership.type: memory | redis`
（`config.example.yaml:1893`）选择租约存储；Redis 模式下 `take()`（acquire 路径转移
所有权）与 `claim()`（adopt/reap 路径，仅在无主或已归我时成功）分离，`del:` 租约状态
在销毁窗口内挡住新持有者。配置注释（`config.example.yaml:1879`）写明：**多实例部署
必须设 `type: redis`**；Docker Compose 已设置 `DEER_FLOW_STREAM_BRIDGE_REDIS_URL`，
会被自动推断为多实例并启用 Redis 所有权。单实例用默认 `memory` 即可——它声明
`supports_cross_process = False`，明示"看不见对端"。

### 8.3.3 挂载计算的对称性

AIO 在**容器创建时**就把线程目录挂到同样的虚拟路径（`aio_sandbox_provider.py:1101`）：

```python
    @staticmethod
    def _get_thread_mounts(thread_id: str, *, user_id: str | None = None) -> list[tuple[str, str, bool]]:
        """Get volume mounts for a thread's data directories."""
        ...
            (paths.host_sandbox_work_dir(thread_id, user_id=effective_user_id), f"{VIRTUAL_PATH_PREFIX}/workspace", False),
            (paths.host_sandbox_uploads_dir(thread_id, user_id=effective_user_id), f"{VIRTUAL_PATH_PREFIX}/uploads", False),
            (paths.host_sandbox_outputs_dir(thread_id, user_id=effective_user_id), f"{VIRTUAL_PATH_PREFIX}/outputs", False),
```

这就是 AGENTS.md 那句总结的出处："AIO has the directories volume-mounted at the same
virtual paths inside its container, so both implementations accept `/mnt/user-data/...`
natively"。两个 Provider 对外的路径契约完全一致，差异只在**映射发生的位置**：

| 维度 | LocalSandboxProvider | AioSandboxProvider |
| --- | --- | --- |
| 隔离边界 | 无（宿主子进程，仅路径映射） | Docker 容器 / K8s Pod / 远程 VM |
| sandbox_id 形态 | `local:{user_id}:{thread_id}` | 16 位 hex scope token 派生 |
| 路径映射 | Python 内 `PathMapping` 表，逐调用解析翻译 | 容器 volume 挂载，内核级 |
| bash 执行 | 默认禁用（`allow_host_bash` 显式打开） | 容器内 bash，支持服务端 hard_timeout |
| release 语义 | no-op（LRU 缓存常驻） | 回收进温热池 / 归还所有权 |
| 跨实例协调 | 不需要 | `ownership: memory/redis` 租约 |
| shell 会话 | 每条命令新进程（`persistent_shell_sessions = False`） | 持久 PTY 会话（`persistent_shell_sessions = True`） |

## 8.4 源码走读：/mnt/user-data 虚拟路径映射（重点）

### 8.4.1 一份路径，三种形态

`backend/docs/PATH_EXAMPLES.md` 把路径分为三类（节选自其第 9–53 行的表格化描述）：

```
实际文件系统路径 path:      {DEER_FLOW_HOME}/users/{user_id}/threads/{thread_id}/user-data/uploads/document.pdf
虚拟路径 virtual_path:      /mnt/user-data/uploads/document.pdf
HTTP 访问 URL artifact_url: /api/threads/{thread_id}/artifacts/mnt/user-data/uploads/document.pdf
```

常量定义在 `backend/packages/harness/deerflow/config/paths.py:14`：

```python
VIRTUAL_PATH_PREFIX = "/mnt/user-data"
```

宿主目录的推导集中在同文件的几个 helper（`paths.py:364`–`paths.py:442`），例如：

```python
    def sandbox_uploads_dir(self, thread_id: str, *, user_id: str | None = None) -> Path:
        """
        Host path for user-uploaded files.
        Host: `{base_dir}/threads/{thread_id}/user-data/uploads/`
        Sandbox: `/mnt/user-data/uploads/`
        """
        return self.thread_dir(thread_id, user_id=user_id) / "user-data" / "uploads"
```

`base_dir` 即 `DEER_FLOW_HOME`（默认 `backend/.deer-flow`）。注意 `paths.py:344` 的
`thread_dir`：带 `user_id` 时走 `users/{user_id}/threads/{thread_id}`，不带时走
`threads/{thread_id}`——**上传桶按用户分桶**，这正是 IM 渠道多租户场景的基础。

### 8.4.2 正向解析：PathMapping 表

LocalSandbox 持有一组 `PathMapping`（`local/local_sandbox.py:264`）：

```python
@dataclass(frozen=True)
class PathMapping:
    """A path mapping from a container path to a local path with optional read-only flag."""

    container_path: str
    local_path: str
    read_only: bool = False
```

每线程映射表由 `_build_thread_path_mappings`（`local_sandbox_provider.py:334`）构建，
覆盖五个虚拟根：`/mnt/user-data`（聚合父映射）、`.../workspace`、`.../uploads`、
`.../outputs`、`/mnt/acp-workspace`，再叠加技能投影挂载与 `sandbox.mounts` 自定义挂载。
解析时**最长前缀优先**（`local/local_sandbox.py:583`）：

```python
    def _find_path_mapping(self, path: str) -> tuple[PathMapping, str] | None:
        path_str = str(path)

        for mapping in self._mappings_by_container_specificity:
            container_path = mapping.container_path.rstrip("/") or "/"
            if container_path == "/":
                if path_str.startswith("/"):
                    return mapping, path_str.lstrip("/")
                continue

            if path_str == container_path or path_str.startswith(container_path + "/"):
                relative = path_str[len(container_path) :].lstrip("/")
                return mapping, relative

        return None
```

随后 `_resolve_path_with_mapping`（`local_sandbox.py:599`）做两件安全事务：
`os.path.realpath` 消解符号链接，再用 `commonpath` 检查解析结果没有逃出挂载根
（`local_sandbox.py:622` 的 `PermissionError(errno.EACCES, "Access denied: path escapes
mounted directory", path_str)`）——`..` 目录穿越和"挂在uploads里的软链接指向 uploads 外"
都在这里被拒。

### 8.4.3 反向掩码：宿主路径永远不回到模型眼前

Agent 跑 `python /mnt/user-data/workspace/x.py`，脚本里 `print(os.getcwd())`——输出是
宿主真实路径。若原样返回模型，下一步它就会拿着宿主路径调工具（解析失败），更糟的是
泄露了服务器目录结构。所以 `execute_command` 的最后一步是反向解析
（`local/local_sandbox.py:964`）：

```python
        final_output = output if output else "(no output)"
        # Reverse resolve local paths back to container paths in output
        return self._reverse_resolve_paths_in_output(final_output)
```

底层扫描器 `replace_output_path_matches`（`sandbox/path_patterns.py:115`）的规则值得
读一遍注释（`path_patterns.py:42`–`path_patterns.py:73`）：

- `_SEGMENT_BOUNDARY`：宿主根必须结束在**真实路径段边界**，防止 `.../skills` 匹配进
  `.../skills-extra`；
- `PATH_START_BOUNDARY`：左侧镜像——根不能是一个更长路径的中段，否则
  `/mnt/user-data` 会错误命中 artifact URL `.../artifacts/mnt/user-data/...`；
- `_PATH_TAIL` 在 `:` 处停止，否则 `$PATH` 这类冒号连接的列表会把后续每个条目都
  整段带进同一个根下返回给模型。

这个模块存在的原因也写在注释里：`LocalSandbox` 与 `sandbox/tools.py` 是两个独立调用点，
历史上各自维护一份匹配规则并两次漂移（#4035、#4053），现在收敛为单一实现。
工具层还有第三道防线 `mask_local_paths_in_output`（`sandbox/tools.py:863`）与
`replace_virtual_path`（`sandbox/tools.py:755`）——`tools.py` 把它们定位为
"defense-in-depth 层以及路径校验"。

### 8.4.4 上传与产物在沙箱内外的同步行为

- **`thread_data_mounts=True`**（Local、本地 AIO 容器默认）：上传 API 写完线程目录后
  沙箱"天然可见"，无需同步。AIO 侧由后端自动检测，`sandbox.thread_data_mounts`
  （`config.example.yaml:1836`）可显式覆盖。
- **`thread_data_mounts=False` 或远程 Provider**：每次上传后 Gateway 调
  `SandboxProvider.acquire_async()` + `sandbox.update_file()` 把文件推入沙箱
  （见 `backend/AGENTS.md` File Upload 节的约定）。
- **反向**：Agent 在容器内写 `/mnt/user-data/outputs/report.html`，本地容器模式同样
  天然落盘；远程模式靠产物回收管线。`artifact_snapshot.py` 为此实现了一个
  **描述符受限的 POSIX 协议**：`publish_snapshot`（`artifact_snapshot.py:135`）先用
  `O_NOFOLLOW` + `fstat` 身份戳分块 append 到临时文件，再以 sha256/size 双校验
  `os.link` 原子发布——单文件上限 `MAX_BYTES = 2 * 1024 * 1024`（`artifact_snapshot.py:16`），
  确认"远端文件在传输期间没有被掉包"才允许覆盖已有文件。

## 8.5 源码走读：Sandbox 接口与一次 bash 执行

### 8.5.1 接口契约与"会话语义"自白

`backend/packages/harness/deerflow/sandbox/sandbox.py:68` 声明了一个特殊的三态字段：

```python
    #: Whether ``execute_command`` reuses one persistent shell session across
    #: calls (shell state — exports, cwd, functions — survives from one call
    #: into the next). When True, a recorded command's environment cannot be
    #: proven clean from the command text alone, so evidence consumers (the
    #: acceptance checklist's ``tests_passed`` matcher) must treat recorded
    #: bash evidence as untrusted and degrade to UNVERIFIED.
    #:
    #: Tri-state, failing closed: ``None`` (the default) means the
    #: implementation has NOT declared its session semantics — ...
    persistent_shell_sessions: bool | None = None
```

`LocalSandbox.persistent_shell_sessions = False`（`local_sandbox.py:358`——每条命令都是
`subprocess.run([shell, "-c", ...])` 新进程），`AioSandbox.persistent_shell_sessions = True`
（`aio_sandbox.py:73`——复用容器内 PTY 会话）。这个字段会被第 9 章的验收检查消费：
一条"测试通过"的证据如果产自状态不可信的持久会话，只能降级为 UNVERIFIED。
自定义 Provider 忘了声明？三态默认 `None` 按"未声明"处理，同样失败闭合。

### 8.5.2 execute_command 的完整流水线

`LocalSandbox.execute_command`（`local/local_sandbox.py:844`）串起了本章前半部分的所有
机制，节选关键段：

```python
        _validate_extra_env(env)
        # Resolve container paths in command before execution
        shell = self._get_shell()
        resolved_command = self._resolve_paths_in_command(command, shell=shell)
        if timeout is None:
            timeout = DEFAULT_COMMAND_TIMEOUT_SECONDS

        # Inherit os.environ minus platform secrets, then layer injected
        # request-scoped secrets on top (#3861). ...
        injected = {**self.environment, **(env or {})}
        sandbox_env = build_sandbox_env(injected)
```

五个步骤依次是：

1. `_validate_extra_env`：校验注入 env 的键名符合 POSIX 规则
   `^[A-Za-z_][A-Za-z0-9_]*$`（`sandbox.py:15`），这是契约层的纵深防御——今天本地
   实现用 `subprocess.run(env=...)` 不经 shell，但 AIO 实现会把键拼进
   `export <k>=<v>`，统一在抽象层拒绝注入向量；
2. `_resolve_paths_in_command`：把命令文本里的 `/mnt/user-data/...` 翻译成宿主路径
   （PowerShell 还要经过 `escape_powershell_path` 的引号上下文转义，
   `local_sandbox.py:281`）；
3. `build_sandbox_env`：环境变量策略（下节）；
4. 按 shell 分派运行器：Windows 上 PowerShell/cmd/Git Bash 三条分支各自处理编码
   （UTF-8 前导 + locale 回退解码，`local_sandbox.py:877`–`local_sandbox.py:942`），
   POSIX 走 `_run_posix_command`；管道由有界排水线程读取（`_BoundedPipeCapture`，
   捕获上限 10 MiB），stdin 立即 EOF；
5. 超时与非零退出都**显式落状态标记**（`local_sandbox.py:952`）：

```python
        if timed_out:
            notice = self._format_timeout_notice(timeout)
            output += f"\n{notice}" if output else notice
            # A timeout is a failed execution: mark it authoritatively (the
            # coreutils ``timeout`` convention) so exit-status evidence
            # consumers cannot read partial output as success.
            output += "\nExit Code: 124"
        elif returncode != 0:
            output += f"\nExit Code: {returncode}"
```

默认命令超时 `DEFAULT_COMMAND_TIMEOUT_SECONDS = 600`（`local_sandbox.py:38`），可被
`config.example.yaml:1780` 的 `sandbox.bash_command_timeout: 600` 按 Provider 透传覆盖。

### 8.5.3 环境变量策略：默认擦除凭据

`backend/packages/harness/deerflow/sandbox/env_policy.py` 解决一个静默漏洞：子进程默认
继承 `os.environ`，而里面躺着平台凭据——技能脚本只要 `os.environ.get("OPENAI_API_KEY")`
就能把密钥抄走。策略是**默认擦除，白名单保留**（`env_policy.py:108`）：

```python
def build_sandbox_env(injected: dict[str, str] | None = None) -> dict[str, str]:
    """Build the environment dict for a sandbox subprocess.

    Inherits ``os.environ`` minus any secret-looking variables, then layers the
    explicitly injected request-scoped secrets on top. An injected secret wins
    even if its name matches a blocked pattern, because injection is authorized
    upstream (the skill declared it and the value came from the request, not from
    the host environment).
    """
    env = {key: value for key, value in os.environ.items() if not is_blocked_env_name(key)}
    if injected:
        env.update(injected)
    return env
```

`is_blocked_env_name`（`env_policy.py:99`）由两组规则构成：

- 通配模式（`env_policy.py:24`）：`*KEY*`、`*SECRET*`、`*TOKEN*`、`*PASS*`、
  `*CREDENTIAL*`、`*DSN*`——注意 `*PASS*` 连 `GIT_ASKPASS`、`SSH_ASKPASS` 这种
  "指向凭据的程序名"也一起擦掉；
- 精确名单（`env_policy.py:66`）：`DATABASE_URL`、`MYSQL_PWD`、`REDISCLI_AUTH`、
  `SSH_AUTH_SOCK`、`PGSERVICEFILE` 等不含关键子串但必然携带凭据的名字。

`PATH`、`HOME`、`LANG`、`VIRTUAL_ENV`、`PWD` 这些良性变量天然不含上述 token 而得以
保留。操作者可通过 `sandbox.environment`（`config.example.yaml:1851` 附近的示例段）
注入显式变量，`$VAR` 形式在配置加载期解析；显式注入**穿透擦除**，因为它是操作者
授权的通道。

### 8.5.4 AIO 侧的对应实现

AioSandbox 的命令执行有两套传输：

- **持久 shell 会话**（`/v1/shell` PTY）：`execute_command_in_scope`（`aio_sandbox.py:584`）
  为每个 `scope_id` 维持一条服务端会话——scope 内命令串行、不同子代理的 scope 并发；
  会话遇 `ErrorObservation` 污染、404 或传输错误时旋转重建；
- **fresh `bash.exec`**（`/v1/bash/exec`）：凡是携带 `env` 的命令走这条新会话通道
  （`aio_sandbox.py:1097` 的 `_run_bash_exec`），保证密钥不残留进持久会话。老镜像
  （`latest` 冻结在 1.0.0.x）没有这个 API，`aio_sandbox.py:30` 的
  `_BASH_EXEC_UNSUPPORTED_ERROR` 会给出"升级到 all-in-one-sandbox >= 1.9.3（推荐
  1.11.0）"的可操作报错而不是让模型盲目重试。

## 8.6 源码走读：租约机制（lease.py，重点）

### 8.6.1 问题：一个沙箱，多个持有者

一条线程的生命周期里会同时出现多个"正在使用沙箱"的执行：lead agent 本轮 run、
并行的子代理、Gateway 的上传/产物同步请求、fork 恢复出的子执行。如果谁用完谁
`release`，lead agent 还在跑的沙箱就会被子代理提前回收。`sandbox/lease.py:1` 的模块
docstring 一句话讲清解法：

```
Provider ownership stores answer which Gateway instance may reap a remote
sandbox.  This module answers a different question: which concurrently running
agent executions inside one Gateway are still using the provider's active
client.  The last execution lease is the only one allowed to call
``SandboxProvider.release``.
```

注意两套"租约"的分工：**Provider ownership store**（8.3.2 的 redis/memory）回答
"哪个 Gateway 实例可以回收容器"，是跨实例的；**`SandboxLeaseManager`**（
`lease.py:180`）回答"本进程内哪些执行还在用这个客户端"，是进程内的。

### 8.6.2 持有者绑定与最后持有者释放

`ensure_sandbox_lease_owner`（`lease.py:780`）在运行时 context 里创建一个临时
owner id（`f"agent:{uuid4()}"`）；子代理则由执行器注入更稳定的
`f"subagent:{task_id}"`（见第 9 章 `executor.py:1734`）。`release` 的核心逻辑
（`lease.py:678`）：

```python
    def release(self, owner_id: str) -> None:
        """Release one execution and park the sandbox only after the last user."""
        with self._metadata_lock:
            binding = self._bindings_by_owner.get(owner_id)
        if binding is None:
            return

        with self._serializer.hold(binding.thread_key):
            with self._metadata_lock:
                current = self._bindings_by_owner.get(owner_id)
                if current is None:
                    return
                binding = current
            try:
                sandbox = self._provider.get(binding.sandbox_id)
                if sandbox is not None:
                    sandbox.release_command_scope(owner_id)
            finally:
                # Scope cleanup still uses the client: keep the holder until
                # it drains, then atomically decide whether parking is pending.
                with self._metadata_lock:
                    binding, release_provider = self._remove_binding_locked(owner_id)
                if release_provider:
                    assert binding is not None
                    self._release_if_idle(binding.sandbox_id)
```

`_remove_binding_locked`（`lease.py:204`）实现"最后持有者"判定：owner 退出时，若
同一 sandbox_id 还有其他 owner（`_owners_by_sandbox` 集合非空），只记下
`_release_pending_by_sandbox` 释放意向；集合清空时才真正触发
`_release_if_idle` → `provider.release`。"释放意向 + 最后退出者执行"把
"持有者先后顺序不可预测"变成了一种安全排序。

另外两类持有者语义（`acquire_sandbox_client_lease`，`lease.py:111` 的
`release_on_last` 参数）：

- **普通执行**（lead、子代理）：`release_on_last=True`，正常表达"我走之后可以收摊"；
- **借用者**（上传同步、fork 恢复子执行）：`release_on_last=False`，只围栏客户端、
  只清理自己的命令作用域，**不请求**回收温热沙箱。

### 8.6.3 取消与清积压：重复取消不能撕裂生命周期

`run_sync_lifecycle_operation`（`lease.py:60`）是全模块的基石原语：把阻塞的
Provider 调用丢进 `asyncio.to_thread`，await 方被取消时**记住取消但不传播**，
先把 worker 跑完（`_drain_task_after_cancellation` 反复 shield），再重抛取消。
这保证"反复 cancel 的调用方"不可能让一次 `acquire`/`release` 半途而废——
Provider 的工作线程无法被取消，唯一安全的做法是等它结束再做簿记。

`SandboxMiddleware.after_agent` / `aafter_agent`（`middleware.py:462`、`middleware.py:495`）
是执行的外围栅栏：先关闭预热句柄（`close_sandbox_prewarm`），fork 恢复的沙箱
**不释放**（"releasing it here would evict the parent's warm sandbox"），普通沙箱按
owner 走 `SandboxLeaseManager.release`。

### 8.6.4 命令作用域（command_scope.py）

租约的 owner id 同时兼任 `sandbox_command_scope_id`（子代理场景见
`executor.py:1907`–`1908`，两个 context 键取同一个值）。`sandbox/command_scope.py:32`
的 `CommandScopes` 维护"每个 owner 的取消令牌 + 进程组"：

```python
COMMAND_OWNER_ENV = "DEERFLOW_COMMAND_OWNER"
```

Local 沙箱（POSIX）把 owner 令牌写进子进程环境变量 `DEERFLOW_COMMAND_OWNER`；
取消时（`local_sandbox.py:334` 的 `cancel_command_scope`）先 SIGTERM 进程组，再对
"shell 已返回但留下 nohup 子进程"的情形用 `pgrep -g` + `ps eww` 校验环境变量里
的令牌匹配，才敢 `SIGKILL` 那个可能已被复用的 PGID。AIO 则把每个 scope 映射为一条
显式持久 shell 会话，scope 释放时一并清理。

## 8.7 源码走读：沙箱中间件、预热与授权门

### 8.7.1 SandboxMiddleware：沙箱进入 ThreadState

`middleware.py:56` 的 `SandboxMiddleware` 是第 6 章中间件链的第三环。它有两种取沙箱
时机（`middleware.py:59`）：

- `lazy_init=True`（默认）：`abefore_model` 里**启动但不等待**预热
  （`middleware.py:452` 的 `start_sandbox_prewarm(state, runtime)`），模型第一次响应
  与 Docker 启动重叠，第一个沙箱工具调用再正式认领；
- `lazy_init=False`：`before_agent` 立即获取。

获取后写进图状态 `{"sandbox": {"sandbox_id": ...}}`，经 LangGraph channel 持久化进
checkpoint——下一轮对话从 checkpoint 恢复时，`_retain_existing_sandbox` 用
`reuse_or_acquire` 校验"这个 id 还活着且属于本身份"，失效就换新。懒获取路径里
`wrap_tool_call`（`middleware.py:590`）负责把工具执行期间新初始化的 sandbox_id
**diff 出来**并用 `Command(update=...)` 回写状态——因为 `ensure_sandbox_initialized`
直接改 `runtime.state`，不经包装器的话 LangGraph 的 channel reducer 根本看不到。

### 8.7.2 预热（prewarm.py）：投机性获取

`should_prewarm_sandbox`（`prewarm.py:73`）用正则预测"最新用户消息里是否出现代码栅栏、
路径、命令行或 Traceback"，命中才允许投机启动。预算控制 `prewarm_max_concurrent`
（默认 1，`config.example.yaml:1744`）限制"每 Provider 每进程"的未认领投机数；
`config.example.yaml:1740` 的 `prewarm: false` 总开关默认关闭，且**仅对 AIO 生效**
（`prewarm.py:120` 检查 `sandbox.use.endswith(":AioSandboxProvider")`）。

预热句柄必须注册在"无条件异步租约释放的 finally"里
（`register_sandbox_prewarm_cleanup`，`lease.py:769`）——一个投机获取如果比正式工具
先拿到沙箱、又没有认领（`claim`），要在 run 结束时归还，且归还动作不能被取消跳过。

### 8.7.3 授权门：sandbox:execute

`tools.py:2112` 的 `ensure_sandbox_initialized` 是所有沙箱工具的单一初始化入口，
第一件事就是授权（`tools.py:2139`）：

```python
    # Authorization is a live execution policy, not a lifetime property of a
    # sandbox id. Re-check before both reuse and acquisition so a role or policy
    # change takes effect on the next sandbox-backed tool call.
    if not _SANDBOX_AUTHORIZATION_CHECKED.get():
        authorize_sandbox_execution(
            context=runtime.context or {},
            app_config=safe_app_config(),
        )
```

RFC #4063 Phase 3 的语义：对每个沙箱工具调用做一次二元
`authorize(principal, "sandbox", "execute", target="*")` 判定，**复用已缓存沙箱也要重查**——
因为授权配置和用户角色可能在沙箱缓存存活期间变了。拒绝以普通错误 `ToolMessage`
（"sandbox execution is not permitted for your role"）浮出，而不是炸掉整个 run；
`SandboxMiddleware.before_agent`（`middleware.py:274`）的急切路径捕获同一异常后跳过
获取，把拒绝推迟到第一个真正触碰沙箱的工具调用。无 `config.yaml` 或
`authorization.enabled: false` 时整个门退化为 no-op（fail-open 由配置显式选择）。

网络出站管控（AIO 本地容器独有）在 `config.example.yaml:1818` 附近：
`network.mode: open | isolated | allowlist`，`allowlist` 模式下被拦域可经
Human Input 卡片审批（临时放行 TTL 默认 300 秒）——审批卡片的构造在
`middleware.py:659` 的 `_network_approval_result`，且**非交互运行（定时任务、webhook、
子代理）一律自动拒绝**，绝不给没有人值守的 run 弹审批卡。

## 8.8 源码走读：Provisioner / K8s 模式

`docker/provisioner/app.py` 是一个独立 FastAPI 服务（端口 8002），五个端点：

```
POST   /api/sandboxes              — Create a sandbox Pod + Service
DELETE /api/sandboxes/{sandbox_id} — Destroy a sandbox Pod + Service
GET    /api/sandboxes/{sandbox_id} — Get sandbox status & URL
GET    /api/sandboxes/{sandbox_id}/presence — Inspect Pod presence & generation
GET    /api/sandboxes              — List all sandboxes
```

`docker/provisioner/README.md` 描述了完整流程：Gateway 发 `POST /api/sandboxes`
携带 `sandbox_id` / `thread_id` / `user_id`，Provisioner 在 `deer-flow` 命名空间创建
专属 Pod，把技能投影（只读）与 `/mnt/user-data`（读写）挂进去，默认 NodePort
Service 暴露访问 URL（集群内可切 `SANDBOX_SERVICE_TYPE=ClusterIP` 返回 DNS 名）。
启用方式见 `config.example.yaml:1950`：

```yaml
# sandbox:
#   use: deerflow.community.aio_sandbox:AioSandboxProvider
#   provisioner_url: http://provisioner:8002
#   # provisioner_api_key: $PROVISIONER_API_KEY
```

AGENTS.md 中的 PVC 约定在本章的落点：Provisioner 以 `USERDATA_PVC_NAME=user-data`
**声明一次**共享 PVC；上传/产物目录与 Lark broker 凭据挂载都复用它（不同 subPath）。
当 Gateway 与 Pod 共享同一份线程用户数据目录（对齐的 PVC/NFS/hostPath）时，把
`sandbox.thread_data_mounts: true` 打开，上传就跳过 acquire/sync（Provisioner README
明确警告：挂载关系不确定时保持未设置，`false` 误报会让上传不可用）。

## 8.9 配置详解：config.yaml → sandbox: 段

默认（local）段的关键键（`config.example.yaml:1732` 起）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `use` | `deerflow.sandbox.local:LocalSandboxProvider` | Provider class path，可指向任意 `SandboxProvider` 子类 |
| `allow_host_bash` | `false` | 仅 local Provider 有效；打开 host bash（非安全边界） |
| `prewarm` | `false` | 仅 AIO；首次模型调用期间投机启动容器 |
| `prewarm_max_concurrent` | `1` | 每 Provider 每进程的投机预算 |
| `mounts` | 空 | 额外挂载 `host_path → container_path`（POSIX 风格），不得与保留前缀冲突（`local_sandbox_provider.py:177` 的 `_RESERVED_CONTAINER_PREFIXES`） |
| `bash_output_max_chars` | `20000` | bash 输出**中部截断**（头+尾，错误可能在任何位置） |
| `read_file_output_max_chars` | `50000` | 读文件**头部截断**，标记续读 `start_line` |
| `ls_output_max_chars` | `20000` | 目录列表头部截断 |
| `bash_command_timeout` | `600` | 每命令超时；AIO 1.9.3+ 由服务端 `hard_timeout` 执行 |

AIO 注释段（`config.example.yaml:1784` 起）补充：`image`（推荐显式 pin
`all-in-one-sandbox:1.11.0`，`latest` 冻结在缺少 `/v1/bash/*` 路由的旧 digest）、
`port`、`replicas`（默认 3，超限驱逐最久未用）、`container_prefix`、`network`
（`config.example.yaml:1819`）、`thread_data_mounts`、`environment`
（`$VAR` 运行时解析；AIO 镜像默认 `MAX_SHELL_SESSIONS=10`，配置注释要求它至少为
`subagent_runtime.max_running + 1`——子代理与 lead 各占会话）与 `ownership`。
第 9 章会用到 `MAX_SHELL_SESSIONS` 与 `max_running` 的联动关系。

## 动手实验：观察两种沙箱下的路径映射

**目标**：让同一个"分析上传 CSV"任务分别在 local 与 docker 沙箱执行，亲眼看到虚拟
路径的双向翻译与落盘位置。全程可离线复现。

**步骤 1：local 模式（默认配置）**

```bash
make config && make install && make dev
```

1. 浏览器打开 `http://localhost:2026`，新建会话，上传一个 `data.csv`；
2. 让 agent 执行：*"用 bash 打印 /mnt/user-data/uploads 目录列表，然后
   `python3 -c "import os; print(os.getcwd())"`，再写一个
   /mnt/user-data/outputs/hello.txt"*；
3. 观察模型可见的输出：全部是 `/mnt/user-data/...` 与相对路径——
   `execute_command` 结尾的反向解析把宿主痕迹抹掉了；
4. 打开宿主机确认落盘：`ls backend/.deer-flow/users/default/threads/<thread_id>/user-data/{uploads,outputs}/`；
5. 在 Gateway 日志（`logs/gateway.log`）里搜 `Acquiring sandbox`，你会看到
   `local:<user_id>:<thread_id>` 形态的 id，以及 LRU 缓存命中/替换的日志。

**步骤 2（可选，需要 Docker）：AIO 容器模式**

把 `config.yaml` 的 sandbox 段改为：

```yaml
sandbox:
  use: deerflow.community.aio_sandbox:AioSandboxProvider
  image: enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0
```

重启 Gateway（`make stop && make dev`），重复同样的对话，然后：

```bash
docker ps --filter name=deer-flow-sandbox
docker exec <容器> ls /mnt/user-data/uploads
```

你会看到容器内确实挂载着同一个线程目录（步骤 1 的 `hello.txt` 若是同一线程仍在）。
对比日志中的 sandbox_id：现在是 16 位 hex（scope token），且第二次对话会命中
温热池回收（`Reclaimed warm-pool sandbox ...`）而不是重新创建。

**步骤 3：验证凭据擦除**

在同一会话里让 agent 运行
`python3 -c "import os; print([k for k in os.environ if 'KEY' in k or 'TOKEN' in k])"`。
对比宿主机 `env | grep -i key` 的输出——沙箱子进程的列表应为空（或只剩你显式
配置在 `sandbox.environment` 里的项），因为 `build_sandbox_env` 在进程启动前就
擦掉了匹配 `*KEY*`/`*TOKEN*` 的继承变量。

## 常见坑

1. **`make dev` 下配置了不存在的 `sandbox.mounts.host_path`**。Local Provider 在
   Docker 部署（`make up`）里从 **gateway 容器内**检查该路径，宿主机路径若没有
   bind-mount 进容器就会被跳过。代码特意把这种静默失败升级为 ERROR 并给出
   修复指引（`local_sandbox_provider.py:234`）——别忽略这条日志。
2. **老 AIO 镜像跑 required-secrets 技能必失败**。`latest` 标签冻结的旧镜像没有
   `/v1/bash/exec`，env 注入命令直接报 404。这不是 bug，是镜像太老：pin
   `all-in-one-sandbox:1.11.0`（`config.example.yaml:1793` 附近的注释）。
3. **多实例共享 Docker 后端但没配 `ownership: type: redis`**。两个 Gateway 各自的
   空闲回收器会把对方正在使用的容器当成孤儿回收，用户看到 502/connection refused
   （issue #4206 的原始事故形态）。单实例用 `memory` 没问题，多实例必须 Redis，
   并把 TTL（`renewal_interval_seconds × ttl_multiplier`）按你的 Redis 可用性目标
   取值。
4. **本地沙箱开 `allow_host_bash: true` 后以为还有技能隔离**。host bash 子进程可以
   用规范路径绕过 `PathMapping`，所以 `supports_agent_skill_isolation` 会动态变
   `False`，显式技能白名单的 Agent 会被中间件直接拒绝（fail closed），而不是
   "降级但继续"。
5. **远程 Provider 下上传文件后 agent 看不见**。`thread_data_mounts` 对
   远程/provisioner 后端默认 `false`，上传需要显式同步；如果部署并没有真正共享
   线程目录却把它设成 `true`，上传同步被跳过，agent 在沙箱里看不到文件——
   配置注释的原话是"a false positive makes uploads unavailable"。
6. **改了 `sandbox.environment` 但新会话没生效**。Provider 是进程级单例，
   config 热编辑对**新 acquire** 生效，但已缓存的 LocalSandbox 映射表/环境快照要等
   下一次 acquire 重建或 Provider reset；拿不准就重启 Gateway。

## 下一步

- **第 9 章**（`docs/tutorials/09-multi-agent.md`）：子代理与 lead agent **共享同一个
  线程沙箱**——每个子代理以 `subagent:{task_id}` 为租约 owner 和命令作用域接入本章
  的 lease 机制，AIO 为每个作用域维持独立持久会话。读完本章再看第 9 章的
  "共享沙箱执行生命周期"会有完全不同的体感。
- **第 10 章**（`docs/tutorials/10-memory.md`）：沙箱管"执行"，记忆管"跨会话知识"——
  两者共同构成 Agent 的长期工作环境。
