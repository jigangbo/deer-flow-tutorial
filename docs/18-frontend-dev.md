# 第 18 章 前端二次开发

> **本章源码锚点**
>
> | 锚点 | 作用 |
> | --- | --- |
> | `frontend/package.json:6` | scripts 全表与依赖版本（Next 16 / React 19 / Tailwind v4 / langgraph-sdk） |
> | `frontend/AGENTS.md:9` | 技术栈官方口径（版本、Node/pnpm 要求） |
> | `frontend/src/core/threads/hooks.ts:2180` | `useStream` 流式订阅入口 |
> | `frontend/src/core/threads/stream-state.ts:26` | `RENDERED_THREAD_STATE_KEYS` 状态归一化白名单 |
> | `frontend/src/core/api/api-client.ts:20` | LangGraph SDK 客户端单例与 CSRF 注入 |
> | `frontend/components.json:21` | Shadcn / MagicUI / React Bits / AI SDK 注册表来源 |
> | `frontend/src/app/workspace/scheduled-tasks/page.tsx:51` | "新增 workspace 页面"的官方范例 |
> | `frontend/rstest.config.ts:22` | node / happy-dom 双测试项目切分 |

## 18.0 学习目标

读完本章，你应该能够：

1. 说出前端的三层结构（`app/` 路由、`core/` 业务域、`components/` 组件）各自承担什么职责，以及为什么业务逻辑要收敛在 `core/` 而不是散落在组件里。
2. 完整描述一次流式回复的数据流：LangGraph SDK `useStream` → SSE 归一化 → TanStack Query 状态 → 组件渲染，并知道子代理进度为什么走根命名空间的 `task_*` 事件。
3. 识别 `ui/` 与 `ai-elements/` 这两个"注册表生成物"目录的红线：不能手改，改了会在下次同步时被覆盖。
4. 参照 `/workspace/scheduled-tasks` 的实现模式，独立新增一个 workspace 页面（路由 + 纯函数域 + 组件族 + 测试）。
5. 熟练使用 `pnpm dev` / `pnpm check` / `pnpm rstest run` / `pnpm test:e2e` 完成一次前端变更的完整工程闭环。

---

## 18.1 技术栈与结构

### 18.1.1 版本基线（先对齐认知）

`frontend/AGENTS.md:9` 给出的官方栈口径与 `frontend/package.json` 的实际依赖一致：

- **Next.js 16**（`frontend/package.json:80`，`"next": "^16.4.1"`）——注意这是比多数教程资料更新的版本，`frontend/AGENTS.md:359-367` 甚至专门警告"This is NOT the Next.js you know"，要求动手前先读 `node_modules/next/dist/docs/`。
- **React 19**（`frontend/package.json:88-89`，`react` / `react-dom` `^19.0.0`）。
- **Tailwind CSS v4**（`frontend/package.json:125`，`tailwindcss: ^4.0.15`，PostCSS 插件方式接入）。
- **LangGraph SDK**（`frontend/package.json:33-34`，`@langchain/langgraph-sdk: ^1.5.3`、`@langchain/core: ^1.1.15`）——前端不自己管理 Agent 循环，一切状态来自 SDK 对后端 run 流的订阅。
- **TanStack Query**（`frontend/package.json:56`，`@tanstack/react-query: ^5.90.17`）——服务端状态的唯一管理者。
- **pnpm 10.26.2**（`frontend/package.json:133`，`"packageManager": "pnpm@10.26.2"`），要求 Node.js 22+（`frontend/AGENTS.md:9`）。

```json
// frontend/package.json:80-89（节选）
    "next": "^16.4.1",
    "next-themes": "^0.4.6",
    "nextra": "^4.6.1",
    "nextra-theme-docs": "^4.6.1",
    "nuxt-og-image": "^5.1.13",
    "ogl": "^1.0.11",
    "papaparse": "5.7.0",
    "qrcode.react": "4.2.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
```

