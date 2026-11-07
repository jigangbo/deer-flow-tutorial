# 第 12 章 定时任务与 IM 渠道

> 前两章解决的是"会话内"的治理。本章进入生产自动化：让 DeerFlow 在没有人在场的
> 时刻自己醒来干活（scheduler），并把同一个 agent 通过 IM 渠道（飞书/Slack/Telegram/
> Discord/钉钉/QQ/WeCom/微信/Buzz/GitHub）接进团队日常。两者的共同底座是同一个
> Gateway run 生命周期——**scheduler 决定"何时"，不改变"如何"**。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 调度计算（cron/once/interval） | `backend/packages/harness/deerflow/scheduler/schedules.py:60` |
| 停止规则与启动 prompt 组装 | `backend/packages/harness/deerflow/scheduler/stop_rule.py:30` |
| 能力准入开关 | `backend/packages/harness/deerflow/scheduler/runtime.py:21` |
| 调度服务主循环 | `backend/app/scheduler/service.py:207`（类）、`service.py:446`（run_once）、`service.py:1244`（start） |
| 计划 run 启动入口 | `backend/app/gateway/services.py:2876` |
| 运行状态枚举 | `backend/packages/harness/deerflow/persistence/scheduled_tasks/model.py:56` |
| 单活跃约束迁移 | `backend/packages/harness/deerflow/persistence/migrations/versions/0007_scheduled_run_active_index.py:28` |
| 生命周期规则汇总 | `backend/packages/harness/deerflow/persistence/AGENTS.md:44`（Scheduled-task Lifecycle） |
| 定时任务 REST 路由 | `backend/app/gateway/routers/scheduled_tasks.py:234` |
| 交互策略 | `backend/docs/RUN_INTERACTION_POLICY.md` |
| IM 渠道总纲 | `backend/app/channels/AGENTS.md` |
| 渠道实现 | `backend/app/channels/feishu.py:153`、`slack.py:112`、`telegram.py:129`、`discord.py:110`、`dingtalk.py:183` |
| 选项澄清卡片 | `backend/app/channels/feishu_card_interaction.py` |
| 凭证暂存清理 | `backend/app/channels/credential_staging.py:23` |
| config.yaml scheduler 段 | `config.example.yaml:2895` |
| config.yaml channels 段 | `config.example.yaml:3138`（feishu） |

## 12.0 学习目标

读完本章，你应该能够：

1. 解释 `scheduler.enabled` 与 `scheduler.tool_enabled` 的两级开关语义，以及
   owner-bound 能力准入（`SchedulerRunCapability`）如何限制"谁能建计划、计划能停谁"；
2. 走读 `ScheduledTaskRunStatus` 的八种状态与 `uq_scheduled_task_run_active`
   唯一约束，说明队列如何在重启后存活、租约如何防两个实例重复派发；
3. 描述计划轮的非交互约束：`ask_clarification` 被排除、`non_interactive` 等键
   只对内部认证调用方生效（run-context 信任边界）；
4. 了解 `scheduler.multi_instance=true` 的三个前置条件与恢复语义；
5. 画出一条 IM 消息从平台 WebSocket 到 Gateway run 再回到平台的完整链路。

## 12.1 定时任务 MVP：两级开关与 owner-bound 能力

### 12.1.1 配置总闸

`config.example.yaml:2895`：

```yaml
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

`enabled` 打开后台调度器（lifespan 启动 `ScheduledTaskService`）；`tool_enabled`
只决定**是否给对话注入 schedule 工具**。`backend/packages/harness/deerflow/scheduler/runtime.py:21`：

```python
def scheduler_tools_enabled(app_config: Any) -> bool:
    """Require both operator switches, including for already assembled tools."""
    scheduler = getattr(app_config, "scheduler", None)
    return bool(getattr(scheduler, "enabled", False) and getattr(scheduler, "tool_enabled", False))
