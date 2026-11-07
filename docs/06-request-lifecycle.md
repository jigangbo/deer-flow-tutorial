# 第 6 章 一次请求的一生：Agent 运行时全链路

## 6.0 学习目标

读完本章，你应该能够：

1. 画出一次对话请求的端到端时序：前端 `core/threads/` → Nginx `/api/langgraph/*` →
   Gateway 的 `start_run()` → `RunManager + run_agent() + StreamBridge` → SSE 流回前端；
2. 说清楚 `make_lead_agent()` 如何组装 lead agent，并**逐一列出**完整中间件链上的
   每个中间件类名与所在文件行号，理解"模型调用前依次执行"的顺序从哪里来；
3. 解释 `ThreadState` 在 LangGraph `AgentState` 之上扩展了哪些字段（`sandbox`、
   `artifacts`、`thread_data`、`title`、`todos`、`viewed_images`…），以及每个字段的
   reducer 语义；线程数据为什么落在 `backend/.deer-flow/threads/{thread_id}/`；
4. 掌握 SSE 流协议的四种帧：`messages-tuple`（token 级增量）、有界 `values` 快照、
   `task_*` 自定义事件（子代理进度）、以及 `stream_subgraphs` 的 `values|<ns>` 命名
   空间帧，外加 `heartbeat` / `gap` / `end` 三个控制帧；
5. 用脚本抓取一次完整 SSE 流，把事件时序与中间件生效点对上号。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| LangGraph 图工厂注册 | `backend/langgraph.json:9`（`"lead_agent": "deerflow.agents:make_lead_agent"`） |
| HTTP 路由入口 | `backend/app/gateway/routers/thread_runs.py:1069`（`POST /{thread_id}/runs/stream`） |
| Run 准入 | `backend/app/gateway/services.py:2206`（`start_run`） |
| 后台执行 | `backend/packages/harness/deerflow/runtime/runs/worker.py:1000`（`run_agent`） |
| 流桥 | `backend/packages/harness/deerflow/runtime/stream_bridge/base.py:66`（`StreamBridge`） |
| SSE 消费端 | `backend/app/gateway/services.py:3060`（`sse_consumer`）、`backend/app/gateway/services.py:221`（`format_sse`） |
| 中间件链组装 | `backend/packages/harness/deerflow/agents/lead_agent/agent.py:485`（`build_middlewares`） |
| 共享运行时中间件 | `backend/packages/harness/deerflow/agents/middlewares/tool_error_handling_middleware.py:347`（`_build_runtime_middlewares`） |
| 状态定义 | `backend/packages/harness/deerflow/agents/thread_state.py:379`（`ThreadState`） |
| 流模式翻译 | `backend/packages/harness/deerflow/runtime/stream_modes.py:43`（`to_langgraph_stream_modes`） |
| 事件契约 | `backend/docs/RUN_EVENT_STREAM.md`、`backend/docs/STREAMING.md`、`backend/docs/middleware-execution-flow.md`、`backend/docs/THREAD_LIFECYCLE.md` |
| 递归/用量配置 | `config.example.yaml:120`（`recursion_limit`）、`config.example.yaml:96`（`token_usage`） |

---

## 6.1 概念讲解：一条请求要穿过哪些层

DeerFlow 的所有运行模式（本地 `make dev`、Docker、生产）都以同一条路径执行 agent：
Gateway 内嵌的 LangGraph 兼容运行时。`docs/ARCHITECTURE.md` §3 把这条路径概括为
`RunManager + run_agent() + StreamBridge`。拆开看，一次"用户在输入框敲下回车"会经历：

```
浏览器 (frontend/src/core/threads/)
  │  POST /api/langgraph/threads/{thread_id}/runs/stream
  ▼
Nginx :2026                      ← 唯一公网入口，/api/langgraph/* 重写为 Gateway 原生 /api/*
  ▼
FastAPI 路由 thread_runs.py:1069 → services.py::start_run (services.py:2206)
  │  准入检查（权限/幂等/模型白名单/run-context 信任边界）
  │  RunManager.create() 生成 RunRecord
  │  asyncio.create_task(run_agent(...))      ← agent 在后台任务里跑
  ▼
run_agent (runtime/runs/worker.py:1000)
  │  1. 读取 checkpoint → 2. 组图 make_lead_agent()
  │  3. agent.astream(stream_mode=["values","messages","custom"])
  │  4. 每个 chunk → serialize() → bridge.publish()
  ▼
StreamBridge (asyncio Queue / Redis Stream)   ← 生产者/消费者解耦
  ▼
sse_consumer (services.py:3060) → format_sse (services.py:221)
  │  "event: messages\ndata: {...}\n\n"
  ▼
HTTP SSE 流 → 前端 useStream hook
```

两个容易混淆的要点：

- **Gateway 与 LangGraph Server 的关系**：DeerFlow 没有部署独立的 LangGraph Server，
  而是在 Gateway 进程里内嵌了 LangGraph 兼容运行时。`backend/langgraph.json:9` 把
  `lead_agent` 图工厂声明为 `deerflow.agents:make_lead_agent`，标准 LangGraph SDK
  因此可以直连 DeerFlow——这是第 13 章的主题。
