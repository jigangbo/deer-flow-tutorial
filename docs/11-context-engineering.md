# 第 11 章 上下文工程与长对话治理

> 第 10 章解决了"跨会话记住用户"，本章解决"单会话内的上下文治理"。随着对话变长，
> 三个问题依次出现：**窗口压力**（token 逼近上限）、**上下文丢失**（摘要把关键
> 引用也压没了）、**行为失控**（循环调用、危险工具、PII 泄漏、供应商安全中断）。
> DeerFlow 用一个 `SummarizationMiddleware` 加一整套 guardrail 中间件回答它们。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 摘要中间件扩展层 | `backend/packages/harness/deerflow/agents/middlewares/summarization_middleware.py:123` |
| 摘要官方文档 | `backend/docs/summarization.md` |
| config.yaml summarization 段 | `config.example.yaml:2242` |
| 手动压缩端点 | `backend/app/gateway/routers/threads.py:1567` |
| 手动压缩实现 | `backend/packages/harness/deerflow/runtime/context_compaction.py:146` |
| 检查点写边界 | `backend/app/gateway/services.py:142` |
| 循环检测 | `backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware.py:1`、`backend/docs/LOOP_DETECTION.md` |
| config.yaml loop_detection 段 | `config.example.yaml:1505` |
| 工具调用前授权 | `backend/packages/harness/deerflow/guardrails/middleware.py:25` |
| Guardrails 文档 | `backend/docs/GUARDRAILS.md` |
| config.yaml guardrails 段（注释模板） | `config.example.yaml:3305` |
| PII 脱敏配置 | `config.example.yaml:1538` |
| 先读后写门 | `config.example.yaml:1586` |
| harness_guard 配置 | `config.example.yaml:1604` |
| 供应商安全中断配置 | `config.example.yaml:1680` |
| Plan Mode | `backend/docs/plan_mode_usage.md`、`backend/packages/harness/deerflow/agents/middlewares/todo_middleware.py:124` |
| 中间件链装配 | `backend/packages/harness/deerflow/agents/lead_agent/agent.py:485` |

## 11.0 学习目标

读完本章，你应该能够：

1. 解释 `SummarizationMiddleware` 的三种触发条件（tokens / messages / fraction）、
   `keep` 保留策略与分块摘要协议，以及"模型归属"（model ownership）规则；
2. 走读手动压缩端点 `POST /api/threads/{thread_id}/compact`，说明它如何复用同一
   中间件并通过 `reserve_checkpoint_write()` 与运行中的 run 互斥；
3. 列出 DeerFlow 的六层防护（loop_detection、guardrails、pii_redaction、
   read_before_write、harness_guard、safety_finish_reason）各自的检测对象与失败方向；
4. 用 `guardrails:` 配置接入四种 GuardrailProvider（Allowlist / OAP / Custom / TypeSafe）；
5. 理解 Plan Mode 如何通过 `config.configurable.is_plan_mode` 注入 `write_todos`。

## 11.1 概念：一次模型调用前发生什么

第 6 章给过中间件链全景。本章聚焦其中"上下文治理"相关的环节。`build_middlewares()`
（`backend/packages/harness/deerflow/agents/lead_agent/agent.py:485`）在 lead agent
组装时按顺序挂载，与本章相关的片段（`agent.py:723-725` 与 773-775）：

```python
    # LoopDetectionMiddleware — detect and break repetitive tool call loops
    loop_detection_config = resolved_app_config.loop_detection
    if loop_detection_config.enabled:
        middlewares.append(LoopDetectionMiddleware.from_config(loop_detection_config))
    ...
    # SafetyFinishReasonMiddleware — suppress tool execution when the provider
    # safety-terminated the response. Registered after the terminal-response
    # and custom/configured middlewares so LangChain's reverse-order after_model
    # dispatch runs Safety first; cleared tool_calls then flow through the
    # remaining accounting/terminal guards without firing extra alarms.
    safety_config = resolved_app_config.safety_finish_reason
    if safety_config.enabled:
        middlewares.append(SafetyFinishReasonMiddleware.from_config(safety_config))
```