```

两个开关必须同时打开才提供工具——这就是根 `AGENTS.md` Scheduled-task note 里
"scheduler.tool_enabled（默认 off）通过 Gateway 能力准入提供 owner-bound 的
schedule 工具"的实现。能力通过 `SchedulerRunCapability` 协议
（`scheduler/runtime.py:10`）下发，带 `mode: "interactive" | "scheduled"`：
**交互轮**创建/管理自己的计划；**计划轮**（scheduled 模式）只能调用
`stop_current_schedule()` 停止"自己这一条"计划——每次调度轮只允许停自己的
schedule，不能操作别人的，也不能结束循环计划（每轮目标达成不终止 recurring 计划，
见根 `AGENTS.md`）。

工作区页面是 `/workspace/scheduled-tasks`，REST 端点在
`backend/app/gateway/routers/scheduled_tasks.py`：`POST /scheduled-tasks`（创建）、
`PATCH /scheduled-tasks/{task_id}`、`pause` / `resume` / `trigger` / `DELETE`、
`GET /scheduled-tasks/{task_id}/runs`（运行历史）等；另有咨询型端点
`POST /scheduled-tasks/preview-cron`（第 234 行）——它要求 `threads:read` 权限，
在有界线程里调用共享调度计算器保留 DST 语义，返回 UTC 与本地时间偏移的将来触发点，
**不做任何预约**（backend `AGENTS.md` Runtime 段）。

### 12.1.2 三种 schedule_type 与 cron 的 DST 语义

`backend/packages/harness/deerflow/scheduler/schedules.py:60` 的 `next_run_at()`
支持三种类型：`once`（一次性 `run_at`）、`cron`（5 字段 croniter 表达式）、
`interval`（`every_seconds`）。所有时间统一归一到 UTC 存储——注释解释了原因
（`schedules.py:80-83`）：SQLite 的时间列丢弃时区，非 UTC 偏移会让实际触发时间
整体偏移。cron 分支最有意思的是夏令时处理（`schedules.py:95-103`）：

```python
        # During a daylight-saving fall-back (e.g. 03:00 -> 02:00), an ambiguous
        # wall-clock hour repeats twice. croniter returns both occurrences (the
        # first with fold=0, the second with fold=1). For fixed-time tasks
        # (where neither minute nor hour contains '*'), running twice on the
        # same calendar day violates the cron contract (Vixie cron / POSIX
        # behavior). Skip the second occurrence (fold=1) to preserve once-per-day
        # semantics while letting wildcard schedules (e.g. '0 * * * *') fire each hour.
        if next_local.fold == 1 and _is_fixed_time_cron(cron_expr) and _is_ambiguous_datetime(next_local):
            next_local = it.get_next(datetime)
```

固定时刻的 cron（如 `0 9 * * *`）在夏令时回拨日跳过第二次出现（fold=1），
保持"每天一次"的 POSIX cron 契约；通配表达式（如 `0 * * * *`）则每小时照常触发。
`_is_fixed_time_cron`（`schedules.py:43`）通过检查 minute/hour 字段是否含
`*`/`/`/`-`/`,` 判断是否为固定时刻。

`should_advance_schedule_cursor`（`schedules.py:11`）规定：手动 trial 永远不推进
recurring 计划的游标（`persistence/AGENTS.md:46`：手动 interval/cron 试运行从不
推进 `next_run_at`，即使已逾期；但 trial 会占用单活跃槽位，trial 结束后逾期的
正式 occurrence 仍可被认领并补跑一次 catch-up）。

### 12.1.3 停止规则：存储与注入分离

`backend/packages/harness/deerflow/scheduler/stop_rule.py` 管理"停止条件"：

```python
STOP_RULE_PREFIX: Final[str] = "Stop rule from the user: when this is true, report it and call stop_scheduled_task to pause this schedule: "
STOP_RULE_NO_TOOL_PREFIX: Final[str] = "Stop rule from the user (this run cannot pause the schedule; if it is true, say so clearly so the user can pause it): "
MAX_STOP_CONDITION_CHARS: Final[int] = 500