- **两条并行的流式路径**：`backend/docs/STREAMING.md` 开篇就强调，HTTP SSE 路径
  （async + Queue + JSON 序列化）与嵌入式 `DeerFlowClient.stream()`（sync、进程内、
  原生 LangChain 对象）**无法合并**，因为消费者模型根本不同。本章聚焦 Gateway 路径。

### 为什么需要 StreamBridge

`run_agent` 在一个 `asyncio.Task` 里跑图，而 HTTP 连接活在另一个 task 里。生产者和
消费者必须解耦：`StreamBridge` 抽象了这个队列，同时承担断线重连缓冲（`Last-Event-ID`
重放）、多订阅者 fan-out 和心跳。`runtime/stream_bridge/base.py:66` 定义了抽象接口：

```python
class StreamBridge(abc.ABC):
    async def publish(self, run_id: str, event: str, data: Any) -> None: ...
    async def publish_end(self, run_id: str) -> None: ...
    def subscribe(self, run_id, *, last_event_id=None, ...): ...
```

（摘自 `backend/packages/harness/deerflow/runtime/stream_bridge/base.py:92-100`，节选）

DeerFlow 提供两个实现：`MemoryStreamBridge`（单机默认）与 Redis 实现（多实例部署，
见第 20 章）。`stream_bridge.heartbeat_interval_seconds` 默认 15 秒（`backend/docs/STREAMING.md`
Gateway 路径一节）。

---

## 6.2 源码走读 A：HTTP 准入——`start_run`

SSE 端点定义在 `backend/app/gateway/routers/thread_runs.py:1069`：

```python
@router.post("/{thread_id}/runs/stream")
```

它调用 `services.py::start_run`（`backend/app/gateway/services.py:2206`）。这个函数是
**所有** run 创建路径的唯一咽喉（HTTP 路由、定时任务、IM 渠道都汇到这里），因此承担
了大部分安全检查。摘录开头（`backend/app/gateway/services.py:2233-2242`）：

```python
# Cancel-capability gate. interrupt/rollback strategies terminate an already
# active run — runs:cancel capability, not runs:create — so a create-only
# PAT must not reach them. Enforced here, the single choke point every
# run-creation path flows through (HTTP routes and internal launchers
# alike), so no entry point can bypass it; regenerate launches pass
# multitask_strategy="reject" and are unaffected.
require_cancel_permission_if(request, body.multitask_strategy != "reject")
```

讲解：注释直接点明设计意图——`interrupt` / `rollback` 这类 multitask 策略会终止
正在运行的其他 run，属于"取消"能力而非"创建"能力，所以只持有 `runs:create`
权限的凭证不能借道创建端点达到取消效果。把门禁放在唯一咽喉 `start_run` 里，
任何入口都无法绕过。

`start_run` 依次完成：

1. **线程 ID 校验与模型白名单**（`services.py:2244-2283`）：`model_name` 若提供，
   必须命中 `config.yaml → models` 允许列表，否则 400；
2. **run-context 信任边界**（见 `backend/AGENTS.md:189` 一节）：`body.context` 与
   `body.config` 都是客户端可写表面，服务端产生的键（`non_interactive`、
   `disable_clarification`、`github_token`）只对内部认证调用方生效；
3. **RunManager 准入**：`RunManager`（`backend/packages/harness/deerflow/runtime/runs/manager.py:334`）
   生成 `RunRecord`，做同线程并发准入与幂等重试去重；
4. **拉起后台任务**（`services.py:2831`）：`record.task = asyncio.create_task(worker)`，
   `worker` 即 `run_agent`；
5. **返回 SSE**：路由用 `StreamingResponse(sse_consumer(...))` 把 bridge 订阅变成
   HTTP 事件流。

## 6.3 源码走读 B：后台执行——`run_agent`

`run_agent`（`backend/packages/harness/deerflow/runtime/runs/worker.py:1000`）是整个
运行时的心脏，签名本身就是一份"运行一个 run 需要什么"的清单：

```python
async def run_agent(
    bridge: StreamBridge,
    run_manager: RunManager,
    record: RunRecord,
    *,
    ctx: RunContext,
    agent_factory: Any,
    graph_input: dict[str, Any] | Command | None,
    config: dict,
    thread_incarnation: str | None | object = _THREAD_INCARNATION_UNSET,
    stream_modes: list[str] | None = None,
    stream_subgraphs: bool = False,
    interrupt_before: list[str] | Literal["*"] | None = None,
    interrupt_after: list[str] | Literal["*"] | None = None,
    knowledge_scope: dict[str, Any] | None = None,
) -> None:
    """Execute an agent in the background, publishing events to *bridge*."""
```

（摘自 `backend/packages/harness/deerflow/runtime/runs/worker.py:1000-1016`）

讲解几个参数：

- `bridge` / `run_manager` / `record`：流桥、run 生命周期管理器、本次 run 的记录
  （含 `abort_event`，取消就是设置这个事件）；
- `agent_factory`：图工厂，Gateway 默认传 `make_lead_agent`；
- `stream_subgraphs`：是否订阅子图流。DeerFlow Web 前端**不开**子图流，子代理进度
  走根命名空间的 `task_*` 自定义事件（第 9 章）；开启后子代理帧带命名空间（见 6.6）。

`run_agent` 的主体很长（约 3000 行），但骨架是一个五步循环：