> 版本纪律：`frontend/package.json:1-3` 里的 `"version": "2.3.0-dev"` 参与全书版本锁步（见第 20 章 20.3），不要单独手改这个字段。

### 18.1.2 三层目录结构

`frontend/src/` 一层只有十来个条目，但重心在三个目录：

**`app/` —— App Router 路由层**。实际内容：`(auth)`（登录/初始化/回调）、`[lang]`（多语言文档站）、`api`（route handlers）、`artifacts`（独立产物查看器）、`blog`、`github-stars`、`mock`、`showcase`（allowlist 公开演示）、`workspace`（工作区）。核心会话页在 `app/workspace/chats/[thread_id]/`，自定义 Agent 会话页在 `app/workspace/agents/[agent_name]/chats/[thread_id]/page.tsx`。

**`core/` —— 业务域层（真正的心脏）**。按域切分了 40+ 个子目录：`threads`（创建/流式/状态）、`api`（SDK 客户端单例）、`agents`、`auth`、`artifacts`、`channels`、`citations`、`features`、`i18n`、`integrations`、`knowledge`、`mcp`、`memory`、`messages`、`models`、`projects`、`scheduled-tasks`、`settings`、`sidecar`、`skills`、`streamdown`、`subagent-batches`、`subagents`、`suggestions`、`tasks`、`threads`、`todos`、`tools`、`trash`、`uploads`、`usage`、`utils`、`workspace-changes` 等。**规则：业务状态与副作用写在 `core/`，组件只做渲染**。这也是单元测试的组织单位——`tests/unit/` 目录树按 `src/` 镜像摆放（`frontend/AGENTS.md:30`）。

**`components/` —— 展示层**。手写组件在 `workspace/`（聊天主界面）、`landing/`、`docs/`、`auth/`；而 `ui/`（约 40 个文件）与 `ai-elements/`（14 个文件）是**注册表生成物**，详见 18.3。

一个值得记住的心智模型来自 `frontend/AGENTS.md:112-116`：

```
Frontend (Next.js) ──▶ LangGraph SDK ──▶ LangGraph Backend (lead_agent)
                                              ├── Sub-Agents
                                              └── Tools & Skills
```

### 18.1.3 后端连接方式：默认走 Nginx

前端有两个可选环境变量（`frontend/AGENTS.md:206-213`）：

```
NEXT_PUBLIC_BACKEND_BASE_URL=http://localhost:8001
NEXT_PUBLIC_LANGGRAPH_BASE_URL=http://localhost:8001/api
```

但标准 `make dev` / Docker 流程下**两者都留空**：此时 LangGraph 请求打到同源的 `/api/langgraph`，由 Nginx 重写到 Gateway 的原生 `/api/*` 路由。只有直连后端调试时才需要设置它们。SDK 客户端的构造在 `core/api/api-client.ts`：每个请求动态注入 `X-CSRF-Token`（`frontend/src/core/api/api-client.ts:20-32` 的 `injectCsrfHeader` 文档注释明确说明：按请求读 cookie 而不是烘焙进 SDK 默认头，是为了透明处理登录/登出/改密后的 cookie 轮换）。

---

## 18.2 流式数据流：一次回复如何变成屏幕上的字

### 18.2.1 订阅入口 `useStream`

`core/threads/hooks.ts` 是全前端最大的单文件（4264 行），其中 `useThreadStream`（`frontend/src/core/threads/hooks.ts:1980`）封装了 LangGraph SDK 的 `useStream`。核心调用在 `frontend/src/core/threads/hooks.ts:2180-2192`：

```ts
// frontend/src/core/threads/hooks.ts:2180-2192（节选）
  const thread = useStream<AgentThreadState>({
    client: getAPIClient(isMock),
    assistantId,
    threadId: onStreamThreadId,
    reconnectOnMount: true,
    fetchStateHistory: { limit: 1 },
    // Batch stream updates received in the same macrotask without adding a
    // fixed debounce interval that could delay a continuously active stream.
    // Coalesce same-tick stream events into one React notification. Only the
    // boolean tier is safe: the SDK's numeric tier is a trailing debounce that
    // starves UI updates while chunks keep arriving faster than the window.
    // Keep explicit: SDK types claim @default true, but runtime uses throttle ?? false.
    throttle: true,
```

