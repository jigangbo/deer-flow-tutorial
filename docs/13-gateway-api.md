# 第 13 章 Gateway API 与编程接入

> 第 12 章里，IM 渠道和定时任务都是 Gateway API 的"内部用户"。本章把你——外部
> 开发者——变成同类用户：REST 路由全景、LangGraph 兼容层、文件上传协议、浏览器
> WebSocket，最后用内嵌 `deerflow.client.DeerFlowClient` 在自己的 Python 程序里
> 驱动同一条 run 生命周期。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| API 官方参考 | `backend/docs/API.md` |
| Gateway 路由目录 | `backend/app/gateway/routers/`（40 个路由模块） |
| run 启动核心 | `backend/app/gateway/services.py:2206`（`start_run`）、`services.py:2876`（`launch_scheduled_thread_run`） |
| 文件上传路由 | `backend/app/gateway/routers/uploads.py:394` |
| 上传协议文档 | `backend/docs/FILE_UPLOAD.md` |
| 流式设计（两条路径） | `backend/docs/STREAMING.md` |
| 内嵌客户端 | `backend/packages/harness/deerflow/client.py:177` |
| nginx LangGraph 重写 | `docker/nginx/nginx.conf:107` |
| nginx 浏览器 WebSocket | `docker/nginx/nginx.conf:254` |
| nginx 配置测试 | `backend/tests/test_nginx_browser_websocket.py` |
| 前端连接约定 | `docs/ARCHITECTURE.md` §4（`NEXT_PUBLIC_LANGGRAPH_BASE_URL=/api/langgraph`） |

## 13.0 学习目标

读完本章，你应该能够：

1. 在 40 个路由模块中快速定位需要的能力，并说出 thread/run 生命周期与
   PAT 权限 allowlist 的关系；
2. 用标准 LangGraph SDK 或裸 HTTP 直连 DeerFlow（不需要单独的 LangGraph Server），
   解释 `/api/langgraph/*` → `/api/*` 的重写契约；
3. 走通文件上传协议：`.upload-*.part` 原子发布、markitdown 转换、重复文件 `_N`
   后缀与虚拟路径映射；
4. 说明为什么 nginx 必须把 `/browser/stream` 的 WebSocket 正则放在通用 threads
   正则之前；
5. 用 `DeerFlowClient` 完成一次带文件上传与产物回收的完整 run。

## 13.1 REST 路由全景

Gateway 是一个 FastAPI 应用（`backend/app/gateway/`），路由按业务域拆成 40 个模块
（`ls backend/app/gateway/routers/`）。按用途分组：

| 分组 | 模块 | 覆盖能力 |
| --- | --- | --- |
| **对话核心** | `threads.py`、`thread_runs.py`、`runs.py`、`thread_activity.py`、`trash.py`、`suggestions.py` | thread CRUD/search/state/history/branches/compact/goal、run 创建/流式/等待/取消/join |
| **LangGraph 兼容** | `assistants_compat.py` | LangGraph SDK 的 assistants 语义 |
| **文件** | `uploads.py`、`artifacts.py` | 上传、列表、删除、产物读取 |
| **记忆与知识** | `memory.py`、`knowledge.py`、`project_documents.py`、`project_thread_files.py` | 记忆 CRUD/导入导出、只读知识检索、项目资料库 |
| **模型/MCP/技能** | `models.py`、`managed_models.py`、`mcp.py`、`mcp_tasks.py`、`personal_mcp.py`、`skills.py`、`skill_mutations.py`、`plugins.py`、`integrations.py` | 模型列表、MCP 配置热编辑、长任务、技能管理 |
| **自动化** | `scheduled_tasks.py`、`subagents.py`、`subagent_batches.py` | 第 12 章的定时任务、子代理 |
| **IM** | `channels.py`、`channel_connections.py`、`im_notification_preferences.py`、`github_webhooks.py` | 渠道运行时、用户连接绑定、通知偏好、GitHub webhook |
| **平台** | `auth.py`、`admin_users.py`、`features.py`、`capabilities.py`、`console.py`、`config.py`（gateway 根） | 登录/PAT、特性开关、能力查询 |

