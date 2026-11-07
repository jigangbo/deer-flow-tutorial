# 第 10 章 记忆系统（Memory / DeerMem）

> 进阶篇第 1 章（本章按大纲序号是第 10 章）。第 6 章我们看到一次请求的生命周期里，
> 对话状态由 LangGraph checkpoint 持久化——但那只是"会话内"的记忆。这一章拆解的是
> 跨会话、跨线程的用户级记忆：`MemoryMiddleware` 如何在每轮对话后抽取事实，
> DeerMem 如何存储、淘汰、检索并注入这些事实，以及 `select_facts_for_capacity()`
> 背后的容量策略之争（confidence vs hybrid-v1）。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 记忆模块总纲 | `backend/packages/harness/deerflow/agents/memory/AGENTS.md` |
| 后端无关的 MemoryManager 契约与工厂 | `backend/packages/harness/deerflow/agents/memory/manager.py:128`、`manager.py:1124` |
| 被动抽取中间件 | `backend/packages/harness/deerflow/agents/middlewares/memory_middleware.py:160` |
| 压缩前抢救钩子 | `backend/packages/harness/deerflow/agents/memory/summarization_hook.py:14` |
| locale 打标 | `backend/packages/harness/deerflow/agents/memory/locale.py:8` |
| 五个记忆工具 | `backend/packages/harness/deerflow/agents/memory/tools.py:49` |
| DeerMem 默认后端 | `backend/packages/harness/deerflow/agents/memory/backends/deermem/` |
| 容量淘汰实现 | `backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/eviction.py:157` |
| 淘汰在 updater 中的调用点 | `backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/updater.py:956` |
| 配置 schema（宿主共享字段） | `backend/packages/harness/deerflow/config/memory_config.py:112` |
| config.yaml memory 段 | `config.example.yaml:2353` |
| 认知风格设计说明 | `backend/docs/MEMORY_COGNITIVE_STYLE.md` |
| 抽取成本门与改进路线 | `backend/docs/MEMORY_IMPROVEMENTS.md` |
| 记忆设置页样例数据 | `backend/docs/memory-settings-sample.json` |
| 淘汰策略评测基准 | `backend/scripts/benchmark/deermem_eviction/README.md` |

## 10.0 学习目标

读完本章，你应该能够：

1. 说清 DeerFlow 记忆的两条通道（`middleware` 被动抽取与 `tool` 模型主动读写）各自的写入时机与取舍；
2. 走读 `MemoryMiddleware → add_nowait → 防抖队列 → updater` 的完整抽取链路，并解释为什么入队前要做 PII 脱敏和 locale 打标；
3. 解释 `select_facts_for_capacity()` 的两种策略（`confidence` 与 `hybrid-v1`）的评分构成、correction 预留槽与影子模式；
4. 掌握 `config.yaml → memory:` 段的宿主共享字段与 `backend_config` 私有字段的分层，以及旧字段自动迁移行为；
5. 用 `scripts/benchmark/deermem_eviction` 离线复现两种淘汰策略的差异。

## 10.1 概念：checkpoint 是会话记忆，Memory 是用户记忆

DeerFlow 里有两层容易混淆的"记忆"：

| 层 | 生命周期 | 存储位置 | 覆盖范围 |
| --- | --- | --- | --- |
| **Checkpoint（会话状态）** | 单个 thread | `database:` 配置的 checkpointer（SQLite/Postgres） | 本会话消息、todos、artifacts、`viewed_images` |
| **Memory（用户记忆）** | 跨会话、跨线程 | DeerMem 文件存储 / mem0 / Honcho / OpenViking | 用户偏好、工作上下文、事实、认知风格 |

`docs/ARCHITECTURE.md` §5 把记忆列为横切子系统：一个 lead agent 编排
sub-agents、持久记忆与沙箱执行，"全部按会话线程隔离"的是执行环境，而记忆是
**按用户（user_id）隔离**、故意跨线程共享的。典型场景：你在某个线程里说
"以后 PR 标题都用英文写"，换一个新线程提问，agent 依然记得这条偏好。

`backend/docs/KNOWLEDGE.md` 中的知识检索契约（`deerflow.knowledge`、
`RetrievalProvider`）是**另一套独立机制**——它面向企业知识库/数据集的只读检索，
与用户级记忆互不相干，别把两者混为一谈。

记忆模块位于 harness 层（`backend/packages/harness/deerflow/agents/memory/`），
因此 IM 渠道、定时任务、Web 前端共享同一套记忆。模块自述（`agents/memory/AGENTS.md`
第 20 行）：*"This directory owns memory capture, storage, retrieval, prompt
injection, and model-driven memory tools."*

