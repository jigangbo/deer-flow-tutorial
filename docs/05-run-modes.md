# 第 5 章 更多运行方式

## 5.0 学习目标

读完本章，你应该能够：

1. 在"本地前台 / 本地守护进程 / Docker 开发 / Docker 生产"四种模式中按场景选型，
   并说出每种模式的启动与停止命令；
2. 用 `make start` / `make start-daemon` 跑本地生产模式，用 `SKIP_FRONTEND_BUILD=1`
   复用上一次前端构建；
3. 区分 Docker 开发栈（`make docker-start`，源码挂载 + 热重载）与 Docker 生产栈
   （`make up`，构建镜像 + `/health` 就绪等待）；
4. 了解 Helm 部署的形态：Chart 位于 `deploy/helm/deer-flow/`，配置以 home 卷可写副本
   方式注入；
5. 通过对比 `make dev` 与 `make up` 的进程结构和日志位置，建立"同一系统、不同封装"的直觉。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 全部运行模式命令 | `Makefile:154`（dev）至 `Makefile:246`（prod-logs） |
| 模式对比权威表 | `backend/AGENTS.md:237` |
| 本地启动器 | `scripts/serve.sh`（头部用法注释 :4） |
| Docker 开发栈 | `scripts/docker.sh`、`docker/docker-compose-dev.yaml` |
| Docker 生产栈 | `scripts/deploy.sh`、`docker/docker-compose.yaml` |
| Helm Chart | `deploy/helm/deer-flow/`（`Chart.yaml`、`values.yaml`、`templates/`） |
| 沙箱模式自动检测 | `scripts/deploy.sh:11`（"Sandbox mode ... is auto-detected from config.yaml"） |

---

## 5.1 本地生产模式：`make start` / `make start-daemon`

### `make start`

```bash
make start    # Makefile:162
```

对应 Makefile：

```makefile
start:
	@$(PYTHON) ./scripts/check.py
	@$(RUN_SHELL_SCRIPT) ./scripts/serve.sh --prod $(if $(filter 1,$(SKIP_FRONTEND_BUILD)),--skip-frontend-build)
```

（摘自 `Makefile:162`。）与 `make dev` 的三点差异：

- `serve.sh` 以 `--prod` 运行：前端先执行 `next build` 产物构建再启动，Gateway 关闭
  `--reload` 热重载（模式语义见 `scripts/serve.sh:10`："Production mode, pre-built
  frontend, no hot-reload"）；
- 生产模式不监听源码变化，性能与稳定性更好，适合"长期开着一台服务"的本机使用；
- **`SKIP_FRONTEND_BUILD=1`** 复用已存在的 `.next` 构建目录，走 `next start` 而不是重新
  `next build`（`Makefile:159` 注释与 `scripts/serve.sh:15`：opt-in，没有历史构建时
  直接失败）。

### `make start-daemon`

```bash
make start-daemon    # Makefile:172（dev 版本：make dev-daemon，Makefile:166）
```

后台（daemon）模式：`serve.sh --prod --daemon` 用 nohup 把服务放到后台并立即返回终端
（`scripts/serve.sh:11`）。日志依旧写 `logs/gateway.log` / `logs/frontend.log`，
`make stop` 统一停止。

### 本地模式的补充命令

- `make nginx`（`Makefile:176`）：只在前台启动 nginx（本地 dev 配置），调试代理规则时用；
- `make dev-multi`（`Makefile:184`）：在本地用 Docker 里的 Postgres + Redis 拉起
  **两个 Gateway 组成多实例集群**（配合第 20 章的多实例主题），`make dev-multi-check`
  跑跨实例检查，`make dev-multi-down` 清理。

---

## 5.2 Docker 开发栈：`make docker-start`

```bash
make docker-init    # Makefile:208 — 预拉沙箱镜像（首次或镜像更新时）
make docker-start   # Makefile:212 — 模式感知启动（从 config.yaml 自动检测沙箱模式）
make docker-logs    # Makefile:220 — 跟随日志
make docker-stop    # Makefile:216
```

特点（对应 `README.md:620`："Development (hot-reload, source mounts)"）：

- **源码挂载**：Compose 文件 `docker/docker-compose-dev.yaml`（`scripts/docker.sh:18`
  固定使用它，项目名 `deer-flow-dev`）把仓库源码 bind-mount 进容器，改代码即时生效——
  体验等同 `make dev`，但环境（Python/Node/nginx）完全容器化；
- **免装本机依赖**：本机只需要 Docker，不需要 Node/Python/nginx
  （`CONTRIBUTING.md:11`）；
- **沙箱模式感知**：`make docker-start` 只有在 `config.yaml` 配置了 provisioner 模式时
  才会启动 `provisioner` 服务（`README.md:627`）；
- 分服务看日志：`make docker-logs-frontend` / `docker-logs-gateway` /
  `docker-logs-redis`（`Makefile:224`）。