三个治理视角：

1. **压缩**：`DurableContextMiddleware` 先于 `SummarizationMiddleware` 运行
   （`backend/docs/summarization.md` §Middleware Order）——任务委派记录与已加载
   skill 引用必须先被记入 durable 通道，它们的原始 ToolMessage 才有资格被压缩掉；
2. **保留**：摘要不是唯一手段——摘要本身、活跃 `/goal` 目标、已加载 skill 引用
   都走"durable context"通道在每次模型调用时重投影，绕开消息淘汰；
3. **防护**：在工具真正执行前后，由多个确定性中间件拦截危险或失控行为。

## 11.2 源码走读：自动摘要 SummarizationMiddleware

### 11.2.1 触发条件：三选一即触发（OR 逻辑）

`config.example.yaml:2242` 的出厂配置：

```yaml
summarization:
  enabled: true
  model_name: null
  trigger:
    # Trigger when token count reaches 32000
    - type: tokens
      value: 32000
  keep:
    # Keep the most recent 10 messages (recommended)
    type: messages
    value: 10
  trim_tokens_to_summarize: 15564
  summary_prompt: null
```

三种 trigger 类型（`backend/docs/summarization.md` §trigger）：

| 类型 | 含义 | 备注 |
| --- | --- | --- |
| `tokens` | 消息历史 + 已有 `summary_text` 的 token 数达到阈值 | 最常用，建议设为模型上下文的 60–80% |
| `messages` | 消息条数达到阈值 | 适合大量短消息的会话 |
| `fraction` | 达到模型 `context_window` 的百分比 | 百分比从**活跃 run 模型**声明的 `context_window` 解析；第三方 OpenAI 兼容模型没有内置容量档案，未声明时 fraction 子句在 agent 构建时带警告丢弃，其余绝对阈值继续工作 |

监测发生在每次模型调用前，且计数包含已有 `summary_text`——因为摘要会作为
durable context 投影进下一次请求，不计数就会低估真实输入。

### 11.2.2 DeerFlow 扩展层：DeerFlowSummarizationMiddleware

DeerFlow 没有重写 LangChain 的 `SummarizationMiddleware`，而是继承扩展
（`backend/packages/harness/deerflow/agents/middlewares/summarization_middleware.py:123`）：

```python
class DeerFlowSummarizationMiddleware(SummarizationMiddleware):
    """Summarization middleware with pre-compression hook dispatch."""
```

文件头部的常量定义了三个治理参数（`summarization_middleware.py:43-49`）：

```python
_NOOP_CACHE_MAX_ENTRIES = 128
_MAX_SUMMARY_CHUNKS = 64
_SUMMARY_CHUNK_RETRY_SECONDS = 300
_SHORTENED_SUMMARY_MARKER = "\n[summary shortened]\n"
```

四个关键机制：

**(1) 模型归属（model ownership）**。构造函数注释（第 142-153 行）说明：
`run_model_name` 由调用方（lead / subagent / 手动构建器）直接提供——它是本次
run 真正执行的模型，是权威事实源；`configured_model_name` 是配置的摘要模型。
两者不同且摘要供应商故障（key 过期、配额、宕机）时，run 自己的模型仍可完成压缩
——一个坏掉的摘要供应商不能让压缩整体停摆。`model_name: null`（默认）表示直接用
run 自己的模型，而不是 `models[0]`。

**(2) 流式隔离**。第 157-163 行注释解释了 `_tag_nostream`：

> The summary LLM call runs inside a LangGraph middleware hook, so its token
> stream would otherwise be captured by the messages-tuple stream callback and
> broadcast to the frontend as a phantom AI message. Tag a dedicated model copy
> with TAG_NOSTREAM so the streaming handler skips it.

摘要调用发生在中间件钩子里，若不隔离，其 token 流会被 SSE 回调捕获，前端出现
一条"幽灵 AI 消息"。