1. **预检**：读取 thread 的 checkpoint 状态，收集 `pre_existing_message_ids`——本轮
   之前已存在的消息 ID 集合，用于把历史里的错误回退标记与本轮区分开
   （`worker.py:1057-1061` 的注释解释了：没有这个过滤，一次历史残留会让同线程后续
   所有 run 都被误判为 `error`）；
2. **组图**：调用 `agent_factory(config)` → `make_lead_agent` → 完整中间件链组装
   （下一节）；
3. **流式执行**：`_stream_once`（`worker.py:1598`）内持有每线程的 checkpoint 锁，
   调 `agent.astream(input_payload, config=stream_config, stream_mode=lg_modes)`，
   对每个 chunk 做三件事：解析 `(mode, chunk, namespace)`、序列化、`bridge.publish`：
4. **终止提交**：写回最终状态（`success` / `error` / `interrupted`）、workspace 变更
   快照、token 用量聚合；
5. **收尾**：关闭 journal、释放沙箱租约、清理 bridge（`finally` 保证取消路径也执行）。

其中第 3 步的单模式分支最直观（`backend/packages/harness/deerflow/runtime/runs/worker.py:1604-1628`，节选）：

```python
async with _checkpoint_thread_lock(thread_id):
    if len(lg_modes) == 1 and not stream_subgraphs:
        single_mode = lg_modes[0]
        stream = agent.astream(input_payload, config=stream_config, stream_mode=single_mode)
        ...
        async for chunk in stream:
            if record.abort_event.is_set():
                broke_on_abort = True
                logger.info("Run %s abort requested — stopping", run_id)
                break
            ...
            sse_event = _lg_mode_to_sse_event(single_mode)
            single_payload = serialize(chunk, mode=single_mode)
            if single_mode == "values" and seq_stamper is not None:
                single_payload = await seq_stamper.stamp(single_payload)
            await bridge.publish(run_id, sse_event, single_payload)
```

讲解：`record.abort_event.is_set()` 是取消的协作式检查点——用户点"停止"后，下一次
chunk 到达时循环退出；`_checkpoint_thread_lock` 保证同一线程的 checkpoint 读改写
串行；`seq_stamper.stamp` 给 `values` 帧里的每条消息补上事件存储里的 feed 序号，
解决"摘要压缩后老消息在分页历史窗口之外、客户端无法定位"的问题（`worker.py:3820`
的 `_MessageSeqStamper` 文档字符串详述了 #4666）。

## 6.4 源码走读 C：图工厂与完整中间件链

### `make_lead_agent`：从 RunnableConfig 到编译后的图

LangGraph Server 通过 `backend/langgraph.json:9` 找到图工厂：

```json
"graphs": {
  "lead_agent": "deerflow.agents:make_lead_agent"
}
```

`make_lead_agent`（`backend/packages/harness/deerflow/agents/lead_agent/agent.py:845`）
是个薄包装，真正的组装在 `assemble_lead_agent`（`agent.py:850`）→
`_assemble_lead_agent`（`agent.py:967`）。后者做四类事：

1. **解析运行时选项**：模型名（请求 > 自定义 agent 配置 > 全局默认，`agent.py:1077`）、
   thinking/reasoning 优先级（`agent.py:1066-1069`）、`is_plan_mode`、`subagent_enabled`；
2. **技能与授权**：加载启用技能列表，经 `filter_available_skills_by_authorization`
   过滤（`agent.py:1052`），工具经 `apply_tool_authorization` 过滤（`agent.py:1360`）；
3. **组装工具**：`get_available_tools(...)`（第 7 章主角）+ `update_agent` 等额外工具；
4. **组装中间件**：调用 `build_middlewares`（`agent.py:485`），最后
   `create_agent(model=..., tools=..., middleware=..., system_prompt=..., state_schema=...)`
   交给 LangChain 的 `create_agent` 原语（`agent.py:1416-1423`）。

`build_middlewares` 前有一段珍贵的顺序注释（`backend/packages/harness/deerflow/agents/lead_agent/agent.py:474-484`）：

```python
# ThreadDataMiddleware must be before SandboxMiddleware to ensure thread_id is available
# UploadsMiddleware should be after ThreadDataMiddleware to access thread_id
# DanglingToolCallMiddleware patches missing ToolMessages before model sees the history
# SummarizationMiddleware should be early to reduce context before other processing
# TodoListMiddleware should be before ClarificationMiddleware to allow todo management
# TitleMiddleware generates title after first exchange
# MemoryMiddleware queues conversation for memory update (after TitleMiddleware)
# ViewImageMiddleware should be before ClarificationMiddleware to inject image details before LLM
# ToolErrorHandlingMiddleware should be before ClarificationMiddleware to convert tool exceptions to ToolMessages
# ModelContentCompatibilityMiddleware sanitizes model-incompatible URL content blocks in the request view; register near the end so it sees the near-final message list
# ClarificationMiddleware should be last to intercept clarification requests after model calls
```