版本要求：Docker Compose **v2.24+**（`docker compose version` 自查），旧客户端无法解析
Compose 文件里的可选 `env_file` 语法（`README.md:612`）。

---

## 5.3 Docker 生产栈：`make up` / `make down`

```bash
make up        # Makefile:236 — 构建并启动生产栈（浏览器入口 localhost:2026）
make prod-logs # Makefile:244 — 跟随生产栈日志
make down      # Makefile:240 — 停止并移除容器
```

### 与开发栈的本质区别

| | Docker Dev（`docker-start`） | Docker Prod（`up`） |
| --- | --- | --- |
| Compose 文件 | `docker/docker-compose-dev.yaml` | `docker/docker-compose.yaml` |
| 镜像 | 复用基础镜像 + 源码挂载 | 现场构建应用镜像 |
| 代码变更 | 即时生效（挂载） | 需重新 `make up` 构建 |
| 就绪策略 | 常规启动 | `--wait` 等待健康检查（见下） |

### `/health` 就绪等待

生产栈启动脚本 `scripts/deploy.sh` 用 Compose 的 `--wait` 等待健康检查通过
（`scripts/deploy.sh:514`）：

```bash
if ! "${COMPOSE_CMD[@]}" up -d --remove-orphans --wait --wait-timeout 180 $services; then
```

即 `make up` 会阻塞直到 Gateway 的 `/health` 就绪（最长 180 秒）；失败时输出 Compose
状态与 Gateway 日志（根 `AGENTS.md`："make up waits for Gateway /health; failures show
Compose status and Gateway logs"）。

### docker/ 目录地图

```text
docker/
├── docker-compose.yaml          # 生产栈
├── docker-compose-dev.yaml      # 开发栈
├── docker-compose.dood.yaml     # opt-in：aio 沙箱模式挂载 Docker socket（DooD）
├── docker-compose.cli-auth.yaml # opt-in：CLI 订阅登录的目录挂载回退
├── docker-compose.openviking.yaml
├── nginx/                       # nginx.conf（2026 default_server IPv4+IPv6）与本地版
├── provisioner/                 # 8002 沙箱 provisioner（K8s 模式专用）
└── sandbox-network-proxy/       # 沙箱出网 allowlist 代理镜像
```

两个安全相关的事实必须记住：

1. **发布端口默认回环**：生产 Compose 把 nginx 发布为
   `"${BIND_HOST:-127.0.0.1}:${PORT:-2026}:2026"`，Gateway 的 8001 **从不发布**
   （`docs/ARCHITECTURE.md:44`；测试钉住：`backend/tests/test_compose_default_bind_host.py`）。
   跨机访问需设 `BIND_HOST=0.0.0.0`，并先完成首次初始化与安全加固（`README.md:4188`）；
2. **配置文件挂载方式不同**：生产 Compose 中 `extensions_config.json` 以**读写**挂载
   （Web 界面要热改 MCP/技能），而 `config.yaml` 保持只读（`backend/AGENTS.md:22`）。

另有一个构建期注意事项：镜像用 `uv sync --locked` 安装且 `uv.lock` 锁定官方 PyPI 索引，
`UV_INDEX_URL` 指向镜像源会让构建直接失败（`README.md:633`）；前端 npm 镜像则由独立的
`NPM_REGISTRY` 控制，互不影响。

---

## 5.4 Helm 部署概览

Kubernetes 部署入口在 `deploy/helm/deer-flow/`：

```text
deploy/helm/deer-flow/
├── Chart.yaml     # chart 版本（与仓库版本锁步）
├── values.yaml    # 默认值
├── templates/     # Deployment/Service/Ingress 等
└── README.md
```

教程视角只需要记住两个特征：

- **配置注入方式**：Gateway 在容器里需要对 `extensions_config.json` 有写权限（Web 端
  热改 MCP/技能），但 ConfigMap 天然只读。Helm 的解法是把配置"播种"到**可写的 home 卷
  副本**再让 Gateway 使用副本（`backend/AGENTS.md:22`："Helm seeds a writable
  home-volume copy"）；
- **版本锁步**：`Chart.yaml` 的 `version`/`appVersion` 必须与 `backend/pyproject.toml`、
  `backend/packages/harness/pyproject.toml`、`frontend/package.json` 保持一致，`v*` tag
  的 CI 会阻断漂移（根 `AGENTS.md` 的 Version lockstep 一节；第 20 章展开）。

---

## 5.5 模式对比表与选型

权威表格在 `backend/AGENTS.md:237`，加上停止/重启命令（`backend/AGENTS.md:242`）整理如下：