**(3) 分块与预算**（`backend/docs/summarization.md` §Overview）：选中历史按时间序
分块处理，每次调用拿到"前序摘要 + 下一块原文"；已生成摘要最多占用一半原始输入
预算，超长摘要保留头尾并打 `[summary shortened]` 标记，**原文永远不会被这样裁剪**；
单条超长消息切成连续片段（包括中段）。一次 pass 最多 64 块，超限保留原历史；
任何一块失败，活跃历史保持不变（手动 `/compact` 报告生成失败）。块数超限触发
5 分钟冷却（按 user/thread/executor/首条源消息 ID/旧摘要/策略键控），冷却期内
自动与手动尝试都不发起摘要模型调用——这是一个进程内的成本熔断，不是持久预算。

**(4) no-op 缓存**（`backend/docs/summarization.md` §Reuse and telemetry）：缓存
"首次候选模型原样返回了已有 summary_text"的渲染 prompt，命中时直接复用
（`_ReusedSummary` 标记，`summarization_middleware.py:52`）。**只缓存首选候选**
——回退候选的结果永不缓存，所以缓存复用不会抑制主模型失败后的重试。每次成功
摘要发 `middleware:summarize` 日志事件，`changes` 里带 `noop` / `llm_call_skipped` /
`summary_chars` / `call_count` / `noop_count` / `skip_count` 等字段，
`skip_count / call_count` 即缓存复用率。

### 11.2.3 摘要前钩子：与记忆系统的交接

`BeforeSummarizationHook` 协议（`summarization_middleware.py:88-96`）：

```python
@runtime_checkable
class BeforeSummarizationHook(Protocol):
    """Hook invoked before summarization removes messages from state.

    Hooks are synchronous and may block. The async compaction path runs them
    in a worker thread, so a hook must not assume it runs on the event loop.
    """
```

第 10 章的 `memory_flush_hook`（`agents/memory/summarization_hook.py:14`）就是挂
在这里的钩子：即将被摘要掉的消息先抢救进记忆队列（`add_nowait`），异步压缩路径
在工作线程中执行钩子（mem0/Honcho/OpenViking 的 `add_nowait` 是同步 HTTP，见
`agents/memory/AGENTS.md` §Main components 与阻塞 IO 测试）。

### 11.2.4 压缩后：三条"durable"通道

摘要只是删消息，真正防"上下文丢失"的是三类重投影（`backend/docs/summarization.md`
§Message Preservation / §Skill context channel）：

1. **摘要文本**：存进 `ThreadState.summary_text`（不是 messages），由
   `DurableContextMiddleware` 在每次模型调用时渲染成隐藏的
   `<durable_context_data>## Conversation summary so far ...` 数据消息；
   静态处理规则放在单独的系统消息里——摘要文本与其他用户/工具派生值一律是
   低权限数据；
2. **活跃目标**：线程有活跃 `/goal` 时，目标文本在每次模型调用时以
   `<active_goal>` 元素出现在同一数据消息开头——压缩不能把目标连同陈述它的消息
   一起带走。元素按位置只认开头那一段，其余字段值全部 HTML 转义，防止注入；
3. **已加载 skill 引用**：`read_file` 命中 `skill_file_read_tool_names`
   （默认 `["read_file", "read", "view", "cat"]`）且路径在
   `skills.container_path` 下的调用，在读取工具边界打 `skill_context_entry`
   元数据，由 `DurableContextMiddleware` 捕获进 checkpoint 的 `skill_context`
   通道——压缩后重注入 `name`/`path`/`description`/`loaded_at` 引用，**不持久化
   skill 正文**，agent 需要时按引用重读。

另外压缩会过滤 `HumanMessage(name="todo_reminder")` 快照（在触发检查之后、
保留尾部选择之前）：它们不进入摘要生成也不进入保留消息，`state["todos"]`
不变；只有压缩成功才提交删除，失败路径保持原状态。下一个 `TodoMiddleware.before_model`
会从当前 todos 重建提醒（`backend/docs/summarization.md` §Todo reminders；
消息名常量由 `todo_middleware.py::TODO_REMINDER_MESSAGE_NAME` 独占，值保持
`todo_reminder` 以兼容前端隐藏过滤）。

### 11.2.5 配置建议速查