讲解：LangChain `create_agent` 的钩子规则是——`before_agent` / `before_model` /
`wrap_model_call` 按列表正序执行，`after_model` / `after_agent` 按列表**反序**执行。
所以"列表最后的 `ClarificationMiddleware`"的 `after_model`/`wrap_tool_call` 最先
拦截模型输出。这个规则在 `backend/docs/middleware-execution-flow.md` 的"洋葱模型"
一节有完整推导，该文档强调：DeerFlow 的中间件链**不是洋葱，是管道**——大部分
中间件只用一个钩子，真正对称的只有 `SandboxMiddleware`（`before_agent` 获取 /
`after_agent` 释放）。

### 完整中间件链（lead agent）

中间件链分三段拼装：共享运行时段（`_build_runtime_middlewares`，`backend/packages/harness/deerflow/agents/middlewares/tool_error_handling_middleware.py:347`，末尾
`tool_error_handling_middleware.py:534` 一行 `middlewares = [*outer_wrappers, *thread_hooks, *tail]` 点明分层）+ lead 专属段（`build_middlewares`，`agent.py:542-820`）+
扩展合并（`compose_with_extensions`，`agent.py:791-820`）。下表按**列表位置**列出
默认配置全开时的完整链（✱ 表示条件启用）：

**共享运行时段 —— Layer 1 外层包装器**（`tool_error_handling_middleware.py:379-393`）

| # | 中间件类 | 定义位置 | 挂钩 |
| --- | --- | --- | --- |
| 1 | `InputSanitizationMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/input_sanitization_middleware.py:259` | `wrap_model_call`（最外层，净化注入标签） |
| 2 | `KnowledgeScopeMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/knowledge_scope_middleware.py:40` | `wrap_model_call` |
| 3 | `ToolOutputBudgetMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/tool_output_budget_middleware.py:1158` | `wrap_model_call`（超长工具输出落盘） |
| 4 | `ToolResultSanitizationMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/tool_result_sanitization_middleware.py:122` | `wrap_model_call`（远端工具结果净化） |
| 5✱ | `PiiRedactionMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/pii_redaction_middleware.py:396` | `wrap_model_call`（`pii_redaction.enabled`） |

**共享运行时段 —— Layer 2 线程钩子**（`tool_error_handling_middleware.py:396-409`）

| # | 中间件类 | 定义位置 | 挂钩 |
| --- | --- | --- | --- |
| 6 | `ThreadDataMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/thread_data_middleware.py:24` | `before_agent`（线程目录 + 首条消息打 run_id/时间戳） |
| 7 | `UploadsMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/uploads_middleware.py:49` | `before_agent`（注入上传文件清单，lead 专属；子代理不带） |
| 8 | `SandboxMiddleware` | `backend/packages/harness/deerflow/sandbox/middleware.py:56` | `before_agent` / `after_agent`（获取/释放沙箱，lazy 默认首工具调用才真正 acquire） |

**共享运行时段 —— Layer 3 工具执行尾**（`tool_error_handling_middleware.py:412-532`）

| # | 中间件类 | 定义位置 | 挂钩 |
| --- | --- | --- | --- |
| 9 | `DanglingToolCallMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/dangling_tool_call_middleware.py:183` | `wrap_model_call`（补悬空 ToolMessage） |
| 10 | `LLMErrorHandlingMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/llm_error_handling_middleware.py:445` | `wrap_model_call`（模型边界重试与回退消息） |
| 11✱ | `ToolReceiptMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/tool_receipt_middleware.py:45` | `wrap_tool_call`（回执台账，`verification.receipts_enabled`） |
| 12✱ | `ArtifactResolutionMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/artifact_resolution_middleware.py:31` | `wrap_tool_call`（解析参数里的 artifact 句柄） |
| 13✱ | `GuardrailMiddleware` | `backend/packages/harness/deerflow/guardrails/middleware.py:25` | `wrap_tool_call`（授权适配器 / 显式 guardrail provider） |
| 14 | `SandboxAuditMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/sandbox_audit_middleware.py:449` | `wrap_tool_call`（中风险结果重建） |
| 15✱ | `ReadBeforeWriteMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/read_before_write_middleware.py:209` | `wrap_tool_call`（未读先写拦截） |
| 16✱ | `HarnessGuardMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/harness_guard_middleware.py:207` | `wrap_tool_call`（`harness_guard.enabled`） |
| 17✱ | `ToolProgressMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/tool_progress_middleware.py:254` | `wrap_tool_call`（结果质量相位机，默认关） |
| 18 | `ToolErrorHandlingMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/tool_error_handling_middleware.py:62` | `wrap_tool_call`（异常转 ToolMessage、盖 `deerflow_tool_meta`） |
| 19✱ | `ArtifactCaptureMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/artifact_capture_middleware.py:29` | `before_model`（捕获工具产物引用） |

**Lead 专属段**（`backend/packages/harness/deerflow/agents/lead_agent/agent.py:567-778`）