## 10.2 概念：两种运行模式与后端抽象

### 10.2.1 mode: middleware（默认，被动抽取）

`MemoryMiddleware` 在每轮 agent 结束后（`after_agent` / `aafter_agent` 钩子）把
过滤后的用户消息与最终助手消息入队，由后台防抖线程批量交给 LLM 做事实抽取。
用户无感知，写入质量由抽取 prompt 与多重写入门控决定。这是
`config.example.yaml:2375` 的默认值 `mode: middleware`。

### 10.2.2 mode: tool（实验性，模型主动读写）

`memory.mode: tool` 时注册五个 LangChain 工具（`agents/memory/tools.py`）：
`memory_search`、`memory_get`、`memory_add`、`memory_update`、`memory_delete`。
由模型决定何时检索/改写记忆。注意两点：

- 工具模式**仍然保留被动写入**给支持的远端后端（`requires_passive_writes_in_tool_mode`）；
- 注入行为不同（`agents/memory/AGENTS.md` §Operating modes）：
  middleware 模式注入"共享摘要 + 当前 agent 的事实"；tool 模式只注入共享摘要，
  agent 事实留在 `memory_search` / `memory_get` 后面，由模型按需拉取。

### 10.2.3 manager_class: 可插拔后端

`backend/packages/harness/deerflow/config/memory_config.py:146` 定义了后端选择器：

```python
manager_class: str = Field(
    default="deermem",
    description=(
        "Memory backend selector. Either a registered backend name "
        "(matching a `backends/<name>/` folder that exposes `MANAGER_CLASS`, "
        "e.g. `deermem` / `noop`) or a dotted import path to a "
        "`MemoryManager` subclass. ..."
    ),
)
```

内置后端目录 `backends/`：`deermem`（默认本地文件后端）、`mem0`、`honcho`、
`openviking`、`noop`（空实现）。工厂 `get_memory_manager()`（`manager.py:1124`）
采用双检锁单例：记忆注入走 `asyncio.to_thread`、更新队列跑在 Timer 线程、
Gateway/agent 线程都可能首次触达，所以必须保证只构建一次实例。

关键设计：**宿主共享字段与后端私有字段分层**。`memory_config.py` 模块头注释写明，
共享 schema 只保留 `enabled / mode / injection_enabled /
shutdown_flush_timeout_seconds / manager_class / backend_config / prescreen /
signal_classification` 八个键（`memory_config.py:22` 的 `_SHARED_FIELDS`），
DeerMem 自己的旋钮全部收进 `backend_config`（由后端解析为 `DeerMemConfig`）。
这样换后端时宿主契约不泄漏 DeerMem 细节。

## 10.3 源码走读：写入链路（从 after_agent 到抽取）

### 10.3.1 第一站：MemoryMiddleware.after_agent 入队

`backend/packages/harness/deerflow/agents/middlewares/memory_middleware.py:160`
定义 `MemoryMiddleware`；`after_agent`（第 236 行）在每轮 agent 结束后触发，
`_resolve_add_args`（第 196 行）负责挑选要入队的消息（用户消息 + 最终助手回复），
然后调用 `manager.add()`。入队时捕获 `user_id`——这个身份要穿越后台定时器边界，
否则后台抽取时已拿不到请求上下文。

### 10.3.2 入队前必须做两件事：PII 脱敏与 locale 打标

**脱敏**：`redact_queued_messages()`（`memory_middleware.py:29`）是共享函数，
被 MemoryMiddleware 入队边界与压缩触发的 `memory_flush_hook` 共用。注释里点明了
为什么要在这里脱敏（#3190 vector 5）：

> compaction removes these messages from state right after, so the later
> after-agent redaction cannot repair a raw batch queued here.

也就是说：消息即将因摘要压缩从状态里删除，事后的兜底脱敏再也覆盖不到它们，
所以必须在入队边界就地脱敏。脱敏范围不止 `content`，还包括 `tool_calls` /
`invalid_tool_calls` 参数与错误文本、legacy `function_call`、
`original_user_content`（上传中间件保留的原始用户话轮）和澄清回答
`human_input_response.value`——因为 DeerMem 会读取这些元数据。

**locale 打标**：`agents/memory/locale.py:8`：