| | Local Foreground | Local Daemon | Docker Dev | Docker Prod |
|---|---|---|---|---|
| **Dev** | `./scripts/serve.sh --dev`<br>`make dev` | `./scripts/serve.sh --dev --daemon`<br>`make dev-daemon` | `./scripts/docker.sh start`<br>`make docker-start` | — |
| **Prod** | `./scripts/serve.sh --prod`<br>`make start` | `./scripts/serve.sh --prod --daemon`<br>`make start-daemon` | — | `./scripts/deploy.sh`<br>`make up` |
| 停止 | `make stop` | `make stop` | `make docker-stop` | `make down` |
| 日志 | `logs/*.log` | `logs/*.log` | `make docker-logs` | `make prod-logs` |

### 选型速查

- **第一次跑通 / 改后端代码** → `make dev`（热重载 + 本地日志最好排障）；
- **本机长期自用、不想开热重载** → `make start`（改前端后用 `SKIP_FRONTEND_BUILD=1`
  快速重启）；
- **本机没装 Node/Python，或想复现干净环境** → `make docker-start`；
- **给团队/一台服务器提供稳定服务** → `make up`（配合 `BIND_HOST` 与安全加固）；
- **K8s 集群 / 多副本** → Helm（第 20 章）。

资源规模参考（`README.md:597`）：本地评估 4 vCPU / 8 GB 起步；Docker 开发同级别；
`make up` 长期服务建议 8 vCPU / 16 GB 起步。

---

## 动手实验 5-1：`make dev` vs `make up` 对照跑

目标：亲眼看清"同一套系统在不同封装下的进程结构与日志位置"。

**A 部分：本地前台**

```bash
make dev
# 观察终端：三段输出（Gateway / 前端 / nginx），Ctrl+C 逐个退出
```

记录：本机出现了哪些进程（可用 `ps` / 任务管理器看 `uvicorn`、`next`、`nginx`）；
`logs/gateway.log` 与 `logs/frontend.log` 是否滚动；`make stop` 后端口是否释放。

**B 部分：Docker 生产栈**（需要 Docker Desktop / Engine，Compose v2.24+）

```bash
make up          # 构建镜像 + 启动 + --wait 等待 /health（首次构建较久）
make prod-logs   # 另开终端跟随日志
docker compose -f docker/docker-compose.yaml ps   # 观察容器清单
```

记录：

- 容器列表与 `make dev` 的本机进程列表的对应关系（nginx / gateway / frontend，
  以及按配置出现的 provisioner）；
- 浏览器访问 `http://localhost:2026` 的体验是否与 A 部分完全一致；
- `docker volume ls` 里生产栈创建的数据卷——本地模式的 `backend/.deer-flow` 数据
  在容器里去了哪里；
- 结束后 `make down`，确认容器全部移除。

**对照结论（写进你的笔记）**：两种模式下，浏览器看到的都是同一个 `2026` 入口；
差别只在封装层——进程边界、日志出口、数据卷位置与变更生效方式（挂载即时 vs 重建镜像）。

---

## 常见坑

1. **`make up` 构建失败提示 lockfile**：给 `UV_INDEX_URL` 配了国内镜像源导致
   `uv sync --locked` 校验失败（`README.md:633`）；生产镜像构建保持官方 PyPI 索引，
   npm 镜像用 `NPM_REGISTRY` 单独控制。
2. **Docker 模式访问 Ollama 失败**：容器里的 `localhost` 是容器自己；模型服务地址要用
   `host.docker.internal`（`config.example.yaml:368`）。
3. **`make up` 卡住 180 秒后失败**：Gateway 未通过健康检查——用
   `make prod-logs`（或 `docker compose logs gateway`）看真实报错，常见是
   `config.yaml` 错误或模型 Key 缺失。
4. **混淆两种 Docker 栈的停止命令**：开发栈用 `make docker-stop`，生产栈用
   `make down`；交叉使用会出现"停不掉"的错觉。
5. **`SKIP_FRONTEND_BUILD=1` 报错**：该开关只复用已存在的 `.next` 构建，没有历史构建时
   会失败（`scripts/serve.sh:17`）——先跑一次不带开关的 `make start`。
6. **直接改 Compose 里 Gateway 的端口映射**：`8001` 永不发布是安全约束（CI 测试钉住
   `backend/tests/test_compose_default_bind_host.py`）；对外暴露统一走 nginx 的
   `BIND_HOST`。
7. **改了源码但 `make up` 的站点没变化**：生产栈不挂载源码，变更需要重新 `make up`
   重建镜像；想即时生效请用 `make dev` 或 `make docker-start`。
8. **生产栈里改不动 MCP/技能配置**：这是设计行为——`config.yaml` 只读挂载，
   `extensions_config.json` 才是读写挂载（`backend/AGENTS.md:22`）。

---

## 下一步

至此入门篇完结：你已经能装环境、一键启动、读懂配置、走遍界面、按场景切换运行方式。
第二篇将进入核心组件拆解——从《第 6 章 一次请求的一生：Agent 运行时全链路》开始，
沿 SSE 事件流把 Gateway 内部（`RunManager`、中间件链、ThreadState、checkpoint）逐层
打开，见第二篇对应章节。
