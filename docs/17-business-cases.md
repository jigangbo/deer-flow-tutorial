# 第 17 章 业务二次开发实战（综合案例）

## 17.0 学习目标

读完本章，你应该能够：

1. 用**需求分流决策树**为任何新需求选对承载层：Skill（提示词 + 脚本的领域流程）、
   MCP（外部系统工具化）、扩展（平台能力贡献点）、配置（开关/模型/工具组），以及
   仅剩的"改核心"情形；
2. 拿出一个企业知识库问答方案：`knowledge_base:` 开关 + `knowledge_search` 工具 +
   只读知识契约（`RetrievalProvider`）+ 知识管理扩展，理解范围选择与上游授权边界；
3. 拿出一个数据分析平台方案：Docker 沙箱隔离 + `data-analysis` / `chart-visualization`
   两个官方技能 + `tool_artifacts` 产物句柄注册表，写出可操作的完整接入步骤；
4. 拿出一个深度研报自动化方案：`deep-research` 技能 + 子代理批处理（`subagent_batches`）
   + `verification` 凭证 + 定时任务 + IM 推送的组合拳；
5. 为私有模型网关接入一个自定义模型供应商：读懂 `create_chat_model()` 的能力位
   （`supports_thinking` / `supports_vision` / `context_window` / `reasoning:` 契约），
   不改一行核心代码完成接入。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 分流依据（扩展优先） | 根 `AGENTS.md` Extension-first evaluation 段 |
| 知识能力开关 | `config.example.yaml:825`（`knowledge_base:`） |
| 知识检索工具 | `config.example.yaml:865`–`config.example.yaml:881`（`knowledge_search`） |
| 只读知识契约 | `backend/docs/KNOWLEDGE.md:12`（Provider 注册）、`:71`（Agent 工具入口配置） |
| 知识扩展示例 | `examples/deerflow-extension-knowledge/deerflow_extension_knowledge/__init__.py:48` |
| 知识管理边界 | `examples/deerflow-extension-knowledge-management/AGENTS.md`、`CONTRACT.md` |
| 数据分析技能 | `skills/public/data-analysis/SKILL.md:1`（frontmatter）、`:46`（inspect 命令） |
| 图表技能 | `skills/public/chart-visualization/SKILL.md:1`（frontmatter + `compatibility`） |
| 产物句柄注册表 | `config.example.yaml:1462`（`tool_artifacts:`） |
| 深研技能 | `skills/public/deep-research/SKILL.md:1` |
| 子代理运行时 | `config.example.yaml:2011`（`subagent_runtime:`）、`:2049`（per-agent overrides） |
| 批处理 | `config.example.yaml:2102`（`subagent_batches:`） |
| 工具凭证 | `config.example.yaml:2122`（`verification:`） |
| 定时任务 | `config.example.yaml:2895`（`scheduler:`）、`:2873`（IM 通知投递） |
| IM 渠道 | `backend/app/channels/AGENTS.md:22`（组件表）、`:58`（owner 归属文件存储） |
| 交互卡片 | `config.example.yaml:3176`（`card_interaction_enabled`）、`backend/app/channels/feishu.py:195` |
| 用户连接层 | `config.example.yaml:3063`（`channel_connections:`） |
| 模型工厂 | `backend/packages/harness/deerflow/models/factory.py:540`（`create_chat_model`）、`:19`（元数据字段表） |
| 类路径解析 | `backend/packages/harness/deerflow/reflection/resolvers.py:103`（`resolve_class`） |
| 模型配置段 | `config.example.yaml:157`（`models:`）、`:266`（GLM 必思考示例）、`:334`（Ollama 原生供应商） |

---

## 17.1 需求分流决策树

第 16 章讲过机制，本章第一件事是建立**决策纪律**。根 `AGENTS.md` 的 Extension-first
evaluation 段是权威依据：

> **Extension-first evaluation** — before implementing a feature by editing core code,
> evaluate whether it can ship as a packaged extension through the contribution points
> above. Stay in core for bug fixes and for changes to the agent loop, memory, context
> compaction, or authentication. If existing hooks cannot express the feature, add a
> generic hook to the extension contract plus an extension that uses it — do not
> hard-code business logic into core.

翻译成决策树。拿到一个需求后自顶向下问：

