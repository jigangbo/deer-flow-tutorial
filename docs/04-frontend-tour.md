# 第 4 章 前端界面与基本功能导览

## 4.0 学习目标

读完本章，你应该能够：

1. 说清 `/workspace` 下每个页面的用途与入口：会话页、自定义 Agent 页、能力中心、
   定时任务页、用量页、项目/回收站；
2. 熟练使用会话页的用户可见功能：上传、artifacts 面板、todos、`/goal`、`@` 技能引用、
   归档与未读标记；
3. 区分普通用户与管理员可见的界面（模型管理、用户管理、技能诊断）；
4. 知道双语用户手册（`frontend/src/content/{en,zh}/`）在哪里、怎么被渲染成 `/docs` 页面。

> 本章只讲**页面与用户可见功能**，不深入前端代码实现——组件、数据流与二次开发留给第 18 章。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 路由结构 | `frontend/src/app/`（本章节按目录逐个对应） |
| 页面/域职责速查 | `frontend/AGENTS.md:64`（scheduled-tasks）、`frontend/AGENTS.md:321`（capabilities） |
| 前端总体介绍 | `docs/ARCHITECTURE.md:117`（Source Layout） |
| 用户手册内容 | `frontend/src/content/en/`、`frontend/src/content/zh/` |
| 静态演示构建 | `frontend/AGENTS.md:215`（`make build-static`） |

---

## 4.1 会话页 `/workspace/chats/[thread_id]`

会话页是整个产品的主战场。所有功能围绕"一个 thread = 一次可隔离的对话"展开。

### 消息区

- **流式回复**：模型输出逐块渲染；支持思考内容的独立展示（取决于模型能力位）；
- **子任务卡片**：Agent 委派子代理时，进度通过根命名空间的 `task_*` 事件驱动卡片展示
  （`docs/ARCHITECTURE.md:131`——"Subtask progress rides root-namespace `task_*` custom
  events"）；
- **引用与证据**：知识检索的 ToolMessage 会被解析为可展开的来源面板与
  `#knowledge-source-ID` 引用链接（`frontend/AGENTS.md:95`）；
- **历史事件线**：定时任务触发的会话会显示任务生命周期事件行（创建/启动/完成），
  按 `after_run_id` 插入对应轮次末尾（`frontend/AGENTS.md:77`）。

### 输入区（Composer）

- **上传**：拖拽或点击上传，走 `POST /api/threads/{thread_id}/uploads`（第 2 章已演示）；
- **斜杠命令**：`/` 面板只有两个——`/goal`（设定完成条件）与 `/compact`（手动压缩上下文）
  （`frontend/AGENTS.md:439`）；旧版纯文本斜杠输入依然兼容；
- **`@` 技能引用**：`@` 唤起技能选择器，选中的技能以 `additional_kwargs.skill_references`
  随消息提交（最多 16 个），后端校验技能对当前用户与 Agent 的可用性
  （`frontend/AGENTS.md:437`）；`@` 与附件按钮共用同一个选择器；
- **模型控件**：模型选择、思考模式与推理力度档位都在输入区卡片上
  （`core/models/use-model-control` + HumanInputCard，`frontend/AGENTS.md:93`）；
  必须思考的模型不提供"关闭"档（`frontend/AGENTS.md:406` 的 reasoning 契约）。

### 右侧/侧栏 artifacts 面板

Agent 在沙箱中写出的文件会作为 artifacts 展示：代码、Markdown、图片、CSV/TSV 表格预览
（分页、最多 202 行的逻辑记录与 50 列，见 `frontend/AGENTS.md:282`）。artifacts 也有
独立查看页 `/artifacts/view`（`frontend/src/app/artifacts/view/`）。

### todos 与 goal 卡片

- 打开 Plan Mode 后，Agent 用 `write_todos` 维护任务清单，会话页渲染实时更新的 todos
  卡片（`backend/AGENTS.md:296`）；
- `/goal` 设置的完成条件属于**当前线程**；运行结束后系统评估目标是否满足并展示状态
  （`docs/ARCHITECTURE.md:112`）。

### 会话管理

- **归档**：归档是线程元数据标志（`deerflow_archived === true`），与运行状态无关；侧栏与
  Chats 列表可按归档过滤（`frontend/AGENTS.md:268`）；
- **未读与来源图标**：服务端创建的线程（IM/定时任务发起）在列表行显示来源图标与未读圆点
  （`frontend/AGENTS.md:78`）；
- **删除**：删除经确认对话框执行，先远端后本地清理，远端 404 视为已删除
  （`frontend/AGENTS.md:299`）。

---

## 4.2 自定义 Agent 页 `/workspace/agents/[agent_name]`