| # | 中间件类 | 定义位置 | 挂钩 | 条件 |
| --- | --- | --- | --- | --- |
| 20 | `DynamicContextMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/dynamic_context_middleware.py:364` | `wrap_model_call`（日期/记忆作为 `<system-reminder>` 注入首条 HumanMessage，系统提示保持静态以复用前缀缓存） | 总是 |
| 21 | `SkillActivationMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/skill_activation_middleware.py:118` | `wrap_model_call`（`/skill-name` 斜杠激活，第 7 章） | 总是 |
| 22✱ | `DeferredToolPromotionAuditMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/tool_promotion_audit_middleware.py:72` | 观察最终 `tool_search` Command | 有延迟工具 |
| 23 | `DurableContextMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/durable_context_middleware.py:300` | `before_model`/`wrap_model_call`（委派台账 + 摘要 + 已加载技能三个持久通道） | 总是 |
| 24✱ | `DeerFlowSummarizationMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/summarization_middleware.py:123` | `before_model`（上下文压缩，第 11 章） | `summarization` 配置启用 |
| 25✱ | `TodoMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/todo_middleware.py:124` | `before_model`/`after_model`/`wrap_model_call`（`write_todos`） | `is_plan_mode` |
| 26✱ | `TokenUsageMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/token_usage_middleware.py:353` | 用量展示 | `token_usage.enabled`（`config.example.yaml:96`） |
| 27 | `TitleMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/title_middleware.py:37` | `after_model`（首轮后自动生成标题） | 总是 |
| 28✱ | `MemoryMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/memory_middleware.py:160` | `after_agent`（会话入队记忆抽取，第 10 章） | `memory_enabled` |
| 29✱ | `ViewImageMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/view_image_middleware.py:32` | `wrap_model_call`（图片 base64 注入请求视图，不进 checkpoint） | 模型 `supports_vision` |
| 30✱ | `McpRoutingMiddleware`（由 `build_mcp_routing_middleware` 构建，`backend/packages/harness/deerflow/tools/builtins/tool_search.py:341`） | `backend/packages/harness/deerflow/agents/middlewares/mcp_routing_middleware.py:30` | `after_model`（按 routing 关键词自动晋升延迟 MCP 工具） | 有带 routing 的延迟 MCP 工具 |
| 31✱ | `DeferredToolFilterMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/deferred_tool_filter_middleware.py:32` | `wrap_model_call`（未晋升的延迟工具 schema 对模型隐藏） | 有延迟工具 |
| 32 | `SystemMessageCoalescingMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/system_message_coalescing_middleware.py:121` | `wrap_model_call`（合并多条 SystemMessage；vLLM/Anthropic 等严格后端只接受首条） | 总是 |
| 33✱ | `SubagentLimitMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/subagent_limit_middleware.py:95` | `after_model`（截断超额并行 task 调用） | `subagent_enabled` |
| 34✱ | `LoopDetectionMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware.py:294` | `before_agent`/`after_model`/`wrap_model_call`/`after_agent`（循环检测，`loop_detection.enabled`） | 配置启用 |
| 35✱ | `TokenBudgetMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/token_budget_middleware.py:77` | 预算告警/硬停（`token_budget.enabled`，`config.example.yaml:106`） | 配置启用 |
| 36✱ | `CompletedSubagentUsageMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/token_usage_middleware.py:408` | 预算前回填已完成子代理用量 | 预算+用量同开 |
| 37 | `ModelContentCompatibilityMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/model_content_compatibility_middleware.py:204` | `wrap_model_call`（把 URL 来源的文件/图片块改写为文本占位，修复历史脏数据） | 总是 |
| 38✱ | 自定义 / 扩展中间件 | 经 `configured_extensions` 注入 | — | 配置了 `extensions.middlewares` 或扩展贡献 |
| 39 | `TerminalResponseMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/terminal_response_middleware.py:31` | `after_model`（空回复终端兜底） | 总是 |
| 40 | `ModelLengthFinishReasonMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/model_length_finish_reason_middleware.py:80` | `after_model`（`stop_reason=model_length_capped` 盖章并抑制工具调用） | 总是 |
| 41✱ | `SafetyFinishReasonMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/safety_finish_reason_middleware.py:99` | `after_model`（供应商安全终止时抑制工具执行） | `safety_finish_reason.enabled` |
| 42 | `ClarificationMiddleware` | `backend/packages/harness/deerflow/agents/middlewares/clarification_middleware.py:75` | `wrap_tool_call`（**永远最后**；拦截 `ask_clarification` 并 `Command(goto=END)`） | 总是 |
| 43✱ | `RunInputAdmissionMiddleware`（插到位置 0）/ `RunInputMiddleware`（追加到末尾） | `backend/packages/harness/deerflow/agents/middlewares/run_input_middleware.py:53` 与 `:80` | 输入准入 / `after_agent` 决定是否续跑 | run 带输入控制 |

最后由 `compose_with_extensions`（`agent.py:806-820`）把扩展贡献合并进栈。仓库里
另有一份纯 SDK 侧的组装函数 `_assemble_from_features`
（`backend/packages/harness/deerflow/agents/factory.py:205`），供不读 YAML 的
`create_deerflow_agent` 使用，顺序与上表一致——两条组装路径共用同一套顺序约定。

**为什么子代理只有 4 个共享中间件？** `build_subagent_runtime_middlewares`
（`tool_error_handling_middleware.py:572`）复用 `_build_runtime_middlewares` 但
`include_uploads=False`，再加 `SkillActivationMiddleware` 等少量成员。子代理共享
lead 线程的沙箱与 skill 投影，因此不重复做线程级准备。

## 6.5 源码走读 D：ThreadState 与 checkpoint

### ThreadState 定义