```
需求是什么形态？
│
├─ "教模型在某个领域按流程做事"（提示词 + 可选脚本，无需新增平台能力）
│   → Skill。放 skills/custom/（gitignored）起步，成熟后可申请进 skills/public/。
│     例：周报生成、合同审查清单、行业术语翻译。见第 7 章 7.6。
│
├─ "让模型能调用一个已有外部系统"（HTTP 服务、数据库、内部平台）
│   → MCP server。写一个 stdio/http MCP server，配置进 extensions_config.json →
│     mcpServers。核心不动，进程隔离，热启停。见第 15 章。
│
├─ "给平台加能力"（新中间件/生命周期观察/服务/HTTP 路由/浏览器页面/知识检索源）
│   → 扩展（第 16 章）。对照九大贡献点选最小覆盖的那个；全栈插件（registry.plugin）
│     一次装下页面 + action + 模型工具。
│
├─ "改一个开关/接一个模型/换一段提示词"
│   → 纯配置。config.yaml（models、tools、sandbox、verification…）或
│     extensions_config.json（mcpServers、skills）。连包都不用装。
│
└─ 以上都不行，且需求本质是 agent loop / 记忆 / 上下文压缩 / 认证的行为
    → 才考虑改核心。bug 修复直接进核心；新能力先给扩展契约加通用钩子，
      再用扩展消费它——禁止把业务逻辑硬编码进核心。
```

三条经验法则：

- **先配置，再 Skill，再 MCP，再扩展，最后核心**——承载层离核心越远，升级成本越低；
- **数据面与控制面分开**：知识/文档类接入优先走只读检索契约（`registry.knowledge_provider`），
  管理面（上传、解析、索引）放独立的管理扩展——`examples/deerflow-extension-knowledge-management/AGENTS.md`
  第一句就是"Core retrieval must never depend on it"；
- **一次 Slice 加一个贡献点**：`backend/packages/harness/deerflow/extensions/AGENTS.md:442`
  要求任何新贡献类型必须同时进公共契约与宿主运行时，绝不允许宿主静默忽略的注册方法——
  反过来也提醒我们：贡献点选型宁可小而准，不要一次堆五个。

下面五个实战分别演示决策树上不同分支的组合。

## 17.2 实战 A：企业知识库问答

**需求**：员工在对话框里提问，模型基于公司知识库（RAGFlow / WeKnora / LightRAG 等）
作答，答案可追溯到来源；管理员还能上传与解析文档。

**分流**：检索是"平台能力"（工具面 + 范围选择 UI + 引用证据）→ 核心已有 `knowledge`
工具组与只读契约；具体知识库对接是"连接外部系统" → 扩展（知识提供者）；文档管理 →
独立管理扩展。改核心为零。

### 17.2.1 配置面：开关与工具

`config.example.yaml:825`：

```yaml
knowledge_base:
  enabled: false
  # Custom-agent chat only. Keeps the selector hidden unless the effective
  # knowledge_search provider is the bundled RAGFlow tool.
  scope_selection_enabled: false
```

真正把检索挂进模型工具面的是 `tools:` 条目（`config.example.yaml:865`）：

```yaml
  # - name: knowledge_search
  #   group: knowledge
  #   use: deerflow.community.ragflow.tools:knowledge_search_tool
  #   base_url: http://localhost:9380  # Docker: use a backend-reachable URL
  #   api_key: $RAGFLOW_API_KEY
  #   datasets:  # Optional operator-controlled allowlist
  #     - 0123456789abcdef0123456789abcdef  # Replace with a RAGFlow dataset ID
  #   timeout: 30
  #   page_size: 8
  #   similarity_threshold: 0.2
  #   ...（省略 vector_similarity_weight / max_chars_per_chunk 两行）
  #   top_k: 256
  #   max_total_chars: 8000
```

注意注释里的安全设计（`config.example.yaml:863`）："Configure stable IDs only to
restrict scope. **IDs and catalog listing never reach the model**"——数据集 ID 只做
operator 侧的范围限制，模型永远看不到目录清单。`tool_groups:`（`config.example.yaml:836`）
里的 `- name: knowledge` 是这个工具的分组归属。

### 17.2.2 契约面：只读知识提供者

`backend/docs/KNOWLEDGE.md:14` 定义了接入方式：

> An operator-installed extension calls `registry.knowledge_provider(name, provider)`
> during `install()`. The method returns `False` on older hosts and is supported by
> extension-api **0.2.7**.

六种可选操作（`backend/docs/KNOWLEDGE.md:24` 的表格）：`search`（必选检索）、`sources`
（可归因证据）、`catalog`（数据集分页目录）、`documents`（数据集内文档分页）、
`dataset_filter` / `document_filter`（范围执行）。只有同时支持 `catalog` 与
`dataset_filter`，前端的范围选择器才会启用（`backend/docs/KNOWLEDGE.md:103` 附近：
`/api/features` 的启用条件）。