入口：工作区侧栏 Agents 区；新建走 `/workspace/agents/new`。一个自定义 Agent 可以绑定
专属模型、系统提示、工具访问与知识范围：

- **工具访问**：从 `GET /api/agent-tool-groups` 返回的目录中勾选，保存的是
  `null` / `[]` / 显式列表三种契约——继承全部 / 全部禁用 / 白名单
  （`frontend/AGENTS.md:147`）；
- **知识范围**：当工具白名单不再包含 `knowledge` 时，同一请求会把 `knowledge_scope`
  置空，避免遗留的检索默认值导致 run 被拒（`frontend/AGENTS.md:153`）；
- **显示名**：`display_name` 是可选的 Unicode 界面标签（上限 100 码点），运行时身份仍用
  `name`（`frontend/AGENTS.md:141`）；
- **可移植性**：Agent 可导出/导入版本化的 `deerflow.custom-agent` JSON 文档；
  导入预览只在浏览器端解析文件名，校验以 Gateway 为准（`frontend/AGENTS.md:159`）。

自定义 Agent 创建后，会话页模型选择器与 `/workspace/agents/[agent_name]` 顶栏都可以
以该 Agent 身份发起对话。

---

## 4.3 公开演示页 `/showcase/[thread_id]`

`/showcase/[thread_id]` 是**allowlist 只读**演示页（`docs/ARCHITECTURE.md:120`）：
把某个 thread 加入允许列表后，访客无需账号即可只读回放该对话——适合对外展示 Demo。
它复用与会话页相同的渲染组件，但没有输入区，也没有任何写操作。

与之同族的还有一个纯静态只读变体：`make build-static` 产出 standalone 静态演示站，
Gateway 读取由打包进站内的 `/mock/api` fixtures 提供，写操作本地直接失败
（`frontend/AGENTS.md:215`）。

---

## 4.4 定时任务页 `/workspace/scheduled-tasks`

前置条件：`config.yaml` 中 `scheduler.enabled: true`（重启 Gateway 生效），
且你的账号具备相应能力准入（`scheduler.tool_enabled` 只影响会话内工具）。页面结构
（`frontend/AGENTS.md:64`）：

- **列表**：带状态 Tab（进行中/已暂停等）、按标题或提示词搜索、可叠加类型过滤；
- **详情**：Runs（运行历史）/ 何时运行 / goal / 做什么 / 备注 / History 六块信息；
- **创建/编辑/复制对话框**：支持一次性（once）、cron、间隔（interval）三种计划；
  编辑只提交变更字段，`null` 表示清除；
- **续期对话框**：一次性任务或次数耗尽（`limits_exhausted`）时恢复任务会要求续期
  上限（`max_runs`/`end_at`）；
- **URL 参数**：`?task_id=` 直达某个任务；`?thread_id=` 把列表限定到某个会话
  （`frontend/AGENTS.md:64`）。

运行历史语义值得记住：`unmet` 状态表示"这次运行完成了，但计划目标没达成"，
它**不是**执行失败（`frontend/AGENTS.md:61`）；三次未达标会自动暂停任务。
聊天里的 `schedule_task` 工具结果会渲染成定时任务卡片（轮询仅在卡片可见时进行，
`frontend/AGENTS.md:76`）。

---

## 4.5 其他工作区页面速览

以下页面按 `frontend/src/app/workspace/` 实际目录列出：

| 路由 | 用途 |
| --- | --- |
| `/workspace`（`page.tsx`） | 工作区首页，重定向/汇总视图 |
| `/workspace/chats` | 会话列表 |
| `/workspace/agents`、`/agents/new` | 自定义 Agent 管理与新建（见 4.2） |
| `/workspace/capabilities` | **能力中心**：Plugins（MCP）与 Skills 两个导航（`frontend/AGENTS.md:321`）；MCP 管理器、集成配置对话框都在这里 |
| `/workspace/extensions/[namespace]` | 全栈插件页面挂载点 |
| `/workspace/projects`、`/projects/[id]` | 项目：文档架（document shelf）、归档读取语义（`README.md:3746` 起） |
| `/workspace/scheduled-tasks` | 定时任务（见 4.4） |
| `/workspace/trash` | 回收站 |
| `/workspace/usage` | Token 用量控制台：按 owner/周期/时区查询，门禁在 `runs:read` 权限（`frontend/AGENTS.md:84`） |

**管理员可见**（普通用户不显示入口）：

- 设置 → Models（`?settings=models`）：经 `/api/managed-models` 的目录管理；YAML 里的
  条目只读，草稿凭据不落浏览器存储（`frontend/AGENTS.md:370`）；
- 设置 → Users（`?settings=users`）：账号停用/恢复，经 `/api/v1/admin/users`
  （`frontend/AGENTS.md:379`）；