def launch_prompt(prompt: str, stop_condition: str | None, *, can_stop: bool) -> str:
    """Compose the launched message: the stored prompt plus the stop rule."""
    if not stop_condition:
        return prompt
    prefix = STOP_RULE_PREFIX if can_stop else STOP_RULE_NO_TOOL_PREFIX
    return f"{prompt.rstrip()}\n\n{prefix}{stop_condition}"
```

设计原则写在文件头：停止条件存在 `scheduled_tasks.stop_condition` 自己的列里，
**绝不写进 prompt 存储**；只有启动那一刻才由 `launch_prompt()` 拼成模型可见段落。
`can_stop` 取决于这次 run 是否拿到了 `stop_scheduled_task` 工具（读 live 配置，
`service.py:257` 的 `_can_stop_itself`）——拿不到工具时措辞换成"无法暂停，但请
明确说出条件已满足"，配置重载永远不会让 run 调用一个它没有的工具。

## 12.2 源码走读：occurrence 生命周期与队列

### 12.2.1 状态机：ScheduledTaskRunStatus

`backend/packages/harness/deerflow/persistence/scheduled_tasks/model.py:56`：

```python
class ScheduledTaskRunStatus(StrEnum):
    """Canonical status vocabulary for scheduled-task occurrences."""

    QUEUED = "queued"
    LAUNCHING = "launching"
    RUNNING = "running"
    SUCCESS = "success"
    UNMET = "unmet"
    FAILED = "failed"
    SKIPPED = "skipped"
    INTERRUPTED = "interrupted"