官方合成示例 `examples/deerflow-extension-knowledge/deerflow_extension_knowledge/__init__.py:22`
展示了范围执行的正确姿势：

```python
    async def search_scoped(self, query: str, *, context: KnowledgeRequestContext) -> RetrievalResult:
        scope = context.scope
        if scope is not None:
            if scope["mode"] == "disabled":
                raise ValueError("Knowledge search is disabled")
            if scope["mode"] == "selected":
                if scope["dataset_ids"] != [_DATASET]:
                    raise PermissionError("Selected dataset is unavailable")
                for item in scope.get("document_filters", []):
                    if item["dataset_id"] != _DATASET or item["document_ids"] != [_DOCUMENT]:
                        raise PermissionError("Selected document is unavailable")
        return await self.search(query)
```

**范围检查在 provider 内部执行**，宿主只传上下文；越权就抛 `PermissionError`，绝不
静默扩大检索范围。注册只有两行（`__init__.py:48`）：

```python
@extension(api="0.2.7", name="knowledge-example")
def install(registry, config):
    if not registry.knowledge_provider("synthetic-example", SyntheticKnowledgeProvider()):
        raise RuntimeError("This host does not support knowledge provider registration")
```

宿主会在注册时验证每个声称支持的异步操作，并把它纳入与其它贡献一致的按位置回滚
（`backend/packages/harness/deerflow/extensions/AGENTS.md:3`）。

### 17.2.3 管理面：独立扩展与授权边界

`examples/deerflow-extension-knowledge-management/AGENTS.md` 圈出了管理面的纪律：

- 管理（上传/解析/索引）与检索（只读查询）必须分属两个扩展，核心检索**永不依赖**管理扩展；
- 授权是"显式精确授权 + 宿主管理员下限 + 上游授权"三层叠加，检索绑定不授予写权限；
- 不接受客户端伪造的 user/tenant/Agent/space 身份，不重试写操作，不跟随带凭证的重定向；
- 上游处理状态是"配置能力"而非"完成证据"——可搜索的文档仍可能在继续富化，未知状态
  必须保持未知（`CONTRACT.md` 的 State and uncertainty 节）。

`examples/deerflow-extension-knowledge-platform/` 则给出平台化版本（`service.py` /
`store.py` / `router.py` / `models.py` 四件套，SQLite 存插件自有空间策略）。

### 17.2.4 落地清单

1. `config.yaml`：`knowledge_base.enabled: true` + 取消 `knowledge_search` 工具注释并填
   `base_url`/`api_key`（RAGFlow 内置路径），或安装知识提供者扩展后把 `provider` 指向
   注册名（`backend/docs/KNOWLEDGE.md:71` 的 YAML 模板）；
2. 重启 Gateway，`GET /api/knowledge/capabilities?agent_name=...` 确认能力枚举；
3. 需要文档管理再装 knowledge-management 扩展并做精确授权；
4. 验证引用：回答中的每条知识都应能回链到 `KnowledgeSource`（`backend/docs/KNOWLEDGE.md:133`
   的 Sources and citations 节）。

## 17.3 实战 B：数据分析平台

**需求**：用户上传 Excel/CSV，模型做 SQL 级分析并产出图表，文件产物可下载、可追溯。

**分流**：分析能力 = 沙箱（核心已有）+ 两个官方 Skill（现成）+ 产物管道（核心已有）。
配置层即可完成，一个扩展都不用写——这是决策树"纯配置"分支的样板。

### 17.3.1 三个构件

**构件一：沙箱隔离**。分析脚本由模型的 `bash` 工具在沙箱里执行。生产部署用
`AioSandboxProvider`（Docker 隔离），开发用 `LocalSandboxProvider`（第 8 章）。上传的
文件经虚拟路径映射出现在沙箱的 `/mnt/user-data/uploads/`，产物写到
`/mnt/user-data/outputs/`。

**构件二：`data-analysis` 技能**。`skills/public/data-analysis/SKILL.md:1`：

```markdown
---
name: data-analysis
description: Use this skill when the user uploads Excel (.xlsx/.xls) or CSV files and
  wants to perform data analysis, generate statistics, create summaries, pivot tables,
  SQL queries, or any form of structured data exploration. Supports multi-sheet Excel
  workbooks, aggregation, filtering, joins, and exporting results to CSV/JSON/Markdown.
---
```

技能正文教模型用 DuckDB 三步走：`inspect` 看结构 → `query`/`summary` 分析 → 导出
（`skills/public/data-analysis/SKILL.md:46`）：