`backend/docs/summarization.md` §Best Practices 给出推荐区间：token 触发设模型
上下文的 60–80%；`keep: messages` 推荐 15–25 条；`trim_tokens_to_summarize`
限制单次摘要调用的输入预算（默认 4000，`null` = 单次不裁剪但不推荐）；摘要模型
推荐轻量款（gpt-4o-mini 等）。多模型场景用 `fraction` 触发自动适配每个模型的容量。

## 11.3 源码走读：手动压缩 POST /api/threads/{thread_id}/compact

端点在 `backend/app/gateway/routers/threads.py:1567`：

```python
@router.post("/{thread_id}/compact", response_model=ThreadCompactResponse)
@require_permission("threads", "write", owner_check=True, require_existing=True)
async def compact_thread(thread_id: ThreadId, body: ThreadCompactRequest, request: Request) -> ThreadCompactResponse:
    """Manually summarize old thread context while preserving the visible history."""
    # Compaction writes only base-schema channels (messages + summary_text);
    # every other channel — including middleware-contributed ones — is carried
    # forward by checkpoint fork inheritance, so the base-schema mutation
    # graph is sufficient (and avoids building the full lead graph per call).
    try:
        accessor, _ = build_checkpoint_state_mutation_accessor(
            request,
            thread_id=thread_id,
            as_node="manual_compaction",
        )
    except _CHECKPOINT_MODE_ERRORS as exc:
        raise _checkpoint_mode_http_error(exc, thread_id) from exc
    keep = body.keep.to_tuple() if body.keep is not None else None
    try:
        async with reserve_checkpoint_write(request, thread_id, user_id=get_effective_user_id()):
            result = await compact_thread_context(
                accessor,
                thread_id,
                keep=keep,
                force=body.force,
                user_id=get_effective_user_id(),
                agent_name=body.agent_name,
                model_name=body.model_name,
            )
```

逐条拆解：

- **请求体**（`threads.py:600-607` 的 `ThreadCompactRequest`）：`force`（默认
  True——未达自动阈值也强制压缩）、`keep`（仅本次压缩生效的保留策略覆盖）、
  `model_name`（前端从 composer 当前模型带入，与普通 run 相同的解析优先级）、
  `agent_name`；
- **只写基础通道**：压缩只改 `messages` + `summary_text`，其余通道（包括
  middleware 贡献的）靠 checkpoint fork 继承携带，因此不必为每次调用构建完整
  lead graph（上面的代码注释）；
- **写边界**：`reserve_checkpoint_write()`（`backend/app/gateway/services.py:142`）
  组合进程内线程锁与持久 `checkpoint_write` 预留。`backend/app/gateway/AGENTS.md:224`
  写明：手动压缩、`POST /threads/{id}/state` 与两条 goal 路由都走这个边界——
  存量 run 会阻塞写入，预留会阻塞新的 reject/interrupt/rollback run，
  且该短命 `checkpoint_write` 操作与 run 准入共享持久唯一约束，防住 worker
  本地与跨 worker 的检查点写竞争；
- **错误映射**：`ConflictError` → 409 "Thread has a run in flight. Compact after
  the run finishes."；`ContextCompactionDisabled` → 409；`ContextCompactionFailed`
  → 500；线程不存在 → 404；
- **复用同一中间件**：`compact_thread_context`（`runtime/context_compaction.py:146`
  实现，`ThreadCompactionResult` 定义在其第 64 行）内部走同一个
  `DeerFlowSummarizationMiddleware` 压缩路径，因此摘要前钩子（记忆抢救）、
  todo_reminder 过滤、分块/冷却/no-op 缓存全部生效。结果写入新 checkpoint
  （更新 `messages` / `summary_text`），响应（`threads.py:1554`）返回
  `compacted` / `reason` / `removed_message_count` / `preserved_message_count` /
  `summary_updated` / `checkpoint_id` / `total_tokens`。

白话版协议：前端"压缩上下文"按钮 → `POST /api/threads/{id}/compact` →
拿一个与 run 互斥的写预留 → 复用自动摘要管线生成新摘要 → 写新 checkpoint →
返回统计。可见聊天历史不变，被压缩的是发给模型的上下文。