```python
_MEMORY_LOCALE_KEY = "deerflow_ui_locale"


def with_memory_locale(messages: list, context: object) -> list:
    locale = ui_locale(context)
    captured = []
    for message in messages:
        kwargs = {key: value for key, value in message.additional_kwargs.items() if key != _MEMORY_LOCALE_KEY}
        if locale is not None:
            kwargs[_MEMORY_LOCALE_KEY] = locale
        # Stamp every queued copy: filtering and the extraction watermark may
        # leave only an assistant tail. Never write this marker to graph state.
        captured.append(message.model_copy(update={"additional_kwargs": kwargs}) if kwargs != message.additional_kwargs else message)
    return captured
```

三个细节值得注意：

1. **每条消息都打标**——过滤与抽取水位线可能只留下助手尾部，逐条打标保证语言
   偏好不丢失；
2. **绝不写入 graph state**——打标只发生在入队副本上（`model_copy`），
   checkpoint 里的消息保持干净；
3. `ui_locale`（`agents/language.py:8`）只接受 `UI_LANGUAGES`
   （`language.py:5`：`{"en-US": "English", "zh-CN": "Simplified Chinese"}`）里的值，
   该集合由 `contracts/ui_locales.v1.json` 钉住并在测试中与 DeerMem 的可移植
   映射对齐（`agents/memory/AGENTS.md` §locale）。

这就是大纲 10.3 的答案：`context.locale` 是运行时语言偏好，只影响回复语言与
**新写记忆的语言**（DeerMem 把它读进 human 数据消息，系统文本保持静态，
见 `agents/memory/AGENTS.md` 开头），不落入 checkpoint `configurable`。

### 10.3.3 第二站：防抖队列（DeerMem）

DeerMem 按 `(thread_id, user_id, agent_name)` 三元组独立防抖（单调时钟截止时间）：

- 同 key 合并保留第一个待处理到达；`backend_config.max_wait_seconds`（默认 300）
  封顶防抖延迟，避免持续更新无限顺延；
- 一个 Timer 为最早的截止时间唤醒，一个消费者串行处理；
- `debounce_seconds`（默认 30）是每会话静默期——对话停止后 30 秒才真正调用抽取 LLM；
- **紧急快照**（摘要压缩前的抢救）立即具备处理资格，不与普通更新互相覆盖、
  也不受 `queue_max_depth` 限制；单 key 积压 32 条快照起告警且逐倍翻倍再告警
  （`agents/memory/AGENTS.md` §Operating modes）。

`queue_max_depth`（默认 1000）是背压上限：达到上限时新的非信号更新被拒绝
（QueueFull），而携带信号（correction/reinforcement）的更新永远准入——重要记忆
不能被 Shed。

### 10.3.4 第三站：压缩前的"抢救"钩子

这是记忆与第 11 章摘要机制的交汇点。`agents/memory/summarization_hook.py:14`：

```python
def memory_flush_hook(event: SummarizationEvent, pii_redaction_config: PiiRedactionConfig | None = None) -> None:
    """Flush messages about to be summarized into the memory queue.
    ...
    """
    if not get_memory_config().enabled or not event.thread_id:
        return

    user_id = resolve_runtime_user_id(event.runtime)
    get_memory_manager().add_nowait(
        event.thread_id,
        with_memory_locale(redact_queued_messages(list(event.messages_to_summarize), pii_redaction_config), getattr(event.runtime, "context", None)),
        agent_name=event.agent_name,
        user_id=user_id,
    )
```

当 `SummarizationMiddleware` 即将从状态里删掉旧消息时，先把
`messages_to_summarize` 用 `add_nowait`（跳过防抖、立即入队）塞进记忆队列。
否则这些消息一旦被摘要替换，就永远失去了被抽取成事实的机会。第 11 章的手动
压缩端点 `POST /api/threads/{id}/compact` 复用同一中间件，因此同样会触发这条抢救链。

### 10.3.5 第四站：updater 抽取与写入门控

updater 用 `memory.backend_config.model` 指定的 LLM 做一次调用，同时完成：
新事实提案（newFacts）、矛盾移除（含 `id`/`scope`/`reason`/可选
`replacementFactIndex`）、强化（factsToReinforce）、摘要更新，以及（如启用）
陈旧复审与合并。写入有多重门控（`agents/memory/AGENTS.md` §Extraction safety）：

- **标签门**：提案必须带 `scope`/`durability`/`authority` 标签；自动写入只接受
  user-scoped、durable、descriptive 的事实；缺失标签拒绝该项但不影响同批其他项；