`backend/docs/API.md` 是权威参考（2300+ 行），本节只讲"接入视角"必须知道的四件事。

### 13.1.1 两套 API、一个入口

`backend/docs/API.md` §Overview：

> 1. **LangGraph-compatible API** — Agent interactions, threads, and streaming (`/api/langgraph/*`)
> 2. **Gateway API** — Models, MCP, skills, uploads, and artifacts (`/api/*`)

所有流量统一走 Nginx 的 2026 端口（`docs/ARCHITECTURE.md` §2：Nginx 是唯一公网
入口，Gateway 的 8001 从不发布）。对外编程接入也请走 2026——直连 8001 只适合
本机调试。

### 13.1.2 三种认证身份

`backend/docs/API.md` §Authentication：

| 身份 | 凭证 | 适用 |
| --- | --- | --- |
| 浏览器会话 | 登录签发的 `access_token` cookie | 前端 |
| **PAT（个人访问令牌）** | `Authorization: Bearer dfp_...` | CI、脚本、集成 |
| 内部认证 | 内部 owner 头（`AUTH_SOURCE_INTERNAL`） | scheduler、IM 渠道（第 12 章的信任边界） |

PAT 的关键约束（`API.md:69-161`）：

- 管理 PAT 必须用**交互会话**（PAT 不能造 PAT），raw token 只在创建响应里出现
  一次，服务端只存 SHA-256 摘要；
- `scopes` 是 route 权限的子集：`threads:read/write/delete`、
  `runs:create/read/cancel`——PAT 只能**收窄**所属用户的权限，不能放大；
- **路由级默认拒绝**：PAT 只被准入 thread/run 生命周期路由（`API.md:140-151`
  列出了精确清单，含 `/compact`、`/runs/{run_id}/cancel`、`POST /api/runs/stream|wait`
  等）；memory、agents、MCP/skills 配置、uploads 等其余路由对 PAT 一律 403——
  这是外层边界，scope 只约束带权限装饰器的路由；
- 带 `Authorization` 头但校验失败的请求是硬 401，**永不回退到 session cookie**；
  PAT 永远不携带 admin 能力；
- 细粒度到"取消能力"：`?action=interrupt|rollback`、`multitask_strategy=interrupt|rollback`
  也要求 `runs:cancel`（`API.md:134-139`）。

### 13.1.3 run 创建：幂等键与兼容性

`POST /api/langgraph/threads/{thread_id}/runs`（`API.md:254`）接受可选
`Idempotency-Key` 头：同一用户 + thread + key 重试复用已存在的 run 而不是再次执行；
key 跨 `/runs`、`/runs/stream`、`/runs/wait` 共享，改动 `input`/`assistant_id`
的重试返回 409。**每个有意的用户动作生成新 key，只在不确定的 HTTP 结果后重试时复用**
——第 12 章 IM 渠道的"平台重投递拿到同一条已准入 run"正是靠它实现。

兼容性方面的硬规则（`API.md:347-357`）：

- 支持的 `stream_mode`：`values`、`messages-tuple`、`custom`、`updates`、`debug`、
  `tasks`、`checkpoints`；`messages`、`events`、`tools` 等不支持模式在 run 创建前
  返回 422，DeerFlow **不会**用 `values` 顶替；
- 支持的并发策略：`reject`/`rollback`/`interrupt`；不支持直接 422 的选项：
  `webhook`、`stream_resumable=true`、`after_seconds`、`feedback_keys`、非空
  `on_completion`、`if_not_exists="reject"`、`multitask_strategy="enqueue"`，
  以及未声明的 SDK 选项（`checkpoint_during`、`durability`）——**显式拒绝而非
  静默丢弃**。

### 13.1.4 无状态流式端点与 Content-Location