## 11.4 防护体系：六层确定性中间件

### 11.4.1 loop_detection：循环检测

`backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware.py`
的文件头把策略讲得很清楚：

> 1. After each model response, hash the tool calls (name + args).
> 2. Track recent hashes in a sliding window.
> 3. If the same hash appears >= warn_threshold times, queue a
>    "you are repeating yourself — wrap up" warning ... injected at the next
>    model call (in `wrap_model_call`) as a `HumanMessage` appended ... *after*
>    all ToolMessage responses.
> 4. If it appears >= hard_limit times, strip all tool_calls from the response
>    so the agent is forced to produce a final text answer.

为什么警告在 `wrap_model_call` 注入而不是 `after_model`？文件头解释：`after_model`
时工具节点尚未执行，插进来的消息会落在 `tool_calls` 与其 `ToolMessage` 之间，
OpenAI/Moonshot 会以 `"tool_call_ids did not have response messages"` 拒绝下一个
请求。推迟到下次请求前注入，配对完好。

`config.example.yaml:1505`：

```yaml
loop_detection:
  enabled: true
  warn_threshold: 3
  hard_limit: 5
  window_size: 20
  # Compatibility name: bounds retained (thread_id, run_id) histories, not whole threads.
  max_tracked_threads: 100
  tool_freq_warn: 30
  tool_freq_hard_limit: 50
  # tool_freq_overrides:
  #   bash:
  #     warn: 150
  #     hard_limit: 300
```

两层检测：哈希层（同工具同参数重复）与频率层（窗口内同类工具调用次数）。
`tool_freq_overrides` 允许为高频工具（如批处理工作流里的 bash）单独放宽而不
削弱其他工具的防护。状态按 `(thread_id, run_id)` 键控（`backend/docs/LOOP_DETECTION.md`
§Run-scoped state）：编译图缓存复用时每个用户 run 拿到全新预算，而同一 Gateway
run 的多次图进入（包括隐藏的 goal 续跑）共享一份预算。决策按严重度优先——硬限制
可以直接终止扫描，警告候选不会短路同批次后续调用的频率计数。

### 11.4.2 guardrails：工具调用前的策略授权

`backend/docs/GUARDRAILS.md` 的定位论证：沙箱提供进程隔离但不是语义授权
（沙箱里的 bash 依然能 `curl` 数据外传）；`ask_clarification` 人工审批不适合
自主长任务；guardrails 填补"确定性、策略驱动的工具授权"空缺。核心组件
`GuardrailMiddleware`（`backend/packages/harness/deerflow/guardrails/middleware.py:25`）：

```python
class GuardrailMiddleware(AgentMiddleware[AgentState]):
    """Evaluate tool calls against a GuardrailProvider before execution.

    Denied calls return an error ToolMessage so the agent can adapt.
    If the provider raises, behavior depends on fail_closed:
      - True (default): block the call
      - False: allow it through with a warning
    """
```

每次工具调用构造 `GuardrailRequest`（`guardrails/provider.py:12`——含
`tool_name`、`tool_input`、`user_id`、`user_role`、`thread_id`、`run_id`、
`tool_call_id`、`is_subagent` 等归属字段，全部由 Gateway 从服务端认证状态填充，
客户端提供的值无法覆盖），交给 provider 评估。拒绝返回
`ToolMessage(status="error")`，agent 看到拒绝原因并自行调整策略。`GraphBubbleUp`
（LangGraph 控制信号）永远直接传播，不会被吞。

四种内置 provider（`backend/docs/GUARDRAILS.md` §Four Provider Options）：