三个要点：

1. **泛型 `AgentThreadState`**：前端对后端 `ThreadState` 的投影（title / artifacts / tool_artifacts / todos / goal / messages 等），定义在 `core/threads/types.ts`。
2. **`reconnectOnMount: true` + `fetchStateHistory: { limit: 1 }`**：页面刷新或重连时先拉一次最新 checkpoint 快照再续订流，保证"断线重连不丢上下文"。
3. **`throttle: true` 的注释值得精读**：它刻意只选布尔档——SDK 的数字档是"尾沿去抖"，在 chunk 高速到达时会饿死 UI 更新；布尔档只合并同一个宏任务里的事件，既省渲染又不引入固定延迟。

### 18.2.2 三个事件回调的分工

`useStream` 的状态归一化发生在三个回调里：

**`onCreated`（`frontend/src/core/threads/hooks.ts:2193-2230`）**：run 创建即乐观更新——把新 thread 以 `status: "busy"` 写进搜索缓存与无限列表缓存，侧边栏立刻出现新会话，不用等列表接口返回。

**`onUpdateEvent`（`frontend/src/core/threads/hooks.ts:2231-2277`）**：处理 `values` 帧。先经 `hasRenderedThreadStateUpdate`（`frontend/src/core/threads/stream-state.ts:34`）过滤，只有真正会被渲染的键才触发归并：

```ts
// frontend/src/core/threads/stream-state.ts:26-32
const RENDERED_THREAD_STATE_KEYS = [
  "title",
  "artifacts",
  "tool_artifacts",
  "todos",
  "goal",
];
```

`stream-state.ts` 其余部分是防御性归并函数：`isGoalState`（`frontend/src/core/threads/stream-state.ts:18`）要求 `status === "active"` 才渲染 goal，避免历史残留或畸形数据把目标条画出来；`mergeArtifacts` 用 `Set` 去重追加；`mergeToolArtifacts`（`frontend/src/core/threads/stream-state.ts:69`）以 `handle` 为键替换元数据但不打乱首次出现顺序。**这就是"归一化层"的本体：后端任何帧都先过一遍形状校验，不合格的数据被静默丢弃而不是污染 UI。**

**`onCustomEvent`（`frontend/src/core/threads/hooks.ts:2278` 起）**：处理 `task_*` 自定义事件，即子代理进度：

```ts
// frontend/src/core/threads/hooks.ts:2278-2286（节选）
    onCustomEvent(event: unknown) {
      // Narrow `event.type` once; taskEventToSubtaskUpdate already validated the
      // task_* events, so the per-branch re-narrowing below reads this single
      // source of truth instead of re-checking the object shape each time.
      const eventType =
        typeof event === "object" && event !== null && "type" in event
          ? (event as { type: unknown }).type
          : undefined;
```

`task_running` / `task_completed` 等事件经 `core/tasks/lifecycle.ts` 的 `taskEventToSubtaskUpdate` 转成子任务卡片状态。

### 18.2.3 为什么子代理进度走"根命名空间"

一个容易踩的认知坑：后端支持 `stream_subgraphs`（带 `values|<ns>` 命名空间帧，见第 6 章），但 **Web 前端从不开启 subgraph 流**（`backend/AGENTS.md:12`："The web frontend uses root `task_*` events without subgraph streaming"）。原因写在同文件：裸 `values` 帧会覆盖 SDK 的线程视图（#4399）。子代理的进度因此被网关转写为根命名空间的 `task_*` 自定义事件，前端只需要订阅一路流。你自己写消费端时同理：**要么全量订阅命名空间帧，要么像 Web 前端一样只消费根命名空间 + 自定义事件，不要混用。**

