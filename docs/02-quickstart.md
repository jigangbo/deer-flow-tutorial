# 第 2 章 一键启动（Quick Start）

## 2.0 学习目标

读完本章，你应该能够：

1. 用标准三步 `make config` → `make install` → `make dev` 从零把全栈跑起来；
2. 解释为什么浏览器入口是 `http://localhost:2026`（Nginx）而不是 `3000`/`8001`，以及
   回环绑定默认值 `BIND_HOST` 的含义与修改时机；
3. 在 Web 界面完成首次对话：创建 thread、发送消息、上传文件、查看 artifacts 产物、
   todos 任务卡与 `/goal` 完成条件；
4. 用 `logs/gateway.log` / `logs/frontend.log` 排查启动问题，并用 `make stop` 干净地停栈。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 三步命令 | `Makefile:87`（config）、`Makefile:104`（install）、`Makefile:154`（dev） |
| 统一启动器 | `scripts/serve.sh` |
| Gateway 启动参数 | `backend/Makefile:8`（dev target） |
| 本地 nginx 配置 | `scripts/nginx-local-conf.sh`、`docker/nginx/nginx.local.conf` |
| 回环绑定约束 | `backend/tests/test_local_dev_loopback_bind.py`、`backend/tests/test_compose_default_bind_host.py` |
| 文件上传协议 | `backend/AGENTS.md:283`、`config.example.yaml:1705` |
| 日志路径 | `scripts/serve.sh:527`、`scripts/serve.sh:532` |

---

## 2.1 标准三步

### 第一步：`make config` —— 生成两份运行时配置

```bash
make config    # Makefile:87 → scripts/configure.py
```

`scripts/configure.py` 的核心逻辑是 `copy_if_missing`（`scripts/configure.py:12`）：
从模板生成两份 **gitignored** 的运行时配置，已存在则跳过、绝不覆盖：

- `config.yaml` ← `config.example.yaml`（模型、工具、沙箱、记忆、调度器……）；
- `extensions_config.json` ← `extensions_config.example.json`（MCP 服务器 + 技能）。

如果你是交互式安装的爱好者，也可以用 `make setup`（`Makefile:72`）启动向导
（`scripts/setup_wizard.py`），它在终端里引导你选供应商、填 Key、写配置。

### 第二步：`make install` —— 装前后端依赖

```bash
make install    # Makefile:104
```

对应 Makefile 内容（`Makefile:104`）：

```makefile
install:
	@echo "Installing backend dependencies..."
	@cd backend && uv sync --locked
	@echo "Installing frontend dependencies..."
	@cd frontend && $(FRONTEND_PNPM) install
	@echo "Installing pre-commit hooks..."
	@uv tool install pre-commit
	@uv tool run pre-commit install --overwrite
```

三件事：后端 `uv sync --locked`（按 `uv.lock` 精确安装）、前端 `pnpm install`（经
`scripts/pnpm.py` 运行器）、pre-commit 钩子。安装结束后会提示一个可选步骤
（`Makefile:114`）：如果计划使用 Docker/容器沙箱，先 `make setup-sandbox` 预拉取
约 500MB+ 的沙箱镜像，避免第一次执行工具时长时间等待（`backend/docs/SETUP.md:72`）。

### 第三步：`make dev` —— 全栈热重载启动

```bash
make dev    # Makefile:154
```

它先跑一遍 `make check` 预检工具链（`Makefile:156`），再调
`./scripts/serve.sh --dev`。`serve.sh` 是统一启动器，负责按顺序拉起：

1. **Gateway**：在 `backend/` 目录执行
   `uvicorn app.gateway.app:app --host 127.0.0.1 --port 8001 --reload`
   （见 `backend/Makefile:8` 的 dev target——注意它预创建并把 `DEER_FLOW_HOME` 与
   `backend/sandbox` 排除出重载监视，否则 Agent 运行时写文件会不断触发 Gateway 重启，
   `backend/AGENTS.md:122`）；
2. **前端**：`frontend/` 下启动 Next.js dev server（`3000` 端口，同样绑定 `127.0.0.1`，
   见 `frontend/AGENTS.md:34` 的 Windows 回环说明）；
3. **Nginx**：以 `docker/nginx/nginx.local.conf` 为模板在本机拉起，监听 `2026`。

### 一个容易忽略的点：启动模式总表

`backend/AGENTS.md:237` 有一张权威的启动模式表，`make dev` 只是其中"Local Foreground +
Dev"一格：

| | Local Foreground | Local Daemon | Docker Dev | Docker Prod |
|---|---|---|---|---|
| **Dev** | `make dev` | `make dev-daemon` | `make docker-start` | — |
| **Prod** | `make start` | `make start-daemon` | — | `make up` |

第 5 章会逐一展开其余模式；本章专注左上角那一格。

---

## 2.2 打开 `http://localhost:2026`

三步跑完、终端不再滚动后，浏览器访问 **`http://localhost:2026`**——不是 3000，也不是 8001。