- **置信度门**：`fact_confidence_threshold`（默认 0.7）以下不落盘；越界
  confidence（比如模型输出百分比 70）按项拒绝且**永不静默缩放**——缩放会改变
  阈值语义；
- **确定性强化门**：只有确定性的消息处理能"确认"一条事实（在最近 6 条过滤后
  消息中出现人类消息），LLM 的 factsToReinforce 只提供事实绑定，模型判定永远
  不能写确认；
- **写侧近重复门**（opt-in，`fact_dedup_enabled`）：改写已有同类别事实的提案
  合并进既有事实而不是追加（确定性 token-Jaccard 相似度，无网络）。

抽取成本门 `memory.prescreen`（off/shadow/enforce）是**成本门而非安全边界**：
`enforce` 时低概率批次会跳过抽取调用并推进水位线。注意出厂默认
`staleness_review_enabled: true` 会让 prescreen 完全空转（跳过会连维护复审一起跳），
这是有意的保守 Phase 1 策略（`config.example.yaml:2397-2401` 注释）。

## 10.4 DeerMem 存储布局

DeerMem 的磁盘布局（`agents/memory/AGENTS.md` §Identity and isolation）：

```text
{base_dir}/users/{user_id}/memory.json                       # 共享摘要 + 修订数据
{base_dir}/users/{user_id}/agents/{agent_name}/facts/{sha256-prefix}/{fact-id}.md
```

- `memory.json` 只存共享摘要（`user.*` / `history.*`）、revision 与时间戳，
  **绝不存事实或事实索引**；
- 每条事实一个 Markdown 文件，YAML front matter 携带 id、category、confidence、
  createdAt、source 等元数据；
- 缺失 agent 名映射到保留名 `__default__`；公共 agent 名在本地存储规范化为小写；
- 使用侧数据（usage/audit/每线程抽取水位线 sidecar）放在 agent 目录的
  `.metadata/` 下，不得改动规范 Markdown 的时间戳；
- 写入使用用户锁 + 共享 revision + 事实 revision + 恢复日志；点操作可以在所有
  原始事实前置条件仍成立时 rebase；快照操作在 manifest 冲突后必须重载重算。

`storage_class: markdown`（`config.example.yaml:2477`）让摘要读取容忍 Markdown
包裹：只有闭合 `memory-json` 围栏里的 JSON 对象被接受，解码发生在检查围栏之前，
所以嵌入反引号不会破坏解析。损坏（非法 UTF-8、无法解析的摘要）进隔离区等待重建，
`OSError` 抛 `MemoryStorageCorruption` 并保留原文件。

## 10.5 源码走读：容量淘汰 select_facts_for_capacity()

事实数量受 `max_facts`（默认 100，`DeerMemConfig` 允许 10–500）约束。所有
自动、手动、工具与导入路径统一走
`backends/deermem/deermem/core/eviction.py:157` 的 `select_facts_for_capacity()`：

```python
def select_facts_for_capacity(
    facts: list[dict[str, Any]],
    *,
    max_facts: int,
    policy: str,
    usage: dict[str, dict[str, Any]] | None = None,
    now: datetime | None = None,
    confidence_weight: float = 0.65,
    confirmation_weight: float = 0.25,
    access_weight: float = 0.10,
    confirmation_half_life_days: float = 90,
    access_half_life_days: float = 30,
    correction_reserved_fraction: float = 0.10,
    correction_reserved_max: int = 10,
) -> FactEvictionDecision:
    """Select facts under the configured cap without mutating the snapshot.

    ``confidence`` exactly preserves the historical ranking. ``hybrid-v1``
    combines three bounded signals and reserves only the minimum number of
    correction slots; unused slots immediately return to ordinary competition.
    """
```

### 10.5.1 策略一：confidence（默认，历史排序）

`_score_fact`（`eviction.py:115`）在 `policy == "confidence"` 时直接返回：

```python
    confidence = _bounded_number(fact.get("confidence"), default=0.5)
    if policy == EVICTION_POLICY_CONFIDENCE:
        return FactEvictionScore(
            value=confidence,
            components={"confidence": confidence},
        )
```

分数就是事实的 confidence（bounded 到 [0,1]，缺省 0.5）。排序后保留前
`max_facts` 个，其余进入 `evicted` 审计列表。确定性、可解释，但有一个已知缺陷：
一条低置信度但刚被用户反复确认的纠错事实，可能挤不过一条高置信度却早已过时的
旧事实——这正是 #4641 报告、#4789 修复的问题。

### 10.5.2 策略二：hybrid-v1（opt-in，三信号混合）