最快接入路径不需要预建 thread（`API.md` §Stateless Stream Run，`API.md:619`）：

```http
POST /api/langgraph/runs/stream
Content-Type: application/json
Accept: text/event-stream
```

Gateway 自动建 thread，并在响应头返回两个标识符：

```http
Content-Location: /api/threads/{thread_id}/runs/{run_id}
```

客户端应解析此头的 `thread_id`（路径以 `/runs/{run_id}` 结尾），下一轮通过
`config.configurable.thread_id` 带回来延续会话。SSE 事件协议本身（`messages-tuple`、
有界 `values` 快照、`task_*` 自定义事件、`stream_subgraphs` 命名空间）第 6 章已
详拆，本章不重复；API 调用者只需记住两点：`stream_mode` 要显式列出想要的模式，
且断线恢复依赖 SSE `Last-Event-ID`（`backend/docs/STREAMING.md` 消费者对比表）。

## 13.2 LangGraph 兼容层：标准 SDK 直连

`docs/ARCHITECTURE.md` §2 的入口契约：

> `/api/langgraph/*` → Gateway's LangGraph-compatible runtime (rewritten to native `/api/*`)

nginx 侧的实现（`docker/nginx/nginx.conf:106-109`）：

```nginx
        # LangGraph-compatible API routes served by Gateway.
        # Rewrites /api/langgraph/* to /api/* before proxying to Gateway.
        location /api/langgraph/ {
            rewrite ^/api/langgraph/(.*) /api/$1 break;
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
```

这一条 rewrite 意味着：**标准 `@langchain/langgraph-sdk`（前端同款）或任何
LangGraph 客户端把 `base_url` 指到 `http://localhost:2026/api/langgraph` 即可
直连 DeerFlow**——不需要单独部署 LangGraph Server。其余代理参数都是为长请求
服务的：`proxy_buffering off` + `X-Accel-Buffering no`（SSE 不缓冲）、
`client_max_body_size 20M` + `proxy_request_buffering off`（超长粘贴的 prompt
不再撞 nginx 默认 1M 限制，issue #3952）、三个 600s 超时（长 run 不被 504）。

前端的默认连接正是这条路径：`NEXT_PUBLIC_LANGGRAPH_BASE_URL=/api/langgraph`、
`NEXT_PUBLIC_BACKEND_BASE_URL=`（空），都经 nginx 同源转发（`docs/ARCHITECTURE.md` §4）。

## 13.3 文件上传协议

### 13.3.1 端点与规模限制

`backend/app/gateway/routers/uploads.py` 暴露四个端点：

| 端点 | 行号 | 作用 |
| --- | --- | --- |
| `POST /api/threads/{thread_id}/uploads` | `uploads.py:394` | multipart 上传，一个或多个文件 |
| `GET /api/threads/{thread_id}/uploads/limits` | `uploads.py:494` | 查询限制（前端选择文件前提示） |
| `GET /api/threads/{thread_id}/uploads/list` | `uploads.py:505` | 列出已上传文件 |
| `DELETE /api/threads/{thread_id}/uploads/{filename}` | `uploads.py:517` | 删除 |

应用层限制默认 `uploads.max_files: 10`、`max_file_size: 52428800`（50 MiB）、
`max_total_size: 104857600`（100 MiB），超限返回 `413`
（`config.example.yaml:1705-1710`）。

### 13.3.2 原子发布：.upload-*.part

`backend/AGENTS.md` File Upload 段（第 288 行）：

> Gateway HTTP uploads stage `.upload-*.part` files hidden from upload listings,
> agent context, and sandbox listings/searches; publication is atomic after size
> validation.