### 为什么入口是 Nginx

本地模式同时有三个 HTTP 端点，但分工不同（`docs/ARCHITECTURE.md:31`）：

- `2026`（Nginx）：**唯一对外入口**。非 API 请求伺服前端页面；`/api/*` 反代 Gateway；
  `/api/langgraph/*` 被重写到 Gateway 的原生 `/api/*` 路由；
- `3000`（Next.js dev server）：只服务 Nginx 这一个上游，本地开发直连它会遇到 API
  代理缺失的问题；
- `8001`（Gateway）：REST + 内嵌 LangGraph 兼容运行时，同上，设计上不直接暴露给浏览器。

本地 nginx 的监听地址由 `docker/nginx/nginx.local.conf` 定义；`scripts/nginx-local-conf.sh`
负责在设置了 `BIND_HOST` 时渲染一份替换了 `listen` 行的副本到 `temp/`，其注释写明了原则
（`scripts/nginx-local-conf.sh:8`）：

> Gateway and frontend stay on loopback either way: nginx is the only entry point.

### 回环默认与 `BIND_HOST`

`.env` 里两个控制绑定的变量（`.env.example:52`）：

```bash
# BIND_HOST=0.0.0.0
# PORT=2026
```

默认 `127.0.0.1`：整个栈只对本机可见。这与 Docker 栈的发布约定完全一致——
Compose 把 nginx 发布为 `"${BIND_HOST:-127.0.0.1}:${PORT:-2026}:2026"`，
Gateway 的 `8001` 永远不发布（`docs/ARCHITECTURE.md:44`），
`backend/tests/test_compose_default_bind_host.py` 与
`backend/tests/test_local_dev_loopback_bind.py` 两个测试把它钉死。

**为什么这么谨慎**：DeerFlow 的 Agent 能执行系统命令，官方安全模型是"本地可信环境"
（`README.md:4137`）。要跨机访问时，在 `.env` 设 `BIND_HOST=0.0.0.0` 之前，先完成
首次初始化（创建管理员账号）并落实安全措施——这是第 5 章和第 20 章的主题。

首次打开 `http://localhost:2026` 会进入初始化/登录流程（`(auth)/setup`、`(auth)/login`
路由，见 `frontend/src/app/`），按提示创建账号即可。

---

## 2.3 首次对话

`frontend/AGENTS.md:118` 用一句话定义了前端的全部核心交互：

> Users create **threads** (conversations), send messages, set thread-scoped `/goal`
> completion conditions, and receive streamed responses, agent **artifacts** (files/code),
> **todos** and goal state updates.

按这个顺序体验一遍：

### 1. 创建 thread（会话）

进入工作区后新建一个聊天。每个 thread 在后端对应独立的数据目录
`backend/.deer-flow/threads/{thread_id}/`，上传、产物、checkpoint 全部按线程隔离
（`docs/ARCHITECTURE.md:93`）。

### 2. 发送消息，观察流式回复

回复经 SSE 流式返回：消息逐块渲染，标题自动生成（`TitleMiddleware`），如果模型支持思考，
思考内容也会单独呈现。

### 3. 上传文件

把一个 Excel/CSV/PDF 拖进输入区。上传走
`POST /api/threads/{thread_id}/uploads`（`backend/AGENTS.md:286`）：

- Office/PDF 文档经 `markitdown` 转换为文本供模型阅读（每个请求一个转换 worker）；
- 文件落在线程隔离的 `users/{user_id}/threads/{thread_id}/user-data/uploads`；
- HTTP 上传先写成隐藏的 `.upload-*.part` 临时文件，校验大小后原子发布
  （`backend/AGENTS.md:288`）；
- 应用层上限在 `config.example.yaml:1705`：

```yaml
uploads:
  max_files: 10
  max_file_size: 52428800    # 50 MiB
  max_total_size: 104857600  # 100 MiB
```

### 4. 查看 artifacts（产物）

让 Agent"把结果画成图表"或"生成一份报告文件"。Agent 通过沙箱里的 `write_file` 等工具
产出文件，这些文件作为 **artifacts** 流回前端，在会话页的产物面板中预览/下载。
ThreadState 扩展字段 `sandbox / artifacts / thread_data / title / todos / viewed_images`
记录了这一切（`docs/ARCHITECTURE.md:93`）。

### 5. todos 任务卡与 `/goal`

- 在输入框输入 `/` 可以看到斜杠命令面板——Web 端只有 `/goal` 与 `/compact` 两个
  （`frontend/AGENTS.md:439`）；`/goal` 为当前线程设定完成条件，运行结束时系统会评估
  目标是否达成并展示 goal 状态；
- 打开 Plan Mode（界面开关）后，Agent 获得 `write_todos` 工具，把多步任务拆成实时更新的
  任务卡（`backend/AGENTS.md:296`：`config.configurable.is_plan_mode=True` enables
  TodoList `write_todos`）。

---

## 2.4 看日志与停栈

### 日志双跟随