---

## 18.3 注册表红线：`ui/` 与 `ai-elements/` 不能手改

`frontend/AGENTS.md:173` 一句话立规：

> **Components**: `ui/` 和 `ai-elements/` are generated from registries (Shadcn, MagicUI, React Bits, Vercel AI SDK) — don't manually edit these.

生成来源配置在 `frontend/components.json:21-25`：

```json
// frontend/components.json:21-25
  "registries": {
    "@ai-elements": "https://registry.ai-sdk.dev/{name}.json",
    "@magicui": "https://magicui.design/r/{name}",
    "@react-bits": "https://reactbits.dev/r/{name}.json"
  }
```

如何从代码上辨认生成物？看两个真实例子：

```tsx
// frontend/src/components/ai-elements/conversation.tsx:1-14（节选）
"use client";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { ArrowDownIcon } from "lucide-react";
import type { ComponentProps } from "react";
import { useCallback } from "react";
import { StickToBottom, useStickToBottomContext } from "use-stick-to-bottom";

export type ConversationProps = ComponentProps<typeof StickToBottom>;

export const Conversation = ({ className, ...props }: ConversationProps) => (
  <StickToBottom
```

这是典型的 Vercel AI Elements 产物形态：依赖 `use-stick-to-bottom` 这类注册表固定依赖、导出的是注册表文档里的原语组件。`ui/button.tsx` 则是标准 Shadcn `cva` 变体写法。**实践准则**：

- 需要新原语 → 用 `pnpm dlx shadcn@latest add <name>` 或对应注册表 CLI 拉取，而不是手写进 `ui/`。
- 需要定制外观 → 在 `workspace/` 等手写目录做包装组件，用 `cn()`（`@/lib/utils`）覆写类名，不改生成物本身。
- 生成物升级后会整体替换，任何手改都会丢失且 review 时无法追溯。

---

## 18.4 新增页面实操：解剖 `/workspace/scheduled-tasks`

大纲把 `/workspace/scheduled-tasks` 定为"新增 workspace 页面"的参照实现。它的分层是本仓库的标准答案：

### 18.4.1 页面层只做组合

`frontend/src/app/workspace/scheduled-tasks/page.tsx`（407 行）的第一屏代码就展示了全部依赖关系：

```tsx
// frontend/src/app/workspace/scheduled-tasks/page.tsx:45-67（节选）
const TABS: StatusTab[] = ["all", "active", "paused", "finished"];

function inTab(task: ScheduledTask, tab: StatusTab): boolean {
  return tab === "all" || statusTabOf(task) === tab;
}

export default function ScheduledTasksPage() {
  const { t, locale } = useI18n();
  const st = t.scheduledTasks;
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const threadId = searchParams.get("thread_id");
  const taskIdParam = searchParams.get("task_id");
  const feature = useScheduledTasksFeature();
  const createBlocked = !feature.running;
  // Until /api/features answers, show what an enabled tool shows (as the chat
  // card does) instead of flipping copy and "Stops when" once it loads.
  const toolEnabled = feature.isLoading || feature.toolEnabled;

  const allTasksQuery = useScheduledTasks();
  const threadTasksQuery = useThreadScheduledTasks(threadId);
```

观察四个模式：

1. **页面不写 fetch 逻辑**：数据来自 `core/scheduled-tasks/hooks.ts` 的 `useScheduledTasks()` / `useThreadScheduledTasks(threadId)`；`?thread_id=` 参数把列表收窄到某个会话，`?task_id=` 负责选中态（`frontend/AGENTS.md:64`）。
2. **功能开关前置**：`useScheduledTasksFeature()` 读 `/api/features`，`scheduler.tool_enabled` 关闭时按钮禁用，且 `/api/features` 未返回前不翻转文案（上面的英文注释）。
3. **状态标签是纯函数**：`statusTabOf(task)` 来自 `components/workspace/scheduled-tasks/shared.tsx`，`TABS` 驱动 `all / active / paused / finished` 四个页签。
4. **i18n 必接**：`t.scheduledTasks` 直接取词条，任何新页面都要在 `core/i18n` 的语言包里补键。