即上传先写成隐藏的 `.upload-*.part` 暂存文件——上传列表、agent 上下文、沙箱
列表/搜索都看不见它——大小校验通过后**原子重命名**发布。这套设计保证并发/中断
场景不会留下半截可见文件；启动清扫会把超过 24 小时的孤立 `.part` 清掉（可能是
另一副本仍在写入），`st_nlink > 1` 的别名（已发布文件的多链接）任何年龄都移除。
`FILE_UPLOAD.md:32-34` 同时说明反方向：用户**上传**名为 `.upload-*.part` 的文件
会被 400 拒绝（含 Windows 去尾点/空格/大小写变体），整批先检查再写入，不会留下
部分上传。

### 13.3.3 文档转换与命名

PDF/PPT/Excel/Word 经 `markitdown` 转为 Markdown（`backend/AGENTS.md:286`：
"one conversion worker per request"），同名占用追加 `_N` 后缀，转换伴随文件
（companion）带原文件 mtime/ctime 归属记录，大纲只读记录指定的 Markdown。
注意安全默认值（`config.example.yaml:1711-1714`）：

```yaml
  # Automatic Office/PDF conversion runs on the backend host before sandbox
  # isolation applies. Keep this disabled unless uploads come from a fully
  # trusted source and you intentionally accept host-side parser risk.
  auto_convert_documents: false
```

自动转换发生在**沙箱隔离之前的主机上**，所以默认关闭——这是解析器风险的
明确取舍。

### 13.3.4 三套路径与"线程目录优先"

`FILE_UPLOAD.md` 的路径映射表：

| 视角 | 路径 |
| --- | --- |
| Agent（沙箱内） | `/mnt/user-data/uploads/document.pdf`（虚拟路径） |
| 实际存储 | `backend/.deer-flow/threads/{thread_id}/user-data/uploads/document.pdf` |
| 前端/HTTP | `/api/threads/{thread_id}/artifacts/mnt/user-data/uploads/document.pdf` |

上传流程是"线程目录优先"：先写权威存储，本地沙箱直接用线程目录；非本地沙箱
默认 `acquire_async` 后同步到 `/mnt/user-data/uploads/*`；若 Gateway 与远端沙箱
挂载同一份线程 user-data（共享 PVC/NFS/hostPath），可设
`sandbox.thread_data_mounts: true` 跳过逐文件同步——**不确定时省略并保留自动
检测**，错误设 true 会导致文件在沙箱内不可见（`FILE_UPLOAD.md` 上传流程节）。
上传/列表/删除的文件系统操作经 `deerflow.utils.file_io.run_file_io` 卸载
（backend `AGENTS.md:289`），保持事件循环畅通。

## 13.4 浏览器 WebSocket 与 nginx 正则顺序

`/api/threads/{thread_id}/browser/stream` 是浏览器实时能力（Live 流）的
WebSocket 端点。nginx 侧（`docker/nginx/nginx.conf:254-269`）：

```nginx
        location ~ ^/api/threads/[^/]+/browser/stream {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            ...
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_cache_bypass $http_upgrade;

            # Long-lived Live stream: keep the upgraded connection open.
            proxy_connect_timeout 600s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
        }

        # Custom API: Other endpoints under /api/threads
        location ~ ^/api/threads {
            ...
        }
```

**顺序是硬约束**：nginx 匹配正则 location 时取**第一个命中**的。若通用的
`^/api/threads` 写在前面，WebSocket 升级请求会被它截走——没有 `Upgrade` 头，
连接降级为普通 HTTP，浏览器流静默失效。根 `AGENTS.md` 明确要求
"Keep the dedicated `/api/threads/{thread_id}/browser/stream` WebSocket regex
before the generic threads regex in Docker, local and Helm nginx configs"，
并由 `backend/tests/test_nginx_browser_websocket.py` 把这条约束钉进 CI——
改动 nginx 配置时这个测试会拦住顺序回退。

## 13.5 源码走读：DeerFlowClient（内嵌客户端）

### 13.5.1 为什么要第二条路径

`backend/docs/STREAMING.md` TL;DR 给出定位：