```python
    confirmation = _confirmation_freshness(
        fact,
        now=now,
        half_life_days=confirmation_half_life_days,
    )
    access = _normalized_access_heat(
        usage,
        now=now,
        half_life_days=access_half_life_days,
    )
    value = confidence_weight * confidence + confirmation_weight * confirmation + access_weight * access
```

三个信号（权重默认 0.65 / 0.25 / 0.10，总和必须为 1.0）：

| 信号 | 含义 | 半衰期 |
| --- | --- | --- |
| `confidence` | 事实置信度 | — |
| `confirmationFreshness` | 显式用户确认的时间衰减（`lastConfirmedAt`）；无确认时用 `createdAt` 打五折（"创建弱于确认"，`eviction.py:89`） | 90 天 |
| `accessHeat` | 查询命中的访问热度：**只有 `memory_search` 真正返回的事实才计数**，提示词注入与 `get_context()` 不计（`agents/memory/AGENTS.md` §Capacity and review） | 30 天 |

热度归一化用 `min(1.0, log1p(decayed_heat) / log(9))`（`eviction.py:112`），
即 heat=8 时约等于 1.0，压制单次爆点。

### 10.5.3 correction 预留槽

hybrid-v1 为 `category == "correction"` 的事实预留槽位（`eviction.py:216-223`）：

```python
    if policy == EVICTION_POLICY_HYBRID_V1 and max_facts > 0:
        correction_slots = min(
            correction_reserved_max,
            math.ceil(max_facts * correction_reserved_fraction),
        )
        corrections = [item for item in ranked if str(item[1].get("category") or "").strip().lower() == "correction"]
        reserved_count = min(correction_slots, len(corrections), max_facts)
        selected_indexes.update(index for index, _fact in corrections[:reserved_count])
```

预留数量 = min(10, ceil(max_facts × 10%), correction 事实数)。动机与注入侧的
`guaranteed_categories: [correction]` 对齐——"别用 pip 了，用 uv"这类高信号纠错
即使在预算紧张时也必须注入，那存储侧也应保证它不被淘汰。未用满的槽位立即回归
普通竞争（文档字符串所言）。

### 10.5.4 影子模式：先审计，再切换

updater 侧的 `_select_for_capacity`（`updater.py:956`）展示影子模式怎么工作：

```python
        decision = select_facts_for_capacity(
            facts,
            policy=self._config.fact_eviction_policy,
            **common,
        )
        shadow_decision = None
        if self._config.fact_eviction_shadow_enabled and self._config.fact_eviction_policy == EVICTION_POLICY_CONFIDENCE:
            shadow_decision = select_facts_for_capacity(
                facts,
                policy=EVICTION_POLICY_HYBRID_V1,
                **common,
            )
        return decision.kept, decision, shadow_decision
```

即：**生效的仍然是 confidence 策略**，hybrid-v1 只是额外算一遍并记录分歧
（`fact_eviction_shadow_enabled: true`），审计写在规范持久化成功之后
（`_record_capacity_decision`，`updater.py:1000`，best-effort，异常只告警）。
切换策略前先开影子观察分歧率，是官方推荐的路径。

### 10.5.5 评测基准：deermem_eviction

`backend/scripts/benchmark/deermem_eviction/README.md` 记录了受控对比：
钉死 LongMemEval oracle 数据集（revision + SHA-256）、40 个官方用例 + 5 个
合成 correction 守卫、每个用例 1 条支撑事实 + 9 条确定性干扰项、容量 5/7/9、
固定评测时钟 `2026-08-13T00:00:00Z`。关键是它**直接调用生产
`select_facts_for_capacity()`**，不复制评分实现、不引入第三种策略。

离线结果（容量 7，README "Deterministic reconstruction" 一节）：

| Suite | confidence | hybrid-v1 |
| --- | ---: | ---: |
| 40 official + 5 synthetic | 27/45 | 45/45 |

即 confidence 策略在 18 个用例里把支撑事实淘汰了，hybrid-v1 全部保住。
已发布的真实 QA 运行（`results/pr4789-reproduction-v1/`）进一步显示官方场景
准确率 23/40 vs 35/40（McNemar p=0.0018）。基准命令全部从 `backend/` 运行：

```bash
PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction validate-contracts
PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction run-policy \
  --dataset "$LONGMEMEVAL_ORACLE_PATH" \
  --output-dir /tmp/deermem-eviction-policy-run
PYTHONPATH=. uv run pytest tests/test_bench_deermem_eviction_*.py -q
```