### 18.4.2 组件族与纯函数域

页面组合的组件全部位于 `components/workspace/scheduled-tasks/`，共 12 个文件：`task-list.tsx`（列表 + 状态页签 + 搜索）、`task-detail.tsx`（Runs / Stops when / goal / History 详情）、`task-form-dialog.tsx`（创建/编辑/复制对话框，PATCH 只发改动字段、`null` 清除）、`renew-limits-dialog.tsx`（`limits_exhausted` 时 Resume 打开的续期对话框）、`task-outcome-notice.tsx`（结果横幅）、`scheduler-state-notice.tsx`、`bind-feishu-group.tsx`、`notification-group.tsx`、`run-row.tsx`、`delete-task-dialog.tsx`、`empty-state.tsx`、`shared.tsx`。

对应的业务域 `core/scheduled-tasks/` 是**纯函数优先**：`status.ts`（"任务是否在跑"= `status === "running"` 或 `active_run_status`）、`actions.ts`、`format.ts`、`describeTaskSchedule`、`errors.ts`（按 `detail.code` 本地化错误）、`search.ts`（字面量过滤）、`goal-outcome.ts`、`events.ts`、`tool-result.ts`。`frontend/AGENTS.md:63` 明确要求列表、详情、聊天卡片三处 UI 都从这些纯 helper 读状态，**这样三处显示永远一致，且每一处都能用 node 环境单测覆盖**。`contracts/scheduled_task_errors_contract.json` 与 `contracts/scheduled_goal_notes_contract.json` 把错误码/结果文案钉成跨端契约（`frontend/AGENTS.md:62-63`）。

### 18.4.3 抽象成公式

新增任意 workspace 页面的步骤：

1. `app/workspace/<your-page>/page.tsx`：只做参数解析、功能开关判断、组件组合。
2. `core/<your-domain>/`：`types.ts` + `hooks.ts`（TanStack Query 封装）+ 纯函数（状态推导、格式化、错误映射），能在 node 测试环境跑的都放这里。
3. `components/workspace/<your-domain>/`：展示组件，条件类名一律 `cn()`。
4. `core/i18n` 双语词条 + `contracts/`（若有跨端字符串）。
5. 测试：`tests/unit/<镜像路径>/*.test.ts`（逻辑）+ `*.dom.test.tsx`（组件渲染）。

---

## 18.5 工程工作流：从改代码到提交

### 18.5.1 命令面

`frontend/package.json:6-23` 是命令的唯一权威：

```json
// frontend/package.json:6-23
  "scripts": {
    "catalog:sync": "node scripts/sync-capability-catalog.mjs",
    "demo:save": "node scripts/save-demo.js",
    "build": "next build && pnpm run search:index",
    "check": "eslint . --ext .ts,.tsx && tsc --noEmit",
    "dev": "node scripts/dev.mjs",
    "format": "prettier --check .",
    "format:write": "prettier --write .",
    "lint": "eslint . --ext .ts,.tsx",
    "lint:fix": "eslint . --ext .ts,.tsx --fix",
    "perf:check": "node scripts/measure-route-assets.mjs --check",
    "preview": "pnpm run build && next start",
    "search:index": "node scripts/build-search-index.mjs",
    "start": "next start",
    "test": "rstest",
    "test:e2e": "playwright test",
    "typecheck": "tsc --noEmit"
  },
```

日常循环：`pnpm dev` 开发（**Webpack 默认**；`DEER_FLOW_DEV_BUNDLER=turbo pnpm dev` 才是 Turbopack，`frontend/AGENTS.md:32`）、提交前 `pnpm check`（ESLint + `tsc --noEmit`）、`pnpm test` 跑单测、`pnpm test:e2e` 跑 Playwright。注意 host 上的 pnpm 调用统一走 `../scripts/pnpm.py`（`frontend/AGENTS.md:23`），它解决了 Windows 上 `pnpm.cmd` 与 Corepack 的顺序问题（附录 E）。