`ThreadState` 在 LangGraph `AgentState` 之上扩展（`backend/packages/harness/deerflow/agents/thread_state.py:379-398`）：

```python
class ThreadState(AgentState):
    sandbox: SandboxStateField
    thread_data: NotRequired[ThreadDataState | None]
    title: NotRequired[str | None]
    artifacts: Annotated[list[str], merge_artifacts]
    todos: Annotated[list | None, merge_todos]
    goal: Annotated[GoalState | None, merge_goal]
    goal_outcome: NotRequired[GoalOutcomeState | None]
    applied_run_inputs: NotRequired[dict | None]
    uploaded_files: NotRequired[list[dict] | None]
    viewed_images: Annotated[dict[str, ViewedImageData], merge_viewed_images]  # image_path -> metadata (no base64)
    promoted: Annotated[PromotedTools | None, merge_promoted]
    delegations: Annotated[list[DelegationEntry], merge_delegations]
    skill_context: Annotated[list[SkillEntry], merge_skill_context]
    tool_artifacts: Annotated[list[ArtifactEntry], merge_tool_artifacts]
    tool_artifact_processed: Annotated[list[str], merge_artifacts]
    task_notes: Annotated[dict | None, TaskNotesChannel(dict | None, merge_task_notes)]
    task_history: NotRequired[dict | None]
    summary_text: NotRequired[str | None]
    background_tasks: NotRequired[list[BackgroundTaskState]]
```

讲解要点：

- **`Annotated[..., reducer]` 是 LangGraph 的自定义归并语义**。例如
  `merge_artifacts`（`thread_state.py:103`）合并去重产物列表——`present_files`
  工具（第 7 章）返回 `Command(update={"artifacts": [...]})` 时靠它避免覆盖；
  `merge_todos`（`thread_state.py:139`）"None 表示节点没碰 todos，保留旧值"；
- **`sandbox` 字段的 reducer 会 fail-closed**：`merge_sandbox`（`thread_state.py:79-97`）
  允许幂等写入，但同一线程出现两个不同 `sandbox_id` 直接抛
  `ValueError("Conflicting sandbox state updates")`——这是隔离性 bug 的显式失败；
- **`viewed_images` 只存轻量元数据**：`ViewedImageData`（`thread_state.py:62-76`）
  的文档注释写明，图片字节按需从沙箱读取，base64 载荷不进 checkpoint（#4138）；
- **delta 模式**：`get_thread_state_schema(mode)`（`thread_state.py:521`）在
  `database.checkpoint_channel_mode == "delta"` 时返回把 `messages` 换成
  `DeltaChannel` 的 `DeltaThreadState`，checkpoint 只存增量，由
  `merge_message_writes`（`thread_state.py:431`）线性折叠。模式是**进程级冻结**的
  （`assemble_lead_agent` 里 `freeze_checkpoint_channel_mode`，`agent.py:874-887`），
  客户端无法通过 configurable 键切换。

### 线程数据目录

`ThreadDataMiddleware.before_agent`（`backend/packages/harness/deerflow/agents/middlewares/thread_data_middleware.py:82-122`）：

```python
@override
def before_agent(self, state: ThreadDataMiddlewareState, runtime: Runtime) -> dict | None:
    context = runtime.context or {}
    thread_id = context.get("thread_id")
    ...
    if self._lazy_init:
        # Lazy initialization: only compute paths, don't create directories
        paths = self._get_thread_paths(thread_id, user_id=user_id)
    else:
        paths = self._create_thread_directories(thread_id, user_id=user_id)
    ...
    return {
        "thread_data": {
            **paths,
        },
        "messages": messages,
    }
```

三个路径来自 `Paths` 的 `sandbox_work_dir / sandbox_uploads_dir / sandbox_outputs_dir`
（`thread_data_middleware.py:62-66`），布局是
`{DEER_FLOW_HOME}/threads/{thread_id}/user-data/{workspace,uploads,outputs}`。
默认 `DEER_FLOW_HOME` 是 `backend/.deer-flow`（`backend/AGENTS.md` backend dev 一节：
`make dev` 特意把该目录排除出 uvicorn 热重载监视）。沙箱内 agent 看到的是虚拟路径
`/mnt/user-data/...`，映射关系在第 8 章展开。

## 6.6 源码走读 E：SSE 流协议

### 模式名翻译：`messages-tuple` vs `messages`

`backend/packages/harness/deerflow/runtime/stream_modes.py:7-14` 定义了对外的
LangGraph Platform 兼容模式：

```python
type RunStreamMode = Literal[
    "values",
    "messages-tuple",
    "updates",
    "debug",
    "tasks",
    "checkpoints",
    "custom",
]
```

`to_langgraph_stream_modes`（`stream_modes.py:43`）把公开的 `"messages-tuple"` 翻译成
LangGraph 内部的 `"messages"`：

```python
def to_langgraph_stream_modes(raw: list[str] | str | None) -> list[str]:
    """Map public run modes to ``graph.astream`` modes without silent fallback."""
    modes = normalize_stream_modes(raw)
    mapped = ["messages" if mode == "messages-tuple" else mode for mode in modes]
    return list(dict.fromkeys(mapped))
```