```

三个**活跃**状态（`queued/launching/running`）与五个**终态**
（`success/unmet/failed/skipped/interrupted`）分别由 `ACTIVE_RUN_STATUSES`
（`model.py:81`）与 `TERMINAL_RUN_STATUSES`（`model.py:72`）两个 frozenset 固定，
是 API 与仓储共享的词汇表（backend `AGENTS.md` 明确要求它们与 API 的 occurrence
状态集合一致，改动两处必须同步）。`unmet` 是个容易忽略的语义：run 正常完成但
**停止条件/目标判定未达成**——它算终态但不算失败。父任务状态则是另一组词汇
（`model.py:92-93`）：`TERMINAL_TASK_STATUSES = {"completed", "failed", "cancelled"}`、
`LIVE_TASK_STATUSES = {"enabled", "running", "paused"}`。

### 12.2.2 单活跃约束：uq_scheduled_task_run_active

每次 occurrence 启动要经过两步：先把到期的 occurrence 写成 `queued`（持久排队），
再由执行预算认领。关键不变量是**每个 task 同时最多一个活跃 occurrence**，由
部分唯一索引 `uq_scheduled_task_run_active` 强制（migration
`0007_scheduled_run_active_index.py:28`）：

```python
    """Supersede duplicate active rows so the partial unique index can be built.

    ``uq_scheduled_task_run_active`` enforces at most one queued/running row per
    ``task_id``. A DB that already has two+ active rows for the same task (the
    exact TOCTOU this PR closes: two concurrent ``dispatch_task`` calls both
    passed ``has_active_runs`` and both inserted a "queued" row) would fail
    ``CREATE UNIQUE INDEX`` and abort the alembic upgrade, blocking gateway
    startup. ...
```

这个约束同时是几件事的根基（backend `AGENTS.md` Scheduled-task dispatch 段）：

- **队列在重启后存活**——`queued` 行是持久行，重启不会丢；
- **只有租约围栏内的 `launching` 才调用 Gateway**——`running` 引用持久 run；
- **稳定的准入键**（`scheduled-task:{scheduled_task_run_id}` 幂等键，见下文）
  在恢复后可以复用。

`backend/app/gateway/services.py:2876` 的 `launch_scheduled_thread_run()` 是
"队列 → 真实 run"的唯一桥梁：

```python
    body = RunCreateRequest(
        assistant_id=assistant_id,
        input=graph_input,
        command=None,
        metadata=metadata or {},
        config={"recursion_limit": _resolve_scheduler_recursion_limit()},
        ...
        # ``user_id`` mirrors what IM channels put in ``body.context`` so
        # runtime-context consumers without a ContextVar fallback (e.g.
        # user-scoped GuardrailMiddleware providers) see the owning user;
        # ``inject_authenticated_user_context`` skips the internal user.
        context=({"non_interactive": True, "user_id": owner_user_id} if owner_user_id else {"non_interactive": True}),
        ...
        multitask_strategy="reject",
        ...
    )
    ...
    with ensure_trace_context():
        record = await start_run(
            body,
            thread_id,
            request,
            idempotency_key=f"scheduled-task:{scheduled_task_run_id}" if ... else None,
            evidence_origin="scheduled",
            scheduled_task_runtime=scheduled_task_runtime,
        )
```

注意它**不走任何特殊路径**：构造的就是标准 `RunCreateRequest`，交给与 HTTP
run 相同的 `start_run()`。计划消息有稳定 ID（`scheduled-{run_id}`），重试启动与
重连水合看到同一条消息；`recursion_limit` 默认 1000（与 Web UI 一致），dispatch
时从 `get_app_config()` 读取并被 `max_recursion_limit` 钳制
（`services.py:1334` 的 `_resolve_scheduler_recursion_limit`），YAML 改动下一次
run 生效、无需重启。`multitask_strategy="reject"` 保证同线程已有 run 在飞时
ConflictError → 该 occurrence 重新排队（backend `AGENTS.md`：Reused-thread
ConflictError requeues；其他启动错误失败）。

### 12.2.3 轮询主循环：认领、预算与队列超时

`backend/app/scheduler/service.py:446` 的 `run_once()` 是每 5 秒（`poll_interval_seconds`）
执行一次的心跳：

```python
    async def run_once(self, *, now: datetime) -> None:
        if self._multi_instance:
            ...  # 租约对账
        else:
            await self._task_run_repo.recover_expired_launch_claims(
                error=_LEASE_RECOVERY_ERROR,
                now=now,
            )
            ...
        await self._expire_waiting_runs(now=now)
        await self._drain_queue(now=now)
        # Admission and execution capacity are separate. Due occurrences are
        # persisted even when all execution slots are busy; claim_queued_run()
        # applies the global launch budget under the database lock.
        claimed = await self._task_repo.claim_due_tasks(
            now=now,
            lease_owner=self._lease_owner,
            lease_seconds=self._lease_seconds,
            limit=self._max_concurrent_runs,
        )
```

"准入与执行容量分离"是注释点题的设计：到期 occurrence **先持久化为 queued**，
即使所有执行槽都忙——这就是"busy occurrences persist as queued"（根 AGENTS.md）
的实现，替代了旧的"重叠即跳过"（**不要重新引入 skip-on-overlap**）。随后
`claim_queued_run`（`persistence/scheduled_task_runs/sql.py:559`）在数据库锁下
检查全局预算 `max_concurrent_runs` 与 per-owner 预算
`max_concurrent_runs_per_user`（后者生效值是 `min(per_user, max_concurrent_runs)`，
构造函数 `service.py:232-235` 注释：默认 3 全局 / 2 每用户，保证一个 owner 永远
给其他人留一个槽）。Postgres 用 advisory lock 序列化 count+UPDATE，SQLite 用
`BEGIN IMMEDIATE`；`list_queued_runs` 的公平队列按 owner 的同线程 FIFO 头排序
（`sql.py:464` 的 `_fair_queue_statement`），即使没开 per-owner 上限，排空也
是 owner 公平的。

`queue_timeout_seconds`（默认 3600）给排队等待设上限：超过后该 occurrence 失败
（错误码 `RUN_ERROR_QUEUE_TIMEOUT`，`scheduler/host_notes.py:14`：
`"scheduled task run queue wait timeout exceeded"`），并推进后续调度游标。

### 12.2.4 重启与多实例恢复

`service.py:1244` 的 `start()` 区分两种模式：

```python
    async def start(self) -> None:
        if self._task is not None:
            return
        restart_error = _RESTART_RECOVERY_ERROR
        if self._multi_instance:
            await self._reconcile_active_state(now=datetime.now(UTC))
            self._skip_next_lease_reconciliation = True
        else:
            # This destructive sweep is safe only while Gateway lifespan awaits
            # start(): no request or poll admission can create a run owned by
            # this process yet. ...
            stale = await self._task_run_repo.mark_stale_active_runs(error=restart_error)
            ...
            stuck = await self._task_repo.cancel_stuck_once_tasks(error=restart_error)
```

单实例模式下，启动时的破坏性清扫（把上一个进程留下的活跃行标记 interrupted）
只在 Gateway lifespan 等待 `start()` 完成期间安全；多实例模式改用非破坏性的
租约对账——**存活的对端计划 run 不被保留**（backend `AGENTS.md`：Live scheduled
runs are preserved when a peer starts），过期启动认领回到持久队列，过期 run
租约原子接管，陈旧启动写入被租约所有权围栏（fenced）。

开启 `scheduler.multi_instance=true` 的前置条件（backend `AGENTS.md` Runtime 段）：
共享 Postgres、`run_ownership.heartbeat_enabled=true`、`run_events.backend=db`，
否则启动直接拒绝配置。`max_concurrent_runs` 经 Postgres advisory lock 成为
`launching`/`running` 行的**全局共享上限**。

`persistence/AGENTS.md:44`（Scheduled-task Lifecycle 段）是这套规则的权威清单，
写作/改代码前必读：`ScheduledTaskRepository.update` 是唯一的重新激活 choke point
（`status -> enabled` 时重查 `end_condition_reached` 并抛
`ScheduledTaskLimitsExhausted`）；暂停/删除原子取消 queued 工作并拒绝
launching/running；PATCH/resume 拒绝所有活跃状态；只有 queued 冲突提供暂停取消。

## 12.3 非交互约束与 run-context 信任边界

计划轮是非交互的：`ask_clarification` 从工具集中排除（根 `AGENTS.md` Scheduled-task
note），run 以 `context={"non_interactive": True}` 启动。治理规则集中在
`backend/docs/RUN_INTERACTION_POLICY.md`：

> Runs in `scheduled`, `webhook`, or `autonomous` mode must use the available
> context, make minimal reversible assumptions, list material assumptions, or
> return a structured `BLOCKED` result naming the missing decision for
> high-risk or irreversible work without sufficient authorization.
> They must never wait for a synchronous human response.

模式解析优先级：显式 `interaction_mode` > legacy 提示（`non_interactive` →
scheduled；`channel_name="github"` → webhook；`disable_clarification` →
autonomous）；未知显式模式是配置错误而非回退交互。

**信任边界**是本章最容易踩的安全坑（RUN_INTERACTION_POLICY.md §Gateway trust
boundary + `docs/ARCHITECTURE.md` §6）：

> `interaction_mode`, `non_interactive`, `disable_clarification`, and
> `channel_name` are internal-caller-only Gateway context keys. ... Public run
> requests cannot use these keys to disable clarification, impersonate a
> webhook channel, or override a scheduled run back to interactive behavior.

run 上下文有两个客户端可写入口（`body.context` 与自由格式的 `body.config`），
`merge_run_context_overrides` 只对 `internal=True` 的调用方放行这些键，
`strip_internal_context_keys` 对两个入口都做擦除——普通 HTTP 客户端传
`non_interactive: true` 会被静默剥掉。身份与沙箱生命周期字段无条件清除并从
认证状态重盖。`launch_scheduled_thread_run` 之所以能带 `non_interactive`，
是因为它以 `AUTH_SOURCE_INTERNAL` + `get_internal_user()` 构造合成请求
（`services.py:2898-2908`）。同理 `github_token` 也只对内部认证调用方生效。

## 12.4 IM 渠道：一条消息的完整旅程

`backend/app/channels/` 是 App 层（`app.*`）的 IM 集成。总纲
（`app/channels/AGENTS.md`）给出的组件地图：

| 组件 | 职责 |
| --- | --- |
| `base.py` | 抽象 `Channel` 基类（start/stop/send 生命周期）；SDK 线程回调经 `_submit_threadsafe_coroutine()` 投递到 Gateway 主循环；阻塞式 SDK 拆除必须 `asyncio.to_thread` 卸载 |
| `message_bus.py` | 入站队列 → 派发器；出站用 dispatch-start 监听器快照 |
| `manager.py` | 核心派发器：经 `client.threads.create()` 建 thread、路由 `/goal` `/agent` `/model` 等命令、选择 `runs.wait()` / `runs.stream()` / `runs.create()` 三种等待策略 |
| `store.py` | `channel_name:chat_id[:topic_id] → thread_id` 绑定存储（SQL 多副本共享 / JSON 单进程） |
| `service.py` | 渠道生命周期管理（启动、停止、重启、超时保留重试） |
| `leadership.py` | Leader lease：只有 `channel_leases` 持有者启动非 GitHub 传输（多实例防重复消费） |
| `capabilities.py` | SDK-free `CHANNEL_CAPABILITIES`：声明每个渠道是否支持主动推送、交互卡片等 |

### 12.4.1 消息流（app/channels/AGENTS.md §Message Flow）

1. 外部平台 → 渠道实现（WebSocket 长连接，**无需公网 IP 与回调 URL**）→
   `MessageBus.publish_inbound()`；
2. `ChannelManager._dispatch_loop()` 消费队列；用户自有连接的消息带
   `connection_id` / `owner_user_id`，`owner_user_id` 成为 run 的 `user_id`
   （owner-scoped 文件存储：入站文件、上传、产物都落在
   `users/{user_id}/threads/{thread_id}/user-data/{uploads,outputs}` 下）；
3. 查找/创建 thread：首次绑定用 `claim_thread_id`（insert-if-absent），竞争失败方
   采用胜者并删除自己铸的 thread；`/new` 重绑；
4. 等待策略按渠道分流（`manager.py`）：Slack/Discord 用 `client.runs.wait()` 一次
   拿最终结果；飞书/Telegram 用 `client.runs.stream(["messages-tuple", "values"])`
   增量流出（"Working on it..." 卡片原地编辑）；GitHub 用
   `runs.create()` fire-and-forget（run 进入 `pending` 即返回，agent 自己在沙箱里
   用 `gh` CLI 回帖——出站是 log-only 的）；
5. 出站 → 渠道回调 → 平台回复。

两种容易忽略的正确性细节：

- **流式发布是白名单**（`manager.py` §Stream publishing is an allowlist）：只有
  assistant 类型（`"ai"`、`"AIMessageChunk"`、OpenAI 风格 `"assistant"`）的
  messages-tuple 帧成为回复文本。旧的 `"tool"` 黑名单曾泄漏隐藏模型上下文——
  `DynamicContextMiddleware`（记忆召回、改写后的用户轮）与
  `DurableContextMiddleware` 注入的隐藏 `HumanMessage` 会随 messages-tuple 扇出；
- **run 比请求者活得久**：`runs.wait`/`runs.stream` 传 `on_disconnect: "continue"`
  ——请求者断线，run 继续跑（回复丢失但线程保留）；入站去重键在请求发出后保留
  （`_keep_dedupe_key_after`），平台重投递拿到同一条已准入 run。

### 12.4.2 五大渠道实现文件

| 文件 | 类（行号） | 特色 |
| --- | --- | --- |
| `feishu.py` | `FeishuChannel`（153） | WebSocket 长连接；每个来源一张卡片原地 patch（`config.update_multi=true`），queued → running → final 状态流转 |
| `slack.py` | `SlackChannel`（112） | Socket Mode（`app_token: xapp-...`），`runs.wait()` |
| `telegram.py` | `TelegramChannel`（129） | 接收文本/照片/文档，"Working on it..." 经 `editMessageText` 原地编辑；最终 Markdown 可选走 Bot API Rich Messages（`channels.telegram.rich_messages`，且文本含富结构时才触发） |
| `discord.py` | `DiscordChannel`（110） | discord.py 私有事件循环；跨循环出站经 `_run_on_discord_loop` 有界等待（发送 30s / 上传 120s） |
| `dingtalk.py` | `DingTalkChannel`（183） | `card_template_id` 启用 AI Card 流式（创建卡片 → `PUT /v1.0/card/streaming` → finalize）；`receive_file` 经 `downloadCode` 下载图片/文档 |

配置模板见 `config.example.yaml:3138` 起（`channels.feishu:` 的 `app_id` /
`app_secret` / `domain` / `card_interaction_enabled`，`channels.slack:` 的
`bot_token` / `app_token` / `allowed_users` 等）。凭证一律支持
`$ENV_VAR` 形式引用。Docker Compose 里渠道跑在 gateway 容器内，`localhost`
指向容器自身——要用 `http://gateway:8001/api`（或 `DEER_FLOW_CHANNELS_LANGGRAPH_URL`）。

### 12.4.3 飞书选项澄清卡片

`channels.feishu.card_interaction_enabled`（默认 off）把 `ask_clarification` 的
选项渲染成**可点击按钮卡片**（`backend/app/channels/feishu_card_interaction.py`
的 `build_button_card` / `PendingCardRegistry`）。开启条件写在配置注释里
（`config.example.yaml:3176`）：需要在开放平台控制台的回调配置页（card.action.trigger，
与事件订阅分开）订阅卡片回调并发布新版本。点击交互的归属校验跨 worker 消费一次、
失败即 fail-closed（`app/channels/AGENTS.md` 第 49 行）。卡片交互会让 IM 对话
接近 Web 端的澄清体验，但要权衡：按钮卡片引入了额外的回调订阅与状态管理。

### 12.4.4 凭证暂存目录清理

渠道凭证写入用"暂存 + 原子发布"，崩溃会在磁盘上留下孤儿暂存文件。
`backend/app/channels/credential_staging.py` 负责清扫：

```python
_STALE_AFTER_SECONDS = 24 * 60 * 60

def cleanup_stale_credential_staging(target: Path) -> None:
    """Remove only this store's regular staging files older than a day.

    Scan siblings only, never attachments or symlink targets. The age guard
    leaves fresh files to concurrent writers. Failure to inspect or remove a
    stale copy, including failure to report it, must not stop credential loading.
    Missing files are expected when a peer completes its atomic publication.
    """
```

规则（backend `AGENTS.md` Layout 段）：清扫挂在 worker 线程状态加载路径上（含
SQL legacy 导入）；只删除 **owned** 常规文件且超过 24 小时的；匿名临时文件不动。
删除失败绝不能阻断凭证加载。命名空间由 `credential_staging_prefix()` 预留
（`.{target.name}.deerflow-` 前缀 + `.tmp` 后缀）。

## 动手实验

### 实验 A：创建并观察一个定时任务

1. `config.yaml` 打开两级开关并重启 Gateway：

   ```yaml
   scheduler:
     enabled: true
     tool_enabled: true
   ```

2. Web 端对话里说："每天早上 9 点帮我总结deer-flow仓库昨天的 commit（时区 Asia/Shanghai）"，
   agent 会调用 schedule 工具创建计划；或直接在 `/workspace/scheduled-tasks` 页面创建。
3. 用 `POST /api/scheduled-tasks/preview-cron` 验证 cron 表达式（body 传
   `cron: "0 9 * * *"`、`timezone: "Asia/Shanghai"`），核对返回的 UTC 与本地触发点。
4. 把计划改成 interval（`every_seconds` ≥ `min_once_delay_seconds`）并点
   "Run now" 手动触发，然后观察：
   - `GET /api/scheduled-tasks/{task_id}/runs` 里出现 `queued` → `running` →
     `success`/`unmet` 的状态流；
   - **手动 trial 不推进 `next_run_at`**——触发后计划的下次运行时间不变
     （`schedules.py:11` 语义）；
   - 手动触发后再立即触发第二次，第二次因单活跃约束进入 `queued`（或在忙碌时
     排队），验证"busy occurrences persist as queued"。
5. （可选）设置一个停止条件（如"当我说任务完成时"），观察 `stop_rule.launch_prompt`
   拼进 run 的段落与 `stop_scheduled_task` 工具是否出现（取决于 `tool_enabled`）。

### 实验 B：从飞书/Slack 触发一次对话

1. 在渠道开放平台创建应用拿到凭证（飞书：`app_id`/`app_secret`，选择 WebSocket
   模式，无需公网 IP；Slack：`bot_token: xoxb-...` + `app_token: xapp-...` Socket Mode）。
2. `config.yaml` 的 `channels:` 段启用对应渠道（凭证可用 `$ENV_VAR` 引用），重启 Gateway，
   在日志里确认渠道启动（`logs/gateway.log`）。
3. 在 IM 里发送 `/new` 后随便说一句话，观察：
   - 新 thread 出现在 Web 工作区（绑定存进 `channel_thread_bindings`）；
   - 飞书/Telegram 是流式卡片（"Working on it..." 原地更新），Slack/Discord 是
     等待后的完整回复；
   - 上传一个文件给 bot，确认它落在
     `backend/.deer-flow/users/{owner}/threads/{thread_id}/user-data/uploads/`
     （owner-scoped 存储）。
4. （可选）在对话里问一个需要澄清的问题，观察默认文本澄清；再开启
   `card_interaction_enabled`（需按 12.4.3 配置卡片回调）对比按钮卡片体验。

## 常见坑

1. **只开了 `scheduler.enabled` 没开 `tool_enabled`（或反之）**——调度器在跑，
   但对话里没有 schedule 工具；`scheduler_tools_enabled()` 要求两个开关同时为真
   （`runtime.py:21`）。反过来，只想用页面手动建任务、不想让 agent 建，可以只开
   `enabled`。
2. **计划轮卡在问澄清**——不会发生：计划 run 的工具集排除 `ask_clarification`，
   且策略要求非交互模式"绝不等待同步的人类回复"。如果你的集成测试看到计划 run
   等待人工，检查是否有人把 `non_interactive` 从客户端传进来——普通调用方的这个
   键会被 `strip_internal_context_keys` 擦除，只有内部认证调用方（scheduler/
   webhook 渠道策略）有效。
3. **多实例开了但前置不满足**——`scheduler.multi_instance=true` 要求共享 Postgres +
   `run_ownership.heartbeat_enabled=true` + `run_events.backend=db`，启动时直接拒绝；
   `deployment.multi_instance: true` 还要求不开 scheduler 单实例、IM 渠道开
   leader lease（`config.example.yaml:2947-2954`）。逐项核对再启动。
4. **Docker 里渠道连不上 Gateway**——`localhost:8001` 在 gateway 容器内指向容器
   自身。改用 `http://gateway:8001/api` 或环境变量 `DEER_FLOW_CHANNELS_LANGGRAPH_URL`
   （`app/channels/AGENTS.md` §Configuration）。
5. **`allowed_users` 写了 `@names`**——Telegram 只认数字用户 ID，Slack 认 `U123456`
   形态；无法解析的非空列表 fail-closed（全员拒绝），而不是放行。Buzz 与 Discord
   的空列表语义不同（Buzz 空 = 没有人，其余渠道空 = 所有人），绑定前读
   `allowed_users.py`。
6. **时区存成 "UTC" 但用户不在 UTC**——聊天保存的 interval 任务或带偏移的一次性
   `run_at` 会把时区记为 "UTC"（`timezone_source: not_needed` 占位），展示层按
   查看者时区渲染；不要把 UTC 字面时间当成"用户的 9 点"（`service.py:41`
   `_zone_is_placeholder` 的完整语义）。需要确定本地触达时，用
   `preview-cron` 端点先看一眼。

## 下一步

现在 agent 既能定时醒来，也能在 IM 里被唤醒。它们对外的统一入口都是 Gateway 的
HTTP API——下一章 [第 13 章 Gateway API 与编程接入](13-gateway-api.md)
给你 REST 路由全景、LangGraph 兼容层、文件上传协议，以及用内嵌
`DeerFlowClient` 把整套 run 生命周期装进你自己的程序。