离线测试套件不依赖网络、凭证或 LongMemEval 数据集——`run-policy` 需要数据集
（CLI 永不自动下载），`validate-contracts` 与 pytest 则完全离线。

## 10.6 检索与注入

### 10.6.1 检索适配器

`retrieval_adapter: fts5`（默认）选择持久化 SQLite FTS5 索引；空值回退到子串
匹配。索引是**可重建的派生数据**，默认位于 `{storage_path}/.retrieval`
（`retrieval_index_path` 可改）；多实例共享 `storage_path` 时必须保持实例本地
（SQLite WAL 不支持网络文件系统）。中文分词需要 `memory-zh` extra（jieba）。

跨进程新鲜度：`rebuild_index` 在读取作用域完整事实列表前记录 manifest 签名
`(mtime_ns, size, revision)`；`search_facts` 发现签名漂移（对端写过该用户的记忆）
就先重建。写入方在提交后同步推进同步作用域的签名，所以自己的写入不会触发多余重建。

### 10.6.2 注入：DynamicContextMiddleware 与冻结快照

`agents/middlewares/dynamic_context_middleware.py:364` 的
`DynamicContextMiddleware` 把记忆与当前日期作为 `<system-reminder>` SystemMessage
注入。设计动机写在文件头：

> The system prompt is kept fully static for maximum prefix-cache reuse across
> users and sessions. ... Both are delivered once per conversation as a dedicated
> <system-reminder> SystemMessage inserted before the first user message
> (frozen-snapshot pattern).

也就是：系统提示词完全静态（不同用户共享前缀缓存），记忆+日期作为**冻结快照**
插在第一条用户消息之前，会话期内不再变化；跨天时再注入一条轻量的日期更新提醒。
预算由 `max_injection_tokens`（默认 2000）控制，token 计数默认 tiktoken（首次
使用可能联网下载 BPE 数据；内网环境设 `token_counting: char` 用无网络的 CJK
感知字符估算）。`guaranteed_categories: [correction]` + `guaranteed_token_budget:
500` 让纠错类事实从保留额度走，不被常规预算挤掉。

`memory.injection_enabled: false` 关闭整个注入块；每个自定义 agent 也可以在自己的
`config.yaml` 里设 `memory_enabled: false` 整体退出记忆（动态上下文只保留日期提醒，
并对服务端标记的 `__memory` 条目发 `RemoveMessage` 清理旧 checkpoint）。

每次运行会哈希生效的记忆块并记录 `context:memory` 事件（`content_sha256`），
完整记忆文本留在 checkpoint state；只有当前中间件输出能建立首轮记忆身份，
伪造的动态上下文标记会被 Gateway 输入处理剥掉。

## 10.7 配置详解：config.yaml → memory: 段

`config.example.yaml:2353` 起。分两层：

**宿主共享层**（直接写在 `memory:` 下）：

```yaml
memory:
  enabled: true
  injection_enabled: true # Whether to inject memory into system prompt
  shutdown_flush_timeout_seconds: 30.0
  manager_class: deermem
  mode: middleware
```

- `enabled` / `injection_enabled` 是两个独立开关：前者关掉全部捕获，后者只关注入
  （后台仍可积累记忆，比如先只攒不注）；
- `shutdown_flush_timeout_seconds`（1–300 秒）是 Gateway 优雅停机时排空待处理
  更新的硬预算：每个待处理项要做一次 LLM 调用，IM 大批量场景要调高，且必须装进
  K8s `terminationGracePeriodSeconds`，否则 SIGKILL 会掐断排空；
- `manager_class` 解析失败直接抛 `ValueError`（fail-fast：持久状态不允许被静默
  换成别的存储）。

**后端私有层**（`memory.backend_config:`，`config.example.yaml:2475`）：

```yaml
  backend_config:
    storage_path: ""            # empty = deer-flow base_dir ... per-user memory under {storage_path}/users/{uid}/memory.json
    storage_class: file
    strict_user_scope: false
    manifest_filename: memory.json
    retrieval_adapter: fts5
    debounce_seconds: 30
    max_wait_seconds: 300
    queue_max_depth: 1000
    model:                      # LLM for memory extraction; omit all fields = no extraction
      # provider: openai
      # model: gpt-4o-mini
      # api_key: $OPENAI_API_KEY
    max_facts: 100
    fact_confidence_threshold: 0.7
    fact_eviction_policy: confidence # confidence | hybrid-v1
    fact_eviction_shadow_enabled: false
    max_injection_tokens: 2000
    token_counting: tiktoken
    guaranteed_categories:
      - correction
    guaranteed_token_budget: 500
    staleness_review_enabled: true
    consolidation_enabled: false
```