讲解：`backend/docs/STREAMING.md` 用一整节解释"两套命名的由来"——Graph 层叫
`messages`，Platform SDK 层叫 `messages-tuple`，是同一概念的三个协议层别名。
`DeerFlowClient` 直调 `agent.stream()` 必须传 `"messages"`；IM 渠道走 HTTP SDK 必须传
`"messages-tuple"`。**两个字符串不能互相替代**。

### 序列化与 SSE 帧名

`serialize`（`backend/packages/harness/deerflow/runtime/serialization.py:164`）按模式
分发：`messages` 走 `serialize_messages_tuple`（`serialization.py:144`，把
`(chunk, metadata)` 变成 `[chunk.model_dump(), metadata]`）；`values` 走
`serialize_channel_values_for_api`（剥掉 `__pregel_*` 内部键与 `data:` base64 图片块）。

SSE 事件名与 LangGraph 模式一一对应（`backend/packages/harness/deerflow/runtime/runs/worker.py:3633-3642`）：

```python
def _lg_mode_to_sse_event(mode: str) -> str:
    """Map LangGraph internal stream_mode name to SSE event name.

    LangGraph's ``astream(stream_mode="messages")`` produces message
    tuples.  The SSE protocol calls this ``messages-tuple`` when the
    client explicitly requests it, but the default SSE event name used
    by LangGraph Platform is simply ``"messages"``.
    """
    # All LG modes map 1:1 to SSE event names — "messages" stays "messages"
    return mode
```

SSE 帧格式由 `format_sse`（`backend/app/gateway/services.py:221-234`）产出，
字段顺序 `event:` → `data:` → `id:`（可选）→ 空行，与 `useStream` hook 和
`langgraph-sdk` 解码器的期望一致。

### 子图命名空间帧

开启 `stream_subgraphs` 时，子代理帧必须带命名空间前缀，否则会覆盖 SDK 的线程视图
（#4399）。`_compose_sse_event`（`backend/packages/harness/deerflow/runtime/runs/worker.py:3797-3807`）：

```python
def _compose_sse_event(sse_event: str, namespace: tuple[str, ...]) -> str:
    """Namespace-qualified SSE event name, LangGraph Platform style.

    Root frames keep the bare event name; subgraph frames become
    ``mode|ns1|ns2`` so clients can tell them apart. The LangGraph SDK parses
    exactly this shape (``event.split("|").slice(1)``) and routes
    subagent-namespaced values away from the thread view.
    """
    if not namespace:
        return sse_event
    return "|".join((sse_event, *namespace))
```

讲解：根图帧保持裸事件名（`values`），子图帧变成 `values|<ns1>|<ns2>`。
`backend/AGENTS.md:12` 总结了消费者契约——根命名空间消费者（文件工具 chunk 批处理器、
子代理事件持久化、LLM 错误回退检测）忽略带命名空间的帧；Web 前端只用根命名空间的
`task_*` 自定义事件，不请求子图流。

### `task_*` 自定义事件

子代理委派进度通过 `custom` 流发出：`task_started` / `task_running` /
`task_completed` / `task_failed` 等载荷。持久化侧由
`subagents/step_events.py::subagent_run_event()` 映射为 `subagent.start` /
`subagent.step` / `subagent.end` 三类事件（`backend/docs/RUN_EVENT_STREAM.md`
Producers 一节的表格），再经 `GET /api/threads/{thread_id}/runs/{run_id}/events`
供历史子任务卡片恢复。事件存储的完整契约（信封字段、category 路由、`run.terminal`
权威结果）见 `backend/docs/RUN_EVENT_STREAM.md`。

### 控制帧：heartbeat、gap、end

- `heartbeat`：15 秒默认周期，SSE 注释帧 `": heartbeat\n\n"`；
- `gap`：重连游标已超出保留窗口时，网关在任何部分重放之前发送
  `event: gap` + `recovery: "reload_durable_state"`，客户端必须丢弃瞬时状态、
  重读 checkpoint 与持久化历史（`backend/docs/STREAMING.md` "有界历史与 gap 恢复"）；
- `end`：run 终止哨兵。

## 6.7 动手实验：抓一次完整 SSE 流

目标：绕过前端，用脚本直连 Gateway，观察事件时序并标注中间件生效点。全程离线可做
（只需要一个已配置的模型 Key，第 2 章的 `make dev` 环境即可）。

**步骤 0：处理认证。** 默认 `make dev` 启用了本地认证（首次访问 `/setup` 初始化
管理员，见 `backend/docs/AUTH_UPGRADE.md:127`）。脚本直连有两种选择：最简单的是
单用户模式——在启动 Gateway 前设置环境变量 `DEER_FLOW_AUTH_DISABLED=1`（非生产环境
生效，`backend/app/gateway/auth_disabled.py:15-23`）；或保持认证，先在浏览器登录，
再从开发者工具复制会话 Cookie，给下面的两个请求都加上 `-H "Cookie: <...>"`。

**步骤 1：创建线程。**

```bash
curl -s -X POST http://localhost:2026/api/threads \
  -H 'Content-Type: application/json' -d '{"metadata": {}}'
# 记下返回的 thread_id
```

**步骤 2：订阅 run 流。** 新建 `sse_capture.py`（放在仓库外任意目录，勿提交）：