另外两个容易被忽略的工程闸门：

- **性能预算**：`pnpm perf:check` 度量 `/login` 生产构建与静态 demo 路由的唯一 JS/CSS 体积，对照 `performance-budgets.json`，超预算要拆分路由（`frontend/AGENTS.md:261-266`）。
- **文档搜索索引**：`pnpm build` 末尾跑 `scripts/build-search-index.mjs` 重建 `public/_pagefind/`（`frontend/AGENTS.md:254-256`），改了 `content/` MDX 后文档站搜索才会更新。

### 18.5.2 测试环境切分：node vs happy-dom

`frontend/rstest.config.ts` 用两个 project 把单测切成两档：

```ts
// frontend/rstest.config.ts:22-35（节选）
  projects: [
    {
      ...shared,
      name: "node",
      include: ["tests/unit/**/*.test.ts", "tests/unit/**/*.test.tsx"],
      // A DOM environment costs roughly 3x the runtime of this suite, so the
      // pure-logic tests that make up nearly all of it stay on node and only
      // `*.dom.test.*` pays for a document.
      exclude: { patterns: ["**/*.dom.test.*"], override: false },
    },
    {
      ...shared,
      name: "dom",
      testEnvironment: "happy-dom",
      include: ["tests/unit/**/*.dom.test.ts", "tests/unit/**/*.dom.test.tsx"],
    },
  ],
```

规则：**纯逻辑测试（`*.test.ts`）跑 node 环境；只有组件/hooks 渲染测试用 `*.dom.test.tsx` 命名进 happy-dom**（`frontend/AGENTS.md:37-39`）。DOM 环境慢约 3 倍，这就是 18.4.2 强调"状态推导写进 core 纯函数"的测试动机。E2E 侧是 Playwright Chromium（`tests/e2e/`），CI 分四个 shard、只有 shard 1 跑认证恢复流程，用 `page.route()` mock 后端 API（`frontend/AGENTS.md:46-52`）。

### 18.5.3 Windows 与开发源限制

两处平台相关设定要提前知道：

- Windows dev server 绑定 `127.0.0.1` 以避开 Hyper-V/winnat 的 `EACCES`（#2870，`frontend/AGENTS.md:34`）；要给局域网访问用 `pnpm dev -- --hostname 0.0.0.0`。
- 非本机访问 dev server 需要 `DEER_FLOW_DEV_ALLOWED_ORIGINS` 列出允许的主机，否则 Next 的 `allowedDevOrigins` 会让 `/_next/*`、HMR、甚至登录请求 403（`frontend/AGENTS.md:224-227`）。生产构建忽略该设置。

---

## 动手实验：为 artifacts 新增一种自定义预览卡片

本实验按 TDD 顺序给产物面板加一个"纯文本大文件行数统计"预览卡（不触碰后端，离线可复现）。

**第 0 步：认清现状。** 产物预览体系在两处：`core/artifacts/`（`preview.ts` 决定预览模式、`delimited-preview.ts` + `delimited-preview.worker.ts` + `use-delimited-preview.ts` 是 CSV/TSV 的 worker 预览链路）、`components/workspace/artifacts/`（`artifact-file-preview.tsx` 按 `preview.ts` 的结论分发到 `artifact-table-preview.tsx` 等具体渲染器）。`frontend/AGENTS.md:282-289` 记录了表格预览的边界约束（最多 202 条逻辑记录、50 列、5 秒超时）——你的新卡片要遵守同样的"先限定输入再进 worker"纪律。

**第 1 步：先写失败测试。** 新建 `frontend/tests/unit/core/artifacts/preview.test.ts`：