注意 `model` 省略全部字段 = 不做抽取（非 LLM 操作仍可用，更新会报错）——你可以
用"只注入不抽取"的模式跑只读记忆。

**旧字段自动迁移**：`memory_config.py:29` 的 `_LEGACY_DEERMEM_FIELDS` 列出抽象化
之前写在 `memory:` 顶层的字段（`storage_path`、`max_facts`、`debounce_seconds`、
`model_name`、`staleness_*`、`consolidation_*`……）。`load_memory_config_from_dict`
（`memory_config.py:243`）在加载时把它们迁进 `backend_config` 并打 warning，升级
不会静默丢配置；其中 `storage_path` 若是文件式路径（以 `.json` 结尾）会被**丢弃**
并告警——DeerMem 现在把 `storage_path` 当根目录。未知顶层键同样告警后忽略
（很可能是拼写错误）。

**热更新边界**：`get_memory_config()`（`memory_config.py:203`）在每次读取时触发
签名校验的配置重载，配置文件损坏时回退到上次好的单例，让进行中的轮次正常完成。
`memory.prescreen` / `memory.signal_classification` 的判定器编辑通过
`MemoryManager.refresh_judge` 热加载到缓存的 manager 上——`enforce → off` 的回滚
立即生效，无需重启。

**评测注意**：`memory.prescreen` 的 egress 注释（`config.example.yaml:2392-2395`）
明确指出：被判定文本（用户 + 最终助手轮）会发送到 TypeSafe API——这是你自己
抽取模型之外的第二个目的地，且 `pii_redaction_middleware` **不覆盖这条路径**。
开启前要评估合规。

## 10.8 认知风格 cognitiveStyle 与记忆设置页

`backend/docs/MEMORY_COGNITIVE_STYLE.md` 定义了记忆 schema 中的协作风格槽位：

> **Skills teach the agent how to do tasks; memory's `cognitiveStyle` teaches the
> agent how to think and collaborate with this user.**

解决的问题：语义混装——"偏好 TypeScript"（项目偏好）和"先给结论再展开"
（协作协议）都落进同一个 facts 池，模型需要自行猜哪条是协作协议。因此
schema 增加：

| 层 | 角色 |
| --- | --- |
| `user.cognitiveStyle.summary` | 2–4 句推理与协作习惯段落 |
| `facts[]` 带 `category: cognitive` | 原子化、置信度排序的补充 |
| 注入渲染 | 在 User Context 下作为 `Thinking Style:` 展示 |

写频率刻意做成"慢变量"：每轮都读（注入），但只有抽取模型看到持久的新证据、
JSON 里出现 `cognitiveStyle.shouldUpdate: true` 才更新文本——闲聊轮次不会重写它。
`MEMORY_COGNITIVE_STYLE.md` 的"Adding a new memory field"表还给出了 schema
演进的七步清单（后端 normalize → 前端 normalize → 类型/API → 更新器 prompt →
设置 UI/i18n → 测试 → 导入路径），新增记忆字段时必须全链路对齐，老导出文件
才能继续工作。

`backend/docs/memory-settings-sample.json` 是前端 Settings → Memory 页面的
样例数据（通过 Gateway 记忆 API 的导入功能灌入）：顶层 `version`/`lastUpdated`/
`user`/`history`/`facts` 信封，facts 数组每条带 `id`/`content`/`category`/
`confidence`/`createdAt`/`source`。其中 `fact_review_009` 是给删除测试准备的
一次性条目，`fact_review_010` 给编辑测试——样例数据本身就是一份手工验收脚本。

## 动手实验

### 实验 A：跨会话记忆复现

1. `config.example.yaml` 确认 `memory.enabled: true` 且 `backend_config.model`
   填好抽取模型（如 `provider: openai` + `model: gpt-4o-mini`），`make dev` 启动。
2. 线程 1 里说一条稳定偏好："记住：我以后所有 PR 标题都要用英文写，正文附中文翻译。"
3. 等 ≥ `debounce_seconds`（默认 30 秒）+ 抽取时间，打开 Settings → Memory 页面，
   或 `GET /api/memory`，确认出现了 category 为 `preference`/`workflow` 的事实
   （对照 `memory-settings-sample.json` 的 `fact_review_002`）。