> DeerFlow 有**两条并行**的流式路径：**Gateway 路径**（async / HTTP SSE / JSON
> 序列化）服务浏览器和 IM 渠道；**DeerFlowClient 路径**（sync / in-process /
> 原生 LangChain 对象）服务 Jupyter、脚本、测试。它们**无法合并**——消费者模型
> 不同。

Gateway 的 RunManager、StreamBridge、JSON 序列化全部是为了跨网络边界送事件；
生产者与消费者同进程时这套东西是纯开销。文档还记录了三个被否决的复用方案
（async 化 break 生态、线程池桥接引入复杂度、给 worker.py 加死分支），结论是
**两条路径的事件处理相似但不共享是刻意设计**。

`backend/packages/harness/deerflow/client.py:1` 的模块 docstring：

```python
"""DeerFlowClient — Embedded Python client for DeerFlow agent system.

Provides direct programmatic access to DeerFlow's agent capabilities
without requiring LangGraph Server or Gateway API processes.

Usage:
    from deerflow.client import DeerFlowClient

    client = DeerFlowClient()
    response = client.chat("Analyze this paper for me", thread_id="my-thread")
    print(response)

    # Streaming
    for event in client.stream("hello"):
        print(event)
"""
```

它在 harness 包里（不在 `app/`），所以不依赖 FastAPI：`docs/ARCHITECTURE.md` §3
说"embedded Python client used by scheduled tasks and tests to drive the same
run lifecycle programmatically"——注意它组装的是**同一个** `build_middlewares()`
中间件链与工具集（`client.py:36` 导入了 `build_middlewares`），行为与 Gateway run
一致，只是没有 HTTP/RunManager 层。

### 13.5.2 构造与懒加载 agent

构造函数（`client.py:211`）的关键参数与行为：

- `config_path`：指定 `config.yaml`（None 用默认解析）；
- `checkpointer`：**多轮对话的前提**——`client.py:184-186` 的 Note 写明，没有
  checkpointer 时每次 `stream()`/`chat()` 都是无状态的，`thread_id` 只用于文件
  隔离（上传/产物）；
- `model_name` / `thinking_enabled` / `subagent_enabled` / `plan_mode` /
  `agent_name` / `available_skills` / `middlewares` / `environment`：与 Gateway
  `config.configurable` 语义一一对应的开关；
- agent **懒创建**：第一次调用才构建，配置键（模型、技能等）变化时自动重建
  （`client.py:275-280`）；长驻进程里记忆更新、技能安装后用 `reset_agent()`
  （`client.py:282`）强制刷新系统提示词。

### 13.5.3 stream/chat 与事件归一

`stream()`（`client.py:859`）是同步生成器，产出 `StreamEvent`
（`client.py:135`）：

```python
StreamEventType = Literal["values", "messages-tuple", "custom", "end"]

@dataclass
class StreamEvent:
    """A single event from the streaming agent response.

    Event types align with the LangGraph SSE protocol:
        - ``"values"``: State snapshot (title, messages, artifacts, summary_text).
        - ``"messages-tuple"``: Per-message update (AI text, tool calls, tool results).
        - ``"end"``: Stream finished.
    """
```

事件类型与 SSE 协议对齐——消费者可以在 HTTP 流式与内嵌模式之间切换而不改事件
处理逻辑（`_stream_turn` 的 docstring 明确了这一契约）。token 级细节：
`messages-tuple` 对 AI 文本以 **delta** 形式发出，每条带稳定 `id`。
`stream()` 还有两个值得注意的实现细节（`client.py:877-899`）：trace id 只在每次
`next()` 步骤周围绑定（sync generator 与调用者共享上下文，跨 `yield` 绑定会泄漏
ContextVar）；generator 被放弃时 `close()` 仍会在绑定 id 下完成日志与回调清理。

`chat()`（`client.py:1314`）是便捷封装：

```python
    def chat(self, message: str, *, thread_id: str | None = None, **kwargs) -> str:
        """Send a message and return the final text response.

        Convenience wrapper around :meth:`stream` that accumulates delta
        ``messages-tuple`` events per ``id`` and returns the text of the
        **last** AI message to complete.  Intermediate AI messages (e.g.
        planner drafts) are discarded — only the final id's accumulated
        text is returned.
        """
```