- 技能诊断（`skill-diagnostics`）：仅管理员、非静态演示站可见（`frontend/AGENTS.md:311`）。

---

## 4.6 国际化与双语用户手册

### 界面语言

界面支持 `zh-CN` 与 `en-US` 双语（`docs/ARCHITECTURE.md:124` 的 `core/i18n/`）。
语言偏好会作为 `locale` 用户偏好保存，并影响后续定时任务通知的语言
（`frontend/AGENTS.md:77`：UI 语言每会话保存一次）。

### MDX 用户手册

`frontend/src/content/{en,zh}/` 下是完整的双语手册源文件，目录对称：

```text
frontend/src/content/en/
├── _meta.ts
├── application/
├── harness/
├── index.mdx
├── introduction/
├── posts/
├── reference/
└── tutorials/
```

（`zh/` 结构完全一致。）它们经 `/[lang]/docs/[[...mdxPath]]` 路由渲染成站内文档页
（`frontend/src/app/[lang]/docs/`），构建时 `scripts/build-search-index.mjs` 会生成
`public/_pagefind/` 搜索索引，页面头部提供全文搜索
（`frontend/AGENTS.md:253`）。

**阅读建议**：`harness/` 与 `application/` 两个分区对应"平台运维/使用者"两种视角，
与本教程第 12 章（定时任务与 IM）、第 16 章（扩展）的官方对照文档都在其中；查功能时
先搜手册，再回到 `backend/docs/` 查机制。

---

## 动手实验 4-1：十分钟页面巡检

保持 `make dev` 运行，用浏览器依次访问并记录（无需任何代码修改）：

1. `http://localhost:2026/workspace` —— 新建一个会话，发一条消息，观察流式渲染与
   自动标题；
2. 输入 `/` —— 确认斜杠面板只有 `/goal` 与 `/compact`；输入 `@` —— 确认技能选择器
   能列出 `skills/public/` 下的技能（如 `deep-research`）；
3. 上传一个小 CSV 并让 Agent "统计每列的平均值并生成图表" —— 观察 artifacts 面板
   的表格/图片预览；
4. 访问 `/workspace/agents/new` —— 走一遍新建自定义 Agent 的表单（模型、工具访问、
   显示名），保存后用它发起一次对话；
5. 访问 `/workspace/capabilities` —— 确认 Plugins/Skills 两个导航；在 Skills 页
   看到公共技能列表；
6. 访问 `/workspace/usage` —— 查看刚才几轮对话的 token 用量；
7. 切换界面语言（右下角/设置中）—— 确认 `zh-CN` 与 `en-US` 切换即时生效，然后访问
   `/zh/docs` 与 `/en/docs`，确认双语手册渲染正常；
8. （若已开启 scheduler）访问 `/workspace/scheduled-tasks` —— 确认状态 Tab 与
   新建对话框可用；未开启 scheduler 时记录页面提示。

预期产出：一张"页面 × 功能 × 你看到的状态"对照表；任何与本章描述不符的地方，
先检查 `config.yaml` 对应开关，再查官方手册。

---

## 常见坑

1. **找不到某功能入口就怀疑版本**：管理员功能（模型/用户管理、技能诊断）对普通用户
   隐藏；先确认账号角色，再看 `?settings=` 深链。
2. **在 `showcase` 里想输入**：演示页是只读回放（allowlist 控制），没有输入区；
   要互动请登录后进 `/workspace`。
3. **`@` 引用的技能带不动**：技能引用会经后端按用户注册表与 Agent 白名单双重校验
   （`frontend/AGENTS.md:437`）；自定义 Agent 的工具白名单可能排除了它。
4. **定时任务页空白**：`scheduler.enabled: false` 时页面没有数据且创建会报
   `409 scheduler_not_running`（`backend/docs/CONFIGURATION.md:766`）；先开总闸并重启。
5. **语言切换不保存**：`locale` 偏好只在 Gateway 偏好服务可用时保存
   （`frontend/AGENTS.md:77`）；静态演示站或后端不可达时切换仅当次有效。
6. **文档搜索无结果**：搜索索引在 `pnpm build` 时生成（`frontend/AGENTS.md:254`）；
   dev 模式或未跑过构建时站内搜索可能为空。
7. **把 `ui/`、`ai-elements/` 当普通组件改样式**：它们是注册表生成物，改动会被覆盖；
   定制入口在 `components/workspace/` 等自有目录（第 18 章展开）。

---

## 下一步

界面已经走遍，但你现在只能在"本机前台"跑 DeerFlow。下一章《第 5 章 更多运行方式》覆盖
本地生产模式、守护进程、Docker 开发/生产栈与 Helm 部署，并给出四种模式的对比表——见
`05-run-modes.md`。