4. 新建线程 2，问"帮我写个 PR 标题"，观察 agent 是否直接用英文标题；
   同时在日志里找 `context:memory` 事件（`content_sha256`）确认注入发生。
5. （可选）同轮说一条纠错："更正：以后用 uv 不用 pip。"等防抖过后确认
   `category: correction` 的事实出现——hybrid-v1 的预留槽保护的正是这类事实。
6. 想快速造数据做 UI 演示？用 Gateway 记忆 API 导入 `memory-settings-sample.json`。

### 实验 B：观察两种淘汰策略（离线，不需 LLM）

1. 从 `backend/` 运行契约校验（完全离线）：

   ```bash
   PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction validate-contracts
   ```

2. 下载一次钉死版本的 LongMemEval oracle（约 15 MB，可用 hf-mirror.com 镜像，
   详见 `backend/scripts/benchmark/deermem_eviction/README.md` 的 curl 命令），
   `export LONGMEMEVAL_ORACLE_PATH=...` 后跑：

   ```bash
   PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction validate --dataset "$LONGMEMEVAL_ORACLE_PATH"
   PYTHONPATH=. uv run python -m scripts.benchmark.deermem_eviction run-policy \
     --dataset "$LONGMEMEVAL_ORACLE_PATH" --output-dir /tmp/deermem-eviction-policy-run
   ```

3. 检查输出：`policy.raw.jsonl` 每行含 fact IDs、kept/evicted IDs、score
   components、support retention（只含元数据，无事实内容）；`summary.json`
   按来源/场景/容量/策略聚合支撑事实保留率。对比容量 7 下 `confidence` 27/45
   与 `hybrid-v1` 45/45——然后回答：confidence 策略淘汰支撑事实的原因是什么？
   （提示：支撑事实的 confidence 并不比干扰项高，而 hybrid-v1 的确认新鲜度与
   纠错预留槽救了它。）
4. 若不想下载数据集，直接读 `eviction.py` 手工构造 11 条事实（1 条
   `category: correction` 低 confidence + 10 条高 confidence），在 Python 里调用
   `select_facts_for_capacity(facts, max_facts=10, policy=...)`，验证 correction
   预留槽让纠错事实存活。

## 常见坑

1. **改了 `memory.backend_config` 不生效**——记忆设置属于"构造出来的后端"
   （`agents/memory/AGENTS.md`：*"Settings belong to the constructed backend and
   require backend recreation to change"*）。常规 memory 配置键热加载，但后端
   私有参数需要重启 Gateway 重建 manager。
2. **旧配置字段写在 `memory:` 顶层**——升级后启动日志出现
   "Migrated legacy top-level memory fields into backend_config" 警告。功能不受
   影响，但请把字段移到 `memory.backend_config` 下消除警告；顶层 `storage_path`
   指到 `.json` 文件时会被直接丢弃。
3. **内网环境卡在 tiktoken**——`token_counting: tiktoken`（默认）首次使用可能
   从公网下载 BPE 编码数据（issues #3402/#3429），网络受限时长时间阻塞。设
   `token_counting: char` 预防。
4. **开了 prescreen 却毫无反应**——出厂默认 `staleness_review_enabled: true`，
   而跳过会连维护复审一起跳，所以批次根本不进入判定（`config.example.yaml:2397`
   注释：*"With the defaults shipped here, shadow/enforce therefore sees no
   batches until staleness_review_enabled is turned off"*）。这是有意的保守策略；
   且 `enforce` 必须先通过 `scripts/eval_memory_prescreen.py` 的度量门。
5. **hybrid-v1 的 access heat 迟迟为 0**——只有 `memory_search` 工具的真实命中
   才累加热度；默认注入与 `get_context()` 不计。middleware 模式下没人调用
   `memory_search`，热度信号自然全零，此时 hybrid-v1 退化为 confidence +
   confirmation 两信号。
6. **多实例共享存储**——`retrieval_index_path` 必须实例本地（Helm 用 emptyDir）；
   SQLite WAL 在网络文件系统上不受支持。共享 `storage_path` 而把索引放进存储根
   会在启动校验时收到警告。

## 下一步

记忆解决了"记住用户"，但单会话内部还有一个对手：上下文窗口。当对话逼近 token
上限时，谁来压缩历史、哪些防护栏防止 agent 越轨？下一章
[第 11 章 上下文工程与长对话治理](11-context-engineering.md)拆解
`SummarizationMiddleware`（本章的 `memory_flush_hook` 正是它的钩子）、
手动压缩端点与 guardrails 全家桶。