| Provider | 类路径 | 特点 |
| --- | --- | --- |
| Allowlist（零依赖） | `deerflow.guardrails.builtin:AllowlistProvider` | 按工具名黑/白名单，无网络无外部包 |
| OAP Passport | 如 `aport_guardrails.providers.generic:OAPGuardrailProvider` | Open Agent Passport 开放标准：JSON passport 声明 capabilities 与 limits（`allowed_commands`、`blocked_patterns`），`status` 即 kill switch |
| Custom | 任何带 `evaluate`/`aevaluate` 的类 | 结构化协议，无基类；可读 runtime 归属字段做角色策略，审计写文件须 `asyncio.to_thread` 卸载（CI 有 blocking-IO 门禁） |
| TypeSafe (Jev) | `deerflow.guardrails.typesafe:TypeSafeGuardrailProvider` | 发送工具名 + 完整参数 JSON 到 `POST /v1/systemone`，风险概率 ≥ `threshold` 拒绝；另有 `openai_decisions:OpenAIDecisionsGuardrailProvider` 走 `POST /v1/decisions` 同语义 |

TypeSafe 是唯一把工具参数发往第三方的 provider，文档明确警示（§What is sent）：
**provider 不做脱敏，`pii_redaction_middleware` 不覆盖这条路径**；参数超
`max_state_chars`（字符数，非字节——CJK 一字三字节）本地拒绝（`typesafe.state_unusable`），
绝不截断发送——"前缀可能藏着一半危险的 `write_file` 载荷"。`allowed_tools` 是
硬权限名单而非评估豁免：名单外的工具在任何状态构建之前本地拒绝，名单内的工具
仍要过风险门。本地拒绝同样是 guardrail 决策，`fail_closed: false` 也不能把它
变成未评估就放行。还有一个覆盖面提醒（§Coverage）：拒绝不阻止操作本身——agent
可以从未探查的工具、MCP 工具、子代理或 shell 包装重试同一效果，`tools: ["bash"]`
只是冒烟测试范围而非生产建议。

`config.example.yaml:3305` 起是四种 provider 的注释模板；`guardrails.provider`
是**单槽**设计——指向 TypeSafe 会整体替换 AllowlistProvider，allow 半边迁入
`allowed_tools`，deny 规则迁入 `authorization.*`（RBAC）。

### 11.4.3 pii_redaction：模型可见上下文中的 PII 脱敏

`config.example.yaml:1538`（注释 1523-1537）：

```yaml
pii_redaction:
  enabled: false
  # redact_email: true
  # redact_api_key: true
  # redact_credit_card: true
  # redact_phone: true
  # redact_national_id: true
  # token_secret: change-me-to-a-long-random-string
```

覆盖对象：真实用户消息与远端内容工具结果（web_fetch / web_search / image_search /
web_capture 与 MCP 工具）中的邮箱、电话、API key、信用卡（Luhn 校验）、身份证号。
改写为**键控、值派生的占位符**（如 `[EMAIL_bdqkxw...]`）——HMAC 摘要以
`token_secret` 为密钥（启用时必填、≥16 字符），离线不可反推，同一原始值在同一
部署内总是渲染为同一 token。这个"值派生"性质是关键：身份在压缩前脱敏，压缩后
依然渲染出相同 token，摘要与 `/goal` 评估输入也覆盖。原始文本保留在线程状态里
供 UI 展示；入队的记忆抽取载荷同样脱敏（第 10 章的 `redact_queued_messages`）。

### 11.4.4 read_before_write：先读后写门

`config.example.yaml:1586`：

```yaml
read_before_write:
  enabled: true
  # A blocked call never ran and must be re-issued after a re-read, so its
  # payload (write_file content, str_replace old_str/new_str) is dead weight in
  # every later model call. Replace it with a short placeholder in model-bound
  # requests; stored history, receipts, and the run journal keep the original.
  elide_blocked_payloads: true
  elide_min_chars: 2000
```

语义：`write_file`（对既有文件的 append/overwrite）与 `str_replace` 在 agent 未
读过该文件当前版本时被阻止；任何写操作使之前的读失效，强制连续编辑之间重读——
这是对长任务里"盲写重复追加"的确定性防线。`elide_blocked_payloads` 处理一个
上下文工程细节：被阻止的调用从未执行，其载荷在之后每次模型调用里都是死重，
所以模型可见请求里用短占位符替换（≥`elide_min_chars` 字符的字段才裁），而
存储历史、回执与运行日志保留原始载荷。

### 11.4.5 harness_guard：语法验证与错误模式治理

`config.example.yaml:1604`：