```bash
python /mnt/skills/public/data-analysis/scripts/analyze.py \
  --files /mnt/user-data/uploads/data.xlsx \
  --action inspect
```

注意技能的注释约定："Do NOT read the Python file, just call it with the parameters"
——技能脚本是模型调用的黑盒 CLI，错误走 stderr、退出码非零。

**构件三：`chart-visualization` 技能**。`skills/public/chart-visualization/SKILL.md:1`：

```markdown
---
name: chart-visualization
description: This skill should be used when the user wants to visualize data. It
  intelligently selects the most suitable chart type from 26 available options, extracts
  parameters based on detailed specifications, and generates a chart image using a
  JavaScript script.
compatibility:
  nodejs: ">=18.0.0"
---
```

它前置声明了 `compatibility.nodejs`——技能可以带环境兼容位，frontmatter 是机器可读的。
生成走 Node 脚本（`SKILL.md:58`）：`node ./scripts/generate.js '<payload_json>'`，图片
URL 打在 stdout，失败写 stderr 且退出码为 1（`SKILL.md:63` 的 Result Return 约定）。

### 17.3.2 产物管道：`tool_artifacts`

工具结果里的文件引用要跨上下文压缩存活，靠的是工具产物句柄注册表
（`config.example.yaml:1462`）：

```yaml
tool_artifacts:
  enabled: true
  # Maximum artifact entries retained per thread (a sliding window: the
  # oldest entries are evicted when the cap is exceeded).
  max_entries: 100
  # Conservatively scan free-text tool results for sandbox paths / remote file URLs.
  detect_refs_in_text: true
  # Project available artifact handles into the model request as durable context.
  inject_model_context: true
  # Resolve artifact handles found in tool arguments to real references before execution.
  resolve_handles_in_args: true
```

机制（`config.example.yaml:1456` 的段注释）：工具结果中的路径/URL 被捕获进线程持久状态
`ThreadState.tool_artifacts`，模型用短句柄（`art_xxxxxxxx`）引用它们，句柄在工具执行前
被还原成真实引用，并在 UI 里渲染成徽标。这样即使摘要中间件压缩掉了早期消息，"我刚才
导出的那个 CSV"仍然可解析。

### 17.3.3 动手实验：完整跑通数据分析平台（可操作步骤）

前置：已完成第 2 章三步（`make config && make install && make dev`）。

**步骤 1：确认沙箱与工具组**。检查 `config.yaml` 中 `tool_groups` 含 `bash` 与
`file:read`/`file:write`（模板默认有，`config.example.yaml:836`）；生产/演示建议把沙箱
切到 Docker 模式（`sandbox:` 段，第 8 章 8.5），确认 Docker 可用。

**步骤 2：确认两个技能已启用**。技能发现是懒加载的；`skills.public` 下的
`data-analysis` 与 `chart-visualization` 默认随仓库提供。若你把技能目录指到了别处
（`config.example.yaml:2173` 的 `skills.path`），确认这两个目录仍在内。可在会话里输入
`/` 看技能斜杠命令，或直接让模型分析文件来触发。

**步骤 3：确认产物注册表开启**。`config.yaml` 里 `tool_artifacts.enabled: true`
（模板默认值，`config.example.yaml:1463`）。

**步骤 4：跑一次端到端**。打开 `http://localhost:2026`，新建会话，上传一个 Excel
（没有就 `pip install openpyxl` 造一个两列的销售表），输入：

> 分析上传的销售数据：先看结构，然后统计每个品类的销售额，最后画一张柱状图。

观察三个可验证现象：
1. 模型先调用 `inspect`（终端 `logs/gateway.log` 里可见 bash 工具执行
   `analyze.py --action inspect`）；
2. 产物文件出现在对话的 artifacts 区，带 `art_` 句柄徽标（`tool_artifacts` 生效）；
3. 图表 URL 由 `generate.js` 输出并渲染（退出码 0 才呈现 URL——技能约定）。

**步骤 5：追加一个追问，验证句柄存活**：开启较长对话后让它"把之前导出的 CSV 再按月
透视"。若句柄解析正常（`resolve_handles_in_args: true`），即使早期消息已被摘要压缩，
`analyze.py` 仍拿到正确路径。

**步骤 6：沉淀为业务模板**。把三样东西打包成团队模板（配置 + 技能 + 扩展三件套中的
前两件即可，本场景无需扩展）：
- `config.yaml` 增量片段：`tool_groups`/`tools`/`tool_artifacts`/`sandbox`；
- 可选的领域技能：复制 `skills/public/data-analysis/` 到 `skills/custom/<你的域>/`，
  改 frontmatter 的 `name`/`description`（触发词要写清业务文件类型），脚本按需替换；