本地 `make dev` 模式下，Gateway 与前端输出落在仓库根的 `logs/` 目录
（根 `AGENTS.md` "Logs" 一节；写入点在 `scripts/serve.sh:527` 与 `scripts/serve.sh:532`）：

```bash
tail -f logs/gateway.log logs/frontend.log
```

常见错误模式：

- Gateway 启动即退出 → `logs/gateway.log` 里通常是 `config.yaml` 解析错误或模型 Key 无效；
- 页面 502 → Gateway 还没就绪或已崩溃，看 `logs/gateway.log`；
- 页面白屏/静态资源 404 → 前端未就绪，看 `logs/frontend.log`。

`serve.sh` 在等待 Gateway 就绪超时时也会提示你去看 `logs/gateway.log`
（`scripts/serve.sh:512`），本地等待秒数可用 `.env` 的
`DEER_FLOW_GATEWAY_STARTUP_TIMEOUT` 调大（默认 30，`.env.example:42`）。

### 停栈

```bash
make stop    # Makefile:180 → ./scripts/serve.sh --stop
```

它会停掉本地模式拉起的 Gateway、前端与 nginx。若想连运行时数据一起清掉，用
`make clean`（`Makefile:194`：先跑 `check-data-not-in-use.sh` 保护，再 stop，然后删除
`backend/.deer-flow` 下的 database、users、threads、uploads、memory、secrets 与
`logs/*.log`）——这是一个**有损**操作，别在有价值数据上执行。

---

## 动手实验 2-1：三步启动 + "上传 Excel → 生成图表"

从零走完全流程（假设第 1 章体检已通过、`models:` 已配置至少一个可用模型）：

```bash
# 0. 保险起见确认工具链
make check

# 1. 生成配置（已有则跳过）
make config

# 2. 安装依赖（首次约几分钟）
make install

# 3. 启动全栈
make dev
```

然后：

1. 浏览器打开 `http://localhost:2026`，完成首次账号初始化/登录；
2. 新建聊天，上传一个 Excel 文件（两列数字即可），消息写：
   "读取我上传的表格，用 Python 画一张柱状图，保存为 PNG 展示给我"；
3. 观察四件事并记录：
   - 消息流式返回的过程；
   - Agent 调用了哪个工具执行 Python（沙箱内的 `bash`/`python`）；
   - artifacts 面板里出现的 PNG 产物；
   - `tail -f logs/gateway.log` 里这次 run 的中间件/工具活动痕迹；
4. 给线程设置一个 `/goal`（例如"必须展示图表并列出数据摘要"），重发一条消息，
   观察目标完成状态的变化；
5. `Ctrl+C` 停掉 `make dev`，再执行 `make stop`，确认三个端口（2026/3000/8001）都不再监听。

预期产出：一次完整对话截图 + 一段日志摘录。若中途失败，把 `logs/gateway.log` 的最后
50 行与第 2 章常见坑对照。

---

## 常见坑

1. **访问 3000 发现页面异常**：前端 `3000` 是 Nginx 的上游，浏览器入口是 `2026`；
   直连 3000 会遇到 `/api/*` 代理缺失、跨域等问题。
2. **`make dev` 卡在等待 Gateway**：看 `logs/gateway.log`——多半是 `config.yaml` 语法错误
   或模型环境变量缺失；慢冷启动可调大 `.env` 的
   `DEER_FLOW_GATEWAY_STARTUP_TIMEOUT`（`.env.example:42`）。
3. **改了 Python 文件 Gateway 一直重启**：不要用裸 `uvicorn --reload` 替代 `make dev`；
   后端 dev target 专门排除了 `DEER_FLOW_HOME` 与 `backend/sandbox` 的监视
   （`backend/AGENTS.md:122`），Agent 运行时写文件不应触发重载。
4. **上传大文件被拒**：默认单文件 50 MiB、单请求总量 100 MiB、最多 10 个文件
   （`config.example.yaml:1705`）；超限请调整 `uploads:` 段。
5. **找不到上传的文件在磁盘哪里**：按线程隔离存放于
   `users/{user_id}/threads/{thread_id}/user-data/uploads`（`backend/AGENTS.md:287`），
   仓库根的 `users/` 是运行时数据目录。
6. **`make stop` 后端口仍被占用**：确认是本地模式遗留进程还是之前用 Docker 模式起的栈——
   两种模式的停止命令不同（Docker 用 `make docker-stop` / `make down`，见第 5 章）。
7. **以为 `/` 里有很多斜杠命令**：Web 端斜杠面板只有 `/goal` 和 `/compact`
   （`frontend/AGENTS.md:439`）；技能引用走 `@` 提及，不要找 `/skill` 这类命令。

---

## 下一步

栈已经能跑，但"配置"还是黑盒——模型怎么换？沙箱怎么切换？调度器怎么开？
下一章《第 3 章 配置系统入门》拆解 `config.yaml` 与 `extensions_config.json` 的分工、
热改机制与最常改的五个配置段——见 `03-configuration.md`。