```ts
import { describe, expect, it } from "rstest";

import { resolvePreviewMode } from "@/core/artifacts/preview";

describe("resolvePreviewMode", () => {
  it("returns line-count mode for plain text over the size threshold", () => {
    expect(resolvePreviewMode({ mime: "text/plain", size: 3_000_000 })).toBe(
      "line-count",
    );
  });

  it("keeps existing modes untouched", () => {
    expect(resolvePreviewMode({ mime: "text/csv", size: 10 })).toBe("table");
  });
});
```

跑 `pnpm rstest run preview` —— 应当失败（`line-count` 模式尚不存在），这就是 TDD 的红灯。

**第 2 步：最小实现。** 在 `core/artifacts/preview.ts` 中扩展模式解析（保持纯函数），随后新增 `components/workspace/artifacts/artifact-line-count-preview.tsx`，在 `artifact-file-preview.tsx` 的分发 `switch` 里加一个 case。所有异步/大输入处理沿用 `use-delimited-preview.ts` 的模式：**在主线程先做尺寸上限判断再决定是否加载解析器，组件卸载时取消未完成的工作**。

**第 3 步：补组件测试（可选但推荐）。** 新建 `artifact-line-count-preview.dom.test.tsx`，用 `@testing-library/react` 渲染并断言行数文案；记得以 `.dom.test.` 命名，它才会进 happy-dom project。

**第 4 步：全量门禁。** 依次跑 `pnpm check`、`pnpm test`；若改动了被 E2E 覆盖的产物面板交互，再跑相关 `pnpm test:e2e` spec。绿灯后，你就完整走了一遍本仓库的前端变更闭环：纯函数域 + 组件 + 双环境测试 + lint/type 闸门。

---

## 常见坑

1. **手改 `ui/` / `ai-elements/`**：下次从注册表同步时被整体覆盖，改动无声丢失。要定制就写包装组件（`cn()` 覆写类名），要新原语就走 CLI 拉取（见 18.3）。
2. **环境变量指错地方**：把 `NEXT_PUBLIC_LANGGRAPH_BASE_URL` 设成 `http://localhost:8001/api` 又跑标准 `make dev`，会绕过 Nginx 的 `/api/langgraph` 重写，出现跨域与 CSRF 行为不一致。默认留空走同源代理，仅在直连调试时设置（18.1.3）。
3. **指望前端订阅 subgraph 流**：前端只有根命名空间一路流 + `task_*` 自定义事件；自己另开 `stream_subgraphs` 会拿到 `values|<ns>` 帧，与 `AgentThreadState` 归一化逻辑不兼容（18.2.3）。
4. **Windows 上 dev server 起不来**：报 `EACCES` 多半是绑了 `0.0.0.0` 撞上 Hyper-V/winnat 保留端口；默认绑定是 `127.0.0.1`（#2870），局域网需求用 `--hostname` 参数显式开启（18.5.3）。
5. **测试环境用错**：组件渲染测试忘了 `.dom.test.` 命名，`@testing-library/react` 在 node 环境直接报 `document is not defined`；反过来把纯逻辑塞进 DOM 环境则白白拖慢 3 倍（18.5.2）。
6. **字符长度按 UTF-16 数**：自定义 Agent `display_name` 的 100 上限按 Unicode 码点计（`[...value.trim()].length`，与后端 Pydantic 对齐），用 HTML `maxLength` 会把 emoji 算成两个（`frontend/AGENTS.md:142-145`）。

---

## 下一步

到这里，你已经能在前端把"看得见的部分"改到位。但一个变更要真正合入，还要过全仓库的质量闸门：后端四分片测试、Blockbuster 阻塞 IO 门禁、基准测试纪律、CI 工作流。下一章（第 19 章 可观测性、测试与质量保障）把这套质量体系拆开讲透——你会看到 `make test` 的分片算法为什么是"按耗时均衡"，以及 `trace_id` 是如何从 HTTP 请求一路流进日志的。