- 一份 README 说明上传格式约定。

## 17.4 实战 C：深度研报自动化

**需求**：每天早上 9 点自动产出一份带来源核验的行业研报，推送到飞书群。

**分流**：研报方法论 = Skill（`deep-research` 已有）；规模化 = 子代理批处理（核心已有，
配置开启）；可信度 = verification 凭证（核心已有）；定时 = scheduler（核心已有，配置
开启）。配置 + 一个现成技能的组合，唯一可能的新增是投放渠道（IM，见实战 D）。

### 17.4.1 研究方法论：deep-research 技能

`skills/public/deep-research/SKILL.md:1`：

```markdown
---
name: deep-research
description: Use this skill instead of WebSearch for ANY question requiring web
  research. Trigger on queries like "what is X", "explain X", "compare X and Y",
  "research X", or before content generation tasks. ...
---
```

正文的核心纪律（`SKILL.md:31`）："**Never generate content based solely on general
knowledge.**" 四阶段方法论：Broad Exploration → Deep Dive → Diversity & Validation →
Synthesis Check，并强制检查 `<current_date>` 做时间敏感检索（`SKILL.md:135`）。它不引入
任何新工具——全靠既有 `web_search`/`web_fetch`，所以它是"纯提示词工程也是一等功能"
的最好例证。

### 17.4.2 规模化：子代理运行时与批处理

子代理并发容量是进程级配置（`config.example.yaml:2011`）：

```yaml
subagent_runtime:
  max_running: 3
  max_queued: 64
  admission_policy: queue       # queue or reject when all slots are occupied
  queue_timeout_seconds: 300
```

要让一次研报委派几十个检索任务，开启持久批处理（`config.example.yaml:2102`）：

```yaml
subagent_batches:
  enabled: false
  poll_interval_seconds: 1
  lease_seconds: 120
  max_items_per_batch: 5000
  default_max_live_items: 100
  max_live_items_per_batch: 1000
  default_max_running_items: 3
  max_running_items_per_batch: 64
  max_attempts: 3
  max_result_chars: 100000
  result_preview_max_chars: 2000
```

段注释（`config.example.yaml:2096`）点明两件事：默认关闭是因为"enabling it can
materially increase model usage"，且需要 `database.backend` 为 sqlite/postgres；三个
限额（total / live / running）刻意分开——持久项、同时排队项、真正占执行槽项是三个
不同的水位。若要给研报子代理单独配模型/技能白名单，用 `subagents.agents` 的 per-agent
覆盖（`config.example.yaml:2049`，`general-purpose.timeout_seconds: 2700` 的示例）或
`custom_agents` 定义专属研究员（`config.example.yaml:2069`，`skills:` 白名单写
`data-analysis` 那种格式）。

### 17.4.3 可信度：verification 凭证

`config.example.yaml:2122`：

```yaml
verification:
  receipts_enabled: true
  # Lead-chain ledger rendering: 'delegation_only' renders only while
  # processing subagent results (subagent chains always render).
  receipts_render_mode: "delegation_only"
  judge_enabled: false
  judge_model_name: null
```

`receipts_enabled: true` 给每个工具结果盖上确定性凭证并注入模型上下文，最终研报可以
引用"确实执行过的动作"（`config.example.yaml:2118` 的段注释）。选择性评审
（`judge_enabled`）留给验收标准审查，默认关闭。

### 17.4.4 定时与推送

定时任务三件配置（`config.example.yaml:2895`）：

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

`enabled` 是后台轮询总闸；`tool_enabled` 通过 Gateway 能力准入把排程工具开放给对话
（根 `AGENTS.md` 的 scheduled-task note：互动轮创建/管理计划，计划轮只能停自己的计划）。
计划轮是**非交互**的——`ask_clarification` 被排除，所以研报提示词里不能依赖追问，必须
把"检索不足时的降级策略"写进任务目标。

推送走 IM 通知 worker：当 `channel_connections.enabled` 且渠道在运行时，scheduler 的
`poll_interval_seconds` 同时驱动通知投递（`config.example.yaml:2873`），每次运行结束/
失败/未达目标最多一条消息，且**目前仅 WeCom 支持主动推送**——飞书侧的"推送到群"要用
实战 D 的渠道接入 + 群绑定实现，计划通知本身不会自动进飞书群，规划时别把两者混为一谈。

### 17.4.5 组装清单