```python
import json, sys, time
import httpx

thread_id = sys.argv[1]
url = f"http://localhost:2026/api/langgraph/threads/{thread_id}/runs/stream"
body = {
    "assistant_id": "lead_agent",
    "input": {"messages": [{"role": "user", "content": "用一句话介绍你自己"}]},
    "stream_mode": ["messages-tuple", "values", "custom"],
    "stream_subgraphs": False,
}
t0 = time.monotonic()
with httpx.stream("POST", url, json=body, timeout=120) as resp:
    event = None
    for line in resp.iter_lines():
        if line.startswith("event:"):
            event = line.split(":", 1)[1].strip()
        elif line.startswith("data:") and event:
            data = line.split(":", 1)[1].strip()
            size = len(data)
            print(f"{time.monotonic()-t0:7.3f}s  {event:<15} bytes={size}")
            if event == "values":
                # values 快照里能看到中间件写入的字段
                snapshot = json.loads(data)
                keys = sorted(k for k in snapshot if not k.startswith("__"))
                print(f"          values keys: {keys}")
            event = None
```

运行：`python sse_capture.py <thread_id>`。

**步骤 3：读输出、画时序。** 典型形状：

```
  0.1s  values          bytes=...      ← 首快照：messages 只含用户输入
  0.3s  messages        bytes=...      ← token 增量开始（AIMessageChunk）
  ...
  2.1s  messages        bytes=...      ← 最后一个 chunk 带 usage
  2.2s  values          bytes=...      ← 终快照：此时 title 可能已生成（TitleMiddleware）
  2.3s  end                            ← Run 终止
```

对照检查点：

- 首个 `values` 快照的键列表里应出现 `thread_data`（`ThreadDataMiddleware` 写入）、
  若上传过文件还有 `uploaded_files`（`UploadsMiddleware`）；
- 若在 UI 里开过 Plan Mode（`is_plan_mode`），终快照会多出 `todos` 键；
- 发一张图片并使用 vision 模型，会看到 `viewed_images` 出现（`ViewImageMiddleware`
  + `view_image` 工具），但消息里没有 base64——载荷只活在请求视图里；
- 把 `"stream_subgraphs"` 改为 `True` 并让 agent 委派子代理，事件名会出现
  `values|<namespace>` 形状（`_compose_sse_event`）；
- 长时间不操作的 run 期间插入观察，可看到 15 秒周期的 `: heartbeat` 注释帧。

**步骤 4（可选）：把事件与运行时事件存储对账。** 访问
`GET /api/threads/{thread_id}/runs/{run_id}/events`，对照
`backend/docs/RUN_EVENT_STREAM.md` 的类别表（`trace` / `message` / `middleware` /
`subagent` / `workspace`…），验证 `middleware:summarize`、`middleware:loop_detection`
等审计事件的 `category` 与文档一致。

## 6.8 常见坑

1. **把 `"messages"` 和 `"messages-tuple"` 传错层**：HTTP SDK 客户端要传
   `messages-tuple`，直接调 `agent.stream()` 要传 `messages`。传错不报错，只是收不到
   token 级事件（`backend/docs/STREAMING.md` 的 #1969 事故正是漏订阅 `messages`）。
2. **以为 `values` 是增量**：`values` 是节点级完整状态快照，`messages` 才是 token
   增量；前端按消息 ID 去重合并（`backend/docs/STREAMING.md` "消费语义"一节）。
3. **在中间件链上"随手"插中间件**：`ClarificationMiddleware` 必须最后
   （`agent.py:777-778` 的注释与不变式检查），`ThreadDataMiddleware` 必须先于
   `SandboxMiddleware`。扩展作者应使用 `@Next`/`@Prev` 锚点而不是猜位置
   （`backend/packages/harness/deerflow/agents/factory.py:474` 的 `_insert_extra`）。
4. **直接跑 `uvicorn --reload` 替代 `make dev`**：agent 任务会往
   `backend/.deer-flow/` 写运行时文件，触发无限重启——`backend/AGENTS.md` 明确要求
   用预创建并排除该目录的 `make dev` target。
5. **指望 checkpoint 里存图片**：`viewed_images` 只存 SHA-256/size 等元数据，base64
   在 `wrap_model_call` 内注入请求、从不落图状态（`thread_state.py:62-76`）。
6. **忽略 `gap` 帧**：断线重连收到 `gap` 后继续等事件会永远挂起——正确动作是丢弃
   本地瞬时状态、重读持久化历史，再以 `latest_available_event_id` 重新入流
   （`backend/docs/STREAMING.md`）。

---

## 下一步

一次请求的"骨架"已经走通：HTTP 准入 → `run_agent` → 中间件链 → 模型/工具循环 →
SSE 回流。骨架上最鲜活的器官是**工具**——模型真正"做事"的接口。下一章
《第 7 章 工具系统与 Skills》（`docs/tutorials/07-tools-and-skills.md`）将打开
`get_available_tools()` 的三来源合并、内置工具（`present_files`、`ask_clarification`、
`view_image`、`review_skill_package`）的逐个拆解，以及 23 个官方技能与 Skill 引擎
（frontmatter 解析、静态安全扫描、斜杠激活、质量评审）的内部机制。
第 8 章（沙箱与代码执行）则接在本章 `SandboxMiddleware` 处继续深挖虚拟路径映射与
两种沙箱实现。
