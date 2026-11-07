---
title: 首页
---

# DeerFlow 从入门到精通 · 源码教程

**DeerFlow**（**D**eep **E**xploration and **E**fficient **R**esearch **Flow**）是开源的
超级 Agent Harness：基于 LangGraph 构建，由一个 lead agent 编排**子代理**、**持久记忆**、
**沙箱代码执行**与**可扩展技能/工具**，全部按会话线程隔离；Next.js 聊天界面之外，
飞书 / Slack / Telegram / Discord / 钉钉等 IM 渠道通过 Gateway 接入**同一个** Agent。

> 🔗 **源码仓库**：[bytedance/deer-flow](https://github.com/bytedance/deer-flow)
> —— 本教程基于其 `main` 分支真实源码编写；本站点由独立发布仓
> [jigangbo/deer-flow-tutorial](https://github.com/jigangbo/deer-flow-tutorial) 构建发布。

本教程共 **21 章 + 附录**，全部基于仓库真实源码撰写，引用源码位置 1200+ 处
（`相对路径:行号`）。入门篇重"跑通与直觉"，进阶篇重"机制与源码"，精通篇重"决策与实战"。

---

## 项目全景架构

```
                       浏览器 │ IM 渠道(飞书/Slack/Telegram/Discord/钉钉) │ 定时任务
              ────────────────┴──────────────────┬─────────────────────┴────────────
                                              ┌────▼────┐
                                              │  Nginx  │  :2026 唯一公网入口(回环默认)
                                              └────┬────┘
                 /api/langgraph/* ──重写──▶ /api/* ││ 其余请求 ──▶ Frontend
              ┌────────────────────────┬───────────┘└──────────────────────┐
              │                        │                                   │
   ┌──────────▼─────────────┐   ┌──────▼───────────────────┐   ┌───────────▼──────────┐
   │  Gateway API :8001     │   │  Frontend :3000          │   │ Provisioner :8002    │
   │  FastAPI + 内嵌运行时   │   │  Next.js 16 / React 19   │   │ (可选)沙箱 K8s 模式   │
   │  ┌───────────────────┐ │   │  /workspace /showcase    │   └──────────────────────┘
   │  │ app.*  网关+IM渠道 │ │   └──────────────────────────┘
   │  └────────┬──────────┘ │
   │           │ 单向依赖    │
   │  ┌────────▼──────────┐ │
   │  │ deerflow.* Harness│ │   横切子系统：config.yaml + extensions_config.json
   │  │ runtime 中间件链   │ │   skills 技能 · sandbox 沙箱 · subagents 子代理
   │  │ sandbox 技能 MCP  │ │   memory(DeerMem) · scheduler 定时 · persistence
   │  │ memory scheduler  │ │
   │  └───────────────────┘ │
   └────────────────────────┘
```

## 主工作流：一次对话请求的一生

```
 (1) 用户在会话页发送消息（可携带文件上传）
      │
      ▼
 (2) Nginx :2026  ── /api/langgraph/* 重写 ──▶  Gateway /api/threads/{id}/runs
      │
      ▼
 (3) RunManager.start_run()：消息赋 ID、记录输入、checkpoint 幂等
      │
      ▼
 (4) run_agent()：make_lead_agent() 组装 lead agent + 中间件链
      │
      ▼
 (5) 中间件链逐环执行
      ThreadData → Uploads → Sandbox → Summarization → Title → TodoList → ViewImage → Clarification → ...
      │
      ▼
 (6) 模型调用（create_chat_model，多供应商 + vision / 深度思考）
      │
      ├─(6a)─▶ task 工具 ──▶ SubagentExecutor 子代理委派（隔离图 + 验收契约）
      ├─(6b)─▶ 技能激活 ──▶ skills/*/SKILL.md 领域流程
      ├─(6c)─▶ bash / 文件工具 ──▶ Sandbox 沙箱执行（/mnt/user-data 映射）
      └─(6d)─▶ MCP 工具 ──▶ 独立进程 / McpTaskService 长任务租约
      │
      ▼
 (7) StreamBridge ──▶ SSE 流（messages-tuple / values 快照 / task_* 事件）
      │
      ▼
 (8) 前端 core/threads 归一化 SSE ──▶ TanStack Query ──▶ 渲染消息/子任务卡/产物
      │
      ▼
 (9) checkpoint 持久化 + DeerMem 记忆写入 + RunEventStore 事件落库
```

## 代码-流程映射表

| 流程步骤 | 源码入口 | 教程章节 |
| --- | --- | --- |
| (1) 界面与上传 | `frontend/src/app/workspace/chats/[thread_id]/`、`app/gateway/`（uploads 路由） | 第 4、13 章 |
| (2) 入口代理 | `docker/nginx/nginx.conf`（`/api/langgraph` 重写） | 第 2、13 章 |
| (3) run 管理 | `app/gateway/`（`start_run`）、`deerflow/runtime/`（`RunManager`） | 第 6 章 |
| (4) Agent 组装 | `deerflow/agents/lead_agent/agent.py`（`make_lead_agent`） | 第 6、9 章 |
| (5) 中间件链 | `deerflow/agents/middlewares/`、`deerflow/sandbox/middleware.py` | 第 6 章 |
| (6a) 子代理委派 | `deerflow/subagents/executor.py`、`registry.py` | 第 9 章 |
| (6b) 技能系统 | `deerflow/skills/`、`skills/public/` | 第 7 章 |
| (6c) 沙箱执行 | `deerflow/sandbox/sandbox_provider.py`、`community/aio_sandbox/` | 第 8 章 |
| (6d) MCP 集成 | `deerflow/mcp/`、`extensions_config.json → mcpServers` | 第 15 章 |
| (7) SSE 流协议 | `deerflow/runtime/`（`StreamBridge`）、`worker.py` | 第 6、13 章 |
| (8) 前端渲染 | `frontend/src/core/threads/` | 第 4、18 章 |
| (9) 持久化与记忆 | `deerflow/agents/memory/`、`deerflow/persistence/` | 第 10、20 章 |
| 扩展点 | `packages/extension-api/`、`examples/deerflow-extension-*` | 第 16、17 章 |

## 章节索引

### 第〇部分 导读

| 章 | 内容 |
| --- | --- |
| [第 0 章 全景鸟瞰](00-introduction.md) | 定位、四服务拓扑、Harness/App 分层、四交互面 |

### 第一篇 入门篇：环境配置与一键运行

| 章 | 内容 |
| --- | --- |
| [第 1 章 准备环境](01-environment.md) | 版本清单、目录导览、模型 Key、`make check` / `make doctor` |
| [第 2 章 一键启动](02-quickstart.md) | `make config → install → dev`、2026 入口原理、首次对话 |
| [第 3 章 配置系统入门](03-configuration.md) | `config.yaml` vs `extensions_config.json`、热改、TOP 5 配置段 |
| [第 4 章 前端界面导览](04-frontend-tour.md) | 会话页、自定义 Agent、showcase、定时任务页、i18n |
| [第 5 章 更多运行方式](05-run-modes.md) | `make start`、Docker 开发/生产栈、Helm、四象限对比 |

### 第二篇 进阶篇：核心组件拆解

| 章 | 内容 |
| --- | --- |
| [第 6 章 一次请求的一生](06-request-lifecycle.md) ★ | RunManager/StreamBridge、完整中间件链、ThreadState、SSE 协议 |
| [第 7 章 工具系统与 Skills](07-tools-and-skills.md) ★ | 三来源合并、SKILL.md 解剖、23 个官方技能、质量评审闭环 |
| [第 8 章 沙箱与代码执行](08-sandbox.md) ★ | Local vs Aio Provider、路径映射、租约、Provisioner |
| [第 9 章 Multi-Agent 路由与子代理委派](09-multi-agent.md) ★ | `make_lead_agent`、execution_id 关联链、验收契约、批处理 |
| [第 10 章 记忆系统](10-memory.md) | DeerMem 双通道、容量淘汰双策略、FTS5 检索 |
| [第 11 章 上下文工程](11-context-engineering.md) | SummarizationMiddleware、手动 compact、六层防护、Plan Mode |
| [第 12 章 定时任务与 IM 渠道](12-scheduled-tasks-and-im.md) | 两级开关、八态生命周期、多实例调度、五渠道接入 |
| [第 13 章 Gateway API](13-gateway-api.md) | 40 个路由模块、认证、上传协议、WebSocket、`DeerFlowClient` |

### 第三篇 精通篇：二次开发与 MCP 集成

| 章 | 内容 |
| --- | --- |
| [第 14 章 架构分层与开发规范](14-architecture-layers.md) | Harness/App 边界 CI 强制、extension-api 契约、TDD 门禁 |
| [第 15 章 MCP 集成](15-mcp.md) ★ | stdio/http 配置、双锁原子写、McpTaskService、拦截器 |
| [第 16 章 扩展开发](16-extensions.md) ★ | 九大贡献点、安装事务、官方示例、"周报收集"扩展实战 |
| [第 17 章 业务二次开发实战](17-business-cases.md) ★ | 分流决策树 + 知识库/数据分析/研报/IM 客服/自定义模型 |
| [第 18 章 前端二次开发](18-frontend-dev.md) | core/ 业务域、流式数据流、注册表红线、artifacts 卡片实战 |
| [第 19 章 可观测性、测试与质量](19-testing-quality.md) | trace、token 预算、四分片测试、Blockbuster、三大基准 |
| [第 20 章 生产部署与运维](20-production.md) | SQLite/Postgres、多实例租约、Helm、版本锁步、安全清单 |

### 附录

| 附录 | 内容 |
| --- | --- |
| [appendices.md](appendices.md) | A 命令速查 · B 配置项速查 · C 术语表 · D 验收清单 · E FAQ · F 官方文档映射 |

## 快速开始

- **只想跑起来** → [第 1 章 准备环境](01-environment.md) → [第 2 章 一键启动](02-quickstart.md)（约 30 分钟）
- **想看懂内部机制** → [第 6 章 一次请求的一生](06-request-lifecycle.md) 开始沿第二篇顺读
- **要做二次开发** → [第 14 章 架构分层](14-architecture-layers.md) → [第 15 章 MCP](15-mcp.md) → [第 16 章 扩展](16-extensions.md)
- **查询命令/配置** → 直接翻 [附录](appendices.md) A / B / E