1. `config.yaml`：`scheduler.enabled: true` + `scheduler.tool_enabled: true`；
   视成本预算开 `subagent_batches.enabled`（先评估模型用量）；
2. 保持 `verification.receipts_enabled: true`；
3. 在 `/workspace/scheduled-tasks` 页面创建计划：cron 每日 09:00，任务目标写清
   "用 deep-research 方法论产出《XX 行业日报》，含来源链接与凭证引用，无澄清降级策略"；
4. 从 IM 渠道（实战 D）绑定接收群；或用 Web 会话先手动试跑一次（手动 run now 不发
   通知，`config.example.yaml:2881`）。

## 17.5 实战 D：IM 智能客服

**需求**：客户在飞书/Telegram 里咨询，机器人以公司客服知识回答，支持文件收发与选项
澄清，且每个外部用户的数据归属正确。

**分流**：渠道接入是核心能力（`app/channels/` 已有六个平台 + GitHub webhooks + 用户
连接层）；客服领域知识是 Skill；若要工单系统对接则补一条 MCP。扩展仅在你需要自定义
渠道或深度改造路由时才上场。

### 17.5.1 渠道架构速读

`backend/app/channels/AGENTS.md:22` 的组件表是理解数据流的地图：

- `message_bus.py`：入站队列 → 分发器；出站走 dispatch-start 时的监听器快照；
- `manager.py`：核心分发器——经 `client.threads.create()` 建线程、路由 `/new` `/goal`
  `/agent` `/model` 等命令；Slack/Discord 用 `runs.wait()`，飞书/Telegram 用
  `runs.stream()` 增量编辑消息（`AGENTS.md:46`–`AGENTS.md:47` 的 Message Flow）；
- `base.py`：渠道生命周期抽象（start/stop/send），SDK 回调必须用
  `_submit_threadsafe_coroutine()` 跨线程投递；
- `store.py`：`channel_name:chat_id[:topic_id] → thread_id` 绑定存储（SQL/JSON 双实现，
  多副本共享绑定用 SQL）。

**owner 归属与文件存储**是客服场景的安全底座（`backend/app/channels/AGENTS.md:58`）：

> **Owner-scoped file storage**: inbound files, uploads, and output artifacts are staged
> under the DeerFlow owner's bucket so they land where the agent run reads/writes
> (`users/{user_id}/threads/{thread_id}/user-data/{uploads,outputs}`).

入站消息携带 `connection_id` 与 `owner_user_id`（`AGENTS.md:43`），后者成为 run 的
`user_id`——客户的文件永远落在**绑定的企业用户**名下，而不是某个匿名桶。记忆个性化也
因此天然按 owner 隔离（第 10 章）。

### 17.5.2 配置面：渠道 + 交互卡片

`config.example.yaml:3170`：

```yaml
#   feishu:
#     enabled: false
#     app_id: $FEISHU_APP_ID
#     app_secret: $FEISHU_APP_SECRET
#     # domain: https://open.feishu.cn       # China (default)
#     # domain: https://open.larksuite.com   # International
#     # card_interaction_enabled: false      # render option clarifications as clickable button
#                                            # cards; requires subscribing card.action.trigger
#                                            # under the console's callback-configuration tab
#                                            # (separate from event subscriptions) and
#                                            # publishing a new app version
```

`card_interaction_enabled` 打开后，`ask_clarification` 的选项澄清会渲染成**可点击按钮
卡片**——客服场景的关键体验（客户点"退货政策"而不是打字）。代码开关在
`backend/app/channels/feishu.py:195`：

```python
self._card_interaction_enabled = bool(config.get("card_interaction_enabled", False))
```

启用它有平台侧前置条件（`config.example.yaml:3176` 注释）：在飞书开放平台控制台的
**回调配置**页订阅 `card.action.trigger`（与事件订阅是两回事），并发布新版应用。卡片
交互的消费在 `feishu_card_interaction.py` 中按"来源者/选项校验 + 一次性消费"处理
（`backend/app/channels/AGENTS.md:49`：Originator/option checks consume once；跨
worker 消费 fail closed）。

**用户连接层**让企业员工自助绑定（`config.example.yaml:3063`）：

```yaml
# channel_connections:
#   enabled: false
#   # Security: keep this enabled unless you intentionally want legacy open-bot behavior.
#   # Disabling it lets unbound external IM users create DeerFlow threads/runs.
#   require_bound_identity: true
```