```yaml
harness_guard:
  enabled: true
  write_verify_syntax: false
  block_on_syntax_error: true
  targeted_hints_enabled: true
  max_repeated_error_signatures: 2
  detect_alternating_loops: true
  max_loop_history: 20
  max_tracked_scopes: 1000
```

两个职责：`write_verify_syntax: true` 时在落盘前对 `str_replace` 拼接后的 `.py`
（`ast.parse`）与 `.json`（`json.loads`）做语法验证；错误分类器识别
ModuleNotFoundError / SyntaxError / FileNotFoundError 等工具错误输出，向工具结果
注入针对性的补救提示。`max_repeated_error_signatures: 2` 限制同一错误签名重复
出现次数，`detect_alternating_loops` 捕捉 A→B→A 交替循环。

### 11.4.6 safety_finish_reason：供应商安全中断

`config.example.yaml:1680`（注释 1666-1678）处理 issue #3028 记录的故障模式：
provider 以安全原因停止生成（OpenAI `finish_reason='content_filter'`、Anthropic
`stop_reason='refusal'`、Gemini `finish_reason='SAFETY'`）但消息里仍带 tool_calls
——这些 tool_calls 通常是截断/不可靠的，**绝不能执行**。内置检测器按类路径反射
加载，覆盖 OpenAI 兼容 content_filter、Anthropic refusal、Gemini SAFETY/BLOCKLIST/
PROHIBITED_CONTENT/SPII/RECITATION；国产网关的非标准 finish_reason 用
`detectors:` 列表扩展（示例里给了 `finish_reasons: ["content_filter",
"sensitive", "risk_control"]` 的配置模板，`config.example.yaml:1688-1699`）。

### 11.4.7 防护体系的共同哲学

把六层放在一起看，有两条一致的设计纪律：

1. **失败方向明确**：guardrail provider 异常默认 `fail_closed`（阻止）；
   safety 检测宁可错杀 tool_calls（截断的调用不可靠）；loop 检测到硬限制直接
   剥离 tool_calls 逼出最终文本。凡涉及"危险动作放行"的判断，都朝保守方向失败。
2. **确定性优先**：这六层没有一个依赖 LLM 判断——哈希、窗口计数、正则、HMAC、
   `ast.parse`。LLM 参与的判断（TypeSafe 风险概率）是 opt-in 的网络门，且有自己的
   本地预检兜底。确定性意味着可解释、可复放（guardrail 拒绝写入运行日志
   `middleware:guardrail`，阈值比较可从记录重放）。

## 11.5 Plan Mode：write_todos 与多步任务跟踪

Plan Mode 是运行时配置而非全局开关（`backend/docs/plan_mode_usage.md` §Configuration）：
`config.configurable.is_plan_mode=True` 时 `build_middlewares()` 经
`_create_todo_list_middleware(is_plan_mode)` 加入 TodoList 中间件，给 agent
`write_todos` 工具。任务状态三值：`pending` / `in_progress` / `completed`。

DeerFlow 在 LangChain `TodoListMiddleware` 上做了扩展——`TodoMiddleware`
（`backend/packages/harness/deerflow/agents/middlewares/todo_middleware.py:124`）：

```python
class TodoMiddleware(TodoListMiddleware):
    """Extends TodoListMiddleware with `write_todos` context-loss detection.

    When the original `write_todos` tool call has been truncated from the message
    ...
```

解决的是长对话上下文丢失：原始 `write_todos` 调用与它的 ToolMessage 被滚动出
（或被压缩掉）消息窗口后，中间件检测到"有 todos 但没有可见的 write_todos 调用"，
重建一条提醒消息（前面 11.2.4 的 `todo_reminder` 过滤正是与它配对的压缩侧协议）。
使用准则由自定义 prompt 表达：3 步以上复杂任务才用 todo 列表，单步任务与纯对话
不用；始终恰好一个 `in_progress` 任务、实时更新。

## 动手实验

### 实验一：触发自动摘要并对比 checkpoint