累加规则由 `_AIMessageAccumulator`（`client.py:153`）实现：按消息 id 分桶拼接，
"metadata-only 更新不选新 id"，最后取最后一个 content-bearing AI 消息 id 的全文。
无头 CLI 也用同一规则挑最终答案。

### 13.5.4 上传与产物回收

`upload_files()`（`client.py:1754`）与 Gateway `POST /uploads` 行为对齐：

- **先整批验证再落盘**（"Validate all files upfront to avoid partial uploads"）：
  不存在抛 `FileNotFoundError`，非普通文件、不安全或保留名（`.upload-*.part`）
  抛 `ValueError`；同批重复名走 `claim_unique_filename` 的 `_N` 后缀逻辑；
- PDF/PPT/Excel/Word 转 Markdown（转换 worker 复用，已在事件循环内时不新建线程池）；
- 返回结构匹配 Gateway `UploadResponse` schema（含 `skipped_files`）——
  目标名是符号链接或其他非常规文件时跳过并列出，绝不经符号链接写入。

`get_artifact()`（`client.py:1973`）回收产物：

```python
    def get_artifact(self, thread_id: str, path: str) -> tuple[bytes, str]:
        """Read an artifact file produced by the agent.

        Args:
            path: Virtual path (e.g. "mnt/user-data/outputs/file.txt").

        Returns:
            Tuple of (file_bytes, mime_type).
        """
        validate_thread_id(thread_id)
        try:
            actual = get_paths().resolve_virtual_path(thread_id, path, user_id=get_effective_user_id())
        except ValueError as exc:
            if "traversal" in str(exc):
                from deerflow.uploads.manager import PathTraversalError

                raise PathTraversalError("Path traversal detected") from exc
            raise
```

入参是**虚拟路径**（`mnt/user-data/outputs/...`），解析到真实线程目录，路径穿越
显式转成 `PathTraversalError`——与 Gateway artifacts 路由同一套 `get_paths()`
解析器。

其余常用方法：`list_models()`（`client.py:1342`，返回结构对齐 Gateway
`ModelsListResponse`）、`list_skills()`（`client.py:1369`）、`get_memory()` /
`import_memory()`（`client.py:1393`、`1409`）、`list_threads()`（`client.py:762`）。

## 动手实验

写一个 Python 脚本，用 `DeerFlowClient` 完成"上传 CSV → 让 agent 生成图表脚本
并产出结果文件 → 回收产物"的完整闭环。在 `backend/` 目录下运行（依赖已由
`make install` 装好）：

```python
# run_embedded.py -- 放在 backend/ 目录外任意位置，或 backend/ 下均可
from pathlib import Path

from deerflow.client import DeerFlowClient
from langgraph.checkpoint.memory import MemorySaver

# 1) 构造客户端：MemorySaver 提供多轮上下文（生产可换 SqliteSaver）
client = DeerFlowClient(
    thinking_enabled=True,
    plan_mode=True,          # 观察第 11 章的 write_todos
    checkpointer=MemorySaver(),
)

thread_id = "tutorial-embedded-run"

# 2) 上传本地 CSV（自动获得 _N 后缀与可选 Markdown 转换）
csv_path = Path("sample.csv")          # 自备一个小 CSV
result = client.upload_files(thread_id, [csv_path])
print(result["message"])
virtual = result["files"][0]["virtual_path"]   # /mnt/user-data/uploads/sample.csv

# 3) 流式驱动一次 run
events = []
for event in client.stream(
    f"请用 Python 分析 {virtual}，把统计摘要写进 outputs/summary.txt 并画一张分布图",
    thread_id=thread_id,
):
    events.append(event)
    if event.type == "messages-tuple" and event.data.get("type") == "ai":
        print(event.data.get("content", ""), end="", flush=True)
print()

# 4) 产物回收：按虚拟路径读取 outputs 下的文件
for artifact in ("mnt/user-data/outputs/summary.txt",):
    try:
        data, mime = client.get_artifact(thread_id, artifact)
        print(f"\n--- {artifact} ({mime}, {len(data)} bytes) ---")
        print(data.decode("utf-8", errors="replace")[:500])
    except FileNotFoundError:
        print(f"\n{artifact} 不存在（agent 未产出）")

# 5) 配置查询（与 Gateway API 同构）
print(client.list_models()["models"][0]["name"])
print(len(client.list_skills()["skills"]))
```