注释里的安全警告值得原样贴进运维手册：关掉 `require_bound_identity` 等于退回开放 bot
行为——任何未绑定的外部用户都能创建 DeerFlow 线程和 run。客服机器人若面向外部客户，
保持 `true` 并走 `/connect <code>` 绑定流（`AGENTS.md:75`：Telegram 深链 `/start <code>`，
其余平台 `/connect <code>`；绑定码 `secrets.token_urlsafe(16)`、600 秒 TTL、一次性）。

### 17.5.3 落地清单

1. `config.yaml → channels.feishu`：填 `app_id`/`app_secret`，按需开
   `card_interaction_enabled`（先在控制台完成卡片回调订阅）；
2. `channel_connections.enabled: true`、`require_bound_identity: true`；
3. 客服知识放 `skills/custom/support-kb/`（实战 A 的知识检索亦可并入）；
4. 记忆开启（第 10 章），客户偏好按 owner 隔离沉淀；
5. 验证：绑定一个测试用户 → 发"退货政策是什么" → 观察澄清卡片 → 上传一张发票图片 →
   确认文件落在绑定 owner 的 `uploads/` 目录而非默认桶。

## 17.6 实战 E：自定义模型供应商

**需求**：企业有私有模型网关（vLLM / MindIE / LiteLLM / 一方云兼容端点），要接进
DeerFlow，且深度思考、视觉、上下文窗口指示都表现正确。

**分流**：纯配置。DeerFlow 的模型抽象是"LangChain 类路径 + 能力位"——
`create_chat_model()` 按 `use:` 指到的类构造客户端，任何 LangChain `BaseChatModel`
子类都能接入。

### 17.6.1 工厂走读

入口在 `backend/packages/harness/deerflow/models/factory.py:540`：

```python
def create_chat_model(name: str | None = None, thinking_enabled: bool = False, *,
                      app_config: AppConfig | None = None, attach_tracing: bool = True,
                      model_overrides: dict | None = None, **kwargs) -> BaseChatModel:
```

关键流程（读 `factory.py:568`–`factory.py:574`）：

```python
    config = app_config or get_app_config()
    if name is None:
        name = config.models[0].name
    model_config = config.get_model_config(name)
    if model_config is None:
        raise ValueError(f"Model {name} not found in config") from None
    model_class = resolve_class(model_config.use, BaseChatModel)
    model_settings_from_config = model_config.model_dump(exclude_none=True, exclude=set(_MODEL_METADATA_FIELDS))
```

两个设计点：

1. **`resolve_class(model_config.use, BaseChatModel)`**（`backend/packages/harness/deerflow/reflection/resolvers.py:103`）
   把 `use:` 字符串解析成类并校验基类——这就是"接任意 LangChain 模型类"的机制；
2. **`_MODEL_METADATA_FIELDS`**（`factory.py:19`–`factory.py:44`）把描述性字段
   （`use/name/display_name/aliases/supports_thinking/supports_vision/context_window/
   pricing/reasoning/...`）在进构造器之前剥掉——这些是 DeerFlow 的能力位与 UI 元数据，
   不是 provider 参数，混进去会被 OpenAI SDK 在请求期以"unexpected keyword argument"
   报错（`factory.py:349` 的 `_warn_unknown_model_settings` 会在构建期提前告警）。

### 17.6.2 能力位配置样例

最小可用条目（`config.example.yaml:302`）：

```yaml
  # Example: OpenAI model
  # - name: gpt-4
  #   display_name: GPT-4
  #   use: langchain_openai:ChatOpenAI
  #   model: gpt-4
  #   api_key: $OPENAI_API_KEY # Use environment variable
  #   max_tokens: 4096          # Per-call output cap
  #   context_window: 128000    # Total prompt + completion capacity
  #   temperature: 0.7
  #   supports_vision: true # Enable vision support for view_image tool
```

私有网关 + 必思考模型的完整示例（`config.example.yaml:266`，Z.AI GLM-5.3-Flash）：

```yaml
  # - name: glm-5.3-flash
  #   display_name: GLM-5.3-Flash
  #   use: deerflow.models.patched_deepseek:PatchedChatDeepSeek
  #   model: glm-5.3-flash
  #   api_base: https://api.z.ai/api/paas/v4
  #   api_key: $ZAI_API_KEY
  #   ...（省略 timeout / max_retries / temperature / top_p / max_tokens / stream_usage 数行）
  #   context_window: 1000000
  #   supports_vision: true
  #   reasoning:
  #     thinking: required
  #     dialect: openai_extra_body
  #     history: clear
  #     effort:
  #       values: [low, high, max]
  #       default: high
  #       aliases:
  #         minimal: low
  #         medium: high
```

各字段语义：