1. `config.yaml` 的 `summarization` 段把阈值调低便于触发：

   ```yaml
   summarization:
     enabled: true
     trigger:
       - type: tokens
         value: 4000
     keep:
       type: messages
       value: 6
   ```

2. `make dev` 后在一个线程里连续发起多轮长回复对话（例如让 agent 反复读长文件），
   观察 `logs/gateway.log` 中的摘要日志与 `middleware:summarize` 事件。
3. 触发后调用 `GET /api/threads/{thread_id}/state`，对比 `messages`（应只剩
   `keep` 数量的近期消息）与 `values` 里的 `summary_text` 字段。
4. 再调 `POST /api/threads/{thread_id}/compact` 手动压缩一次（`force: true`），
   检查响应里的 `removed_message_count` / `summary_updated` / `checkpoint_id`。
5. （进阶）在同一会话里先说一条稳定偏好，等摘要触发后再开新线程验证记忆仍在——
   这验证了 11.2.3 的"摘要前抢救钩子"：被摘要掉的消息已进记忆队列。

### 实验二：接一个零依赖 guardrail

1. 在 `config.yaml` 加入（`config.example.yaml:3305` 的取消注释版）：

   ```yaml
   guardrails:
     enabled: true
     provider:
       use: deerflow.guardrails.builtin:AllowlistProvider
       config:
         denied_tools: ["bash", "write_file"]
   ```

2. 重启 Gateway，让 agent "用 bash 执行 echo hello"——agent 收到的应是
   `Guardrail denied: tool 'bash' was blocked (oap.tool_not_allowed)` 类错误
   ToolMessage，且它会自行改道（比如改用别的工具）。
3. 把日志里的 `middleware:guardrail` 事件找出来，核对拒绝原因与策略标识。
4. 恢复配置并重启。

## 常见坑

1. **fraction 触发静默失效**——`type: fraction` 需要模型在 `models:` 段声明
   `context_window`；第三方 OpenAI 兼容模型没有内置容量档案，未声明时 fraction
   子句在 agent 构建时带警告丢弃，只留下绝对阈值。若你的触发只配了 fraction，
   摘要会永远不触发。`keep: fraction` 同理。
2. **手动压缩报 409 "Thread has a run in flight"**——run 进行中检查点被锁定。
   等 run 结束再压缩；这是 `reserve_checkpoint_write()` 边界的预期行为，不是 bug。
3. **摘要模型供应商挂了导致压缩"消失"**——`model_name` 指定的供应商故障时压缩
   回退到 run 自己的模型；但如果你把 `model_name` 设成了一个没配 key 的模型且
   回退也失败，块级失败会保留原历史并进入 5 分钟冷却。看日志里的
   `SummaryGenerationError`（手动路径）或冷却警告（含剩余延迟）。
4. **开了 pii_redaction 却没配 token_secret**——配置校验直接失败：无密钥的
   HMAC 是公开可计算的全局可链接指纹（电话号码甚至可猜测），所以"启用但无密钥"
   被拒绝而不是降级。
5. **guardrail 换 provider 后旧的 denied_tools 失效**——`guardrails.provider`
   是单槽：指向 TypeSafe 就替换了 AllowlistProvider，deny 规则必须迁到
   `authorization.*` 的 RBAC，allow 半边迁入 TypeSafe 的 `allowed_tools`。
   迁移期间保持旧 provider 启用并逐项验证（GUARDRAILS.md §Replacing the built-in
   AllowlistProvider）。
6. **循环检测误伤合法批量工具调用**——批处理工作流（如 RNA-seq 流水线）里 bash
   天然高频。用 `tool_freq_overrides` 单独为该工具提高阈值，而不是整体调高全局
   阈值削弱其他工具的防护（`config.example.yaml:1514-1522`）。

## 下一步

上下文治理保证"单次会话"既省钱又安全。但生产自动化还要求"没人盯着也能跑"：
定时唤醒、非交互约束、多实例租约，以及把同一个 agent 接进飞书/Slack/Telegram。
下一章 [第 12 章 定时任务与 IM 渠道](12-scheduled-tasks-and-im.md)
拆解 scheduler 的队列租约模型与 `app/channels/` 的渠道实现。