观察点：

1. `events` 里 `values` 事件的 `summary_text` 是否为空（短对话不触发摘要），
   `artifacts` 字段是否随 run 更新；
2. 打开 `backend/.deer-flow/threads/tutorial-embedded-run/user-data/uploads/`，
   对照上传响应里的 `path` / `virtual_path` / `artifact_url` 三套路径；
3. 把 `checkpointer` 去掉再跑一次——第二轮对话 agent 不再记得第一轮，验证
   `client.py:184` 的"无 checkpointer 即无状态"；
4. 想走 HTTP 路径对照？用同一 prompt 打
   `POST http://localhost:2026/api/langgraph/runs/stream`（先 `curl` 上传文件到
   `/api/threads/{thread_id}/uploads`），从 `Content-Location` 头取 `thread_id`，
   事件形状与 `StreamEvent` 一一对应。

## 常见坑

1. **多轮对话没传 checkpointer**——每次 `chat()` 都是全新会话（thread_id 只隔离
   文件）。嵌入式用法必须自己提供 checkpointer；Gateway 路径则由 `database:` 配置
   自动装配，两者行为差异常让从 HTTP 切到内嵌的开发者困惑。
2. **内嵌客户端配置"不生效"**——agent 在首次调用时构建并按配置键缓存；运行中途
   改了 `config.yaml` / 装了新技能后，长驻进程要显式 `reset_agent()`（`client.py:282`）。
3. **PAT 调 uploads 返回 403**——PAT 是路由级默认拒绝加 scope 双重约束，
   uploads/memory/MCP 配置等不在 allowlist 里（`API.md:140-156`）。上传文件请用
   session cookie 或内嵌客户端，PAT 只管 thread/run 生命周期。
4. **直连 8001 端口绕过 nginx**——功能上多数可用，但会丢失 `/api/langgraph` 重写
   之外的代理语义（20M body、600s 超时、WebSocket 升级头），且违背回环默认绑定
   的部署模型。编程接入请走 `http://localhost:2026`。
5. **自己改 nginx 把 browser/stream 正则挪到后面**——WebSocket 静默降级，前端
   Live 流失效；`backend/tests/test_nginx_browser_websocket.py` 会拦住这类改动，
   CI 红了先检查 location 顺序。
6. **给 run 传不支持的选项期待静默忽略**——DeerFlow 对不支持的 `stream_mode`、
   `webhook`、`after_seconds`、未声明 SDK 选项一律 422（`API.md:347-357`）。
   这是"显式失败优于静默偏离"的设计，写 SDK 封装时要把 422 当作参数错误而不是
   服务端故障。
7. **`thread_data_mounts: true` 设错环境**——Gateway 与沙箱没有真挂载同一份
   user-data 时，上传文件在沙箱内不可见且不报错。拿不准就省略，保留自动检测
   （`FILE_UPLOAD.md` 上传流程节）。

## 下一步

你已经能从任何 Python 程序、任何 LangGraph SDK 客户端驱动 DeerFlow。接下来是
"改它"：harness 与 app 的分层边界、TDD 门禁、版本锁步——动手改核心之前必读的
工程规范，见第三篇《第 14 章 架构分层与开发规范（二次开发前必读）》
（`docs/TUTORIAL_OUTLINE.md` 第 14 章小节）。