- **`use:`** 选客户端类。OpenAI 兼容网关通常用
  `deerflow.models.patched_deepseek:PatchedChatDeepSeek`（保留 reasoning_content）或
  `langchain_openai:ChatOpenAI`；**Ollama 必须用 `langchain_ollama:ChatOllama`**
  （`config.example.yaml:336`：OpenAI 兼容端点不返回独立 reasoning_content，思考内容
  会被压扁或丢弃）；DeerFlow 还内置 `vllm_provider.py`、`mindie_provider.py`、
  `openai_codex_provider.py` 等（`backend/packages/harness/deerflow/models/` 目录）；
- **`context_window`**：提示 + 回复总容量，驱动 UI 的"已用上下文 %"，并让基于比例的
  摘要触发器能取到阈值（`config.example.yaml:135`；`factory.py:730` 会把它翻译成
  LangChain profile 的 `max_input_tokens`）；
- **`supports_vision`**：开启 `view_image` 工具的可用性（`config.example.yaml:313`）;
- **`supports_thinking` / `reasoning:` 契约**：声明思考开关是否存在、思考是否强制、
  effort 词表与别名。`required` 思考的模型永远不会收到关闭载荷；`default: high` 让
  标题/摘要这类后台调用也别落到最深的思考档（`config.example.yaml:272` 的注释）；
- **`api_base` vs `base_url`**：工厂会把 OpenAI 兼容类上的 `api_base` 别名归一化成
  `base_url`（`factory.py:318`），但 `langchain_deepseek` 这类自己声明 `api_base`
  字段的类除外——拷贝配置时留意注释。

### 17.6.3 验证

```bash
# 配置写好后重启 Gateway，然后：
curl -s http://localhost:2026/api/models | head   # 新模型应出现在目录里
```

再到 Web 界面：模型选择器出现新条目 → 发消息看流式输出 → 让它"看这张图"验证
`supports_vision` → 长对话验证 `context_window` 指示器 → 若配了 `reasoning:` 契约，
在 UI 里切 effort 档位观察请求载荷（`logs/gateway.log` 或 tracing）。

## 17.7 常见坑

1. **把所有需求都做成扩展**。能不能一句话说清"它钩哪个贡献点"？说不清就先考虑
   Skill/MCP/配置。扩展的维护成本（快照升级、重启、契约版本）比配置高一个量级。
2. **知识库只开 `knowledge_base.enabled` 就以为能用**。开关只是能力位，真正把工具挂进
   模型的是 `tools:` 里的 `knowledge_search` 条目（或已注册的知识提供者扩展）；两者缺一
   不可，且 `scope_selection_enabled` 只在 provider 支持 `catalog`+`dataset_filter` 时
   才会真正显示选择器。
3. **数据分析平台忘了沙箱模式**。本地 `LocalSandboxProvider` 是开发直执行，生产必须
   Docker 隔离（第 8 章）；技能脚本路径 `/mnt/skills/...` 在沙箱里的映射由
   `skills.container_path` 控制（`config.example.yaml:2191`），改了它要重启 Gateway。
4. **计划轮里写"如果信息不足请问我"**。计划轮非交互，`ask_clarification` 被排除，
   `non_interactive`/`disable_clarification`/`github_token` 只对内部认证调用方生效
   （run-context 信任边界）——研报任务必须自带降级策略。
5. **飞书卡片开了开关却收不到按钮点击**。`card_interaction_enabled` 需要控制台**回调
   配置**页订阅 `card.action.trigger` 并发布新版本；它和"事件订阅"是两个独立开关
   （`config.example.yaml:3176`–`config.example.yaml:3180`）。
6. **模型配置键敲错**。`ModelConfig` 是 extra=allow 的，`maxx_tokens` 这类笔误不会在
   加载期报错，而是被 LangChain 转进 `model_kwargs` 在**请求期**炸出难排查的错误；
   工厂在构建期会打告警（`factory.py:349` 的 `_warn_unknown_model_settings`），看日志
   第一行就能定位。同理，描述性字段（`context_window`、`supports_vision`…）不是
   provider 参数，会被工厂剥掉，不要指望它们透传。

---

## 下一步

五个实战覆盖了决策树的全部分支：配置（B/C/E）、Skill（C 的方法论）、扩展与契约（A）、
核心能力组合（D）。当业务需要自定义界面——新的产物预览卡片、新的 workspace 页面、
渠道管理面板——就该把镜头转向前端了。请继续阅读第 18 章《前端二次开发》（Next.js
App Router、`core/` 业务域与流式数据流，见 `frontend/AGENTS.md`；章节文件见教程目录
索引）。
