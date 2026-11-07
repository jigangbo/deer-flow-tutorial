# 第 1 章 准备环境（Environment Setup）

## 1.0 学习目标

读完本章，你应该能够：

1. 对照清单确认本机满足 DeerFlow 的系统要求（Python 3.12+、Node 22+、pnpm 10.26.2+、uv、
   Make，以及可选的 Docker / nginx），并了解 Windows / macOS / Linux 的差异；
2. 克隆仓库后独立看懂根目录结构导览，知道每个顶层目录的职责；
3. 在 `config.example.yaml → models:` 与 `.env.example` 中定位模型 API Key 的配置方式，
   理解 `supports_vision`、`supports_thinking` 等模型能力位的作用；
4. 跑通 `make check`（工具链检查）与 `make doctor`（配置 + 系统诊断），读懂输出并修复
   第一处环境问题。

## 本章源码锚点

| 主题 | 锚点 |
| --- | --- |
| 工具链检查脚本 | `scripts/check.py` |
| 配置诊断脚本 | `scripts/doctor.py` |
| 交互式安装向导 | `scripts/setup_wizard.py`（经 `Makefile:72` 的 `make setup` 调用） |
| Windows 兼容层 | `Makefile:9`（OS 分支）、`Makefile:22`（pnpm 运行器） |
| 系统要求 | `backend/pyproject.toml:6`、`frontend/package.json:133`、`CONTRIBUTING.md:192` |
| 模型配置样例 | `config.example.yaml:157` |
| 环境变量样例 | `.env.example` |
| 后端配置解析 | `backend/docs/SETUP.md`、`backend/docs/CONFIGURATION.md:2153` |

---

## 1.1 系统要求

### 版本清单

DeerFlow 由 Python 后端与 Node 前端组成，硬性版本要求来自源码：

- **Python 3.12+**：`backend/pyproject.toml:6` 声明 `requires-python = ">=3.12"`（harness 包
  同样要求，见 `backend/packages/harness/pyproject.toml:5`）；
- **Node.js 22+**：`frontend/AGENTS.md:9` 明确 "Requires Node.js 22+ and pnpm 10.26.2+"，
  `scripts/check.py` 会解析 `node -v` 的主版本号并强制 `major >= 22`；
- **pnpm 10.26.2+**：`frontend/package.json:133` 用 `packageManager` 字段锁定了
  `pnpm@10.26.2`；
- **uv**：Python 包管理器，后端所有命令都经 `uv run` 执行（`backend/Makefile:10`）；
- **Make**：根编排入口（Windows 用户见下文的 Git Bash 方案）；
- **Docker**（可选但推荐）：用于 Docker 运行模式与容器沙箱；生产 Compose 需要
  Docker Compose v2.24+（`README.md:612`）；
- **nginx**（本地模式必需，Docker 模式不需要）：`make dev` 会在本机直接拉起 nginx 作为入口。

### 操作系统差异

**Windows**：仓库根 `Makefile:9` 有一段专门的 OS 分支：

```makefile
ifeq ($(OS),Windows_NT)
    SHELL := cmd.exe
    PYTHON ?= python
    # Run repo shell scripts through Git Bash when Make is launched from cmd.exe / PowerShell.
    RUN_SHELL_SCRIPT = call scripts\run-with-git-bash.cmd
else
    PYTHON ?= python3
    RUN_SHELL_SCRIPT = $(BASH)
endif
```

也就是说，Windows 下所有 shell 脚本（`scripts/serve.sh` 等）会经由 `scripts/run-with-git-bash.cmd`
转交给 Git Bash 执行——**安装 Git for Windows 是 Windows 本地模式的前置条件**。
另外两点 Windows 特有约定：

- pnpm 调用统一走 `scripts/pnpm.py` 运行器（`Makefile:22`）：Windows 上先试 `pnpm.cmd`
  再回退 Corepack，POSIX 反序（根 `AGENTS.md` "Commands" 一节）；
- `scripts/check.py` 在缺少 nginx 时给出的提示是 "Windows: use WSL for local mode or use
  Docker mode"——本地模式在 Windows 上走 WSL 或 Git Bash 环境，Docker 模式则完全绕开。

**macOS / Linux**：直接使用 `python3`、`brew install nginx`（macOS）或
`sudo apt install nginx`（Ubuntu）即可，`scripts/check.py` 的失败提示里给了准确命令。

**磁盘与内存**：`README.md:597` 给出了部署规模参考——本地评估 `make dev` 建议 4 vCPU / 8 GB
内存起步（2 vCPU / 4 GB 通常不够），Docker 开发建议再加 25 GB 空闲 SSD。

---

## 1.2 获取代码与根目录导览

### 克隆仓库

```bash
git clone https://github.com/bytedance/deer-flow.git
cd deer-flow
```

`Install.md:38` 的官方流程是：确认当前目录是仓库根（存在 `Makefile`、`backend/`、
`frontend/`、`config.example.yaml`），之后再做配置与安装。

### 根目录结构导览

对照根 `AGENTS.md` 的 Repository Map 一节，逐个目录过一遍（建议用 `ls` 实际看一遍）：

```text
deer-flow/
├── Makefile                        # 根编排：dev/start/stop、docker、extension-*、doctor
├── config.example.yaml             # 配置模板 → 复制为 gitignored 的 config.yaml
├── extensions_config.example.json  # 扩展配置模板（MCP 服务器 + 技能）
├── backend/                        # Python 后端
│   ├── Makefile                    # 后端模块命令（dev/gateway/test/lint/migrate-rev）
│   ├── app/                        # FastAPI Gateway + IM 渠道（import 前缀 app.*）
│   └── packages/
│       ├── harness/                # deerflow-harness 包（import 前缀 deerflow.*）
│       └── extension-api/          # 扩展公开契约包
├── frontend/                       # Next.js 前端（pnpm）
├── docker/                         # compose 文件、nginx 配置、provisioner
├── skills/                         # Agent 技能：public/（入库）+ custom/（gitignored）
├── contracts/                      # 跨组件 JSON 契约（subagent 状态、技能评审等）
├── examples/                       # 扩展示例：deerflow-extension-{example,bookmarks,...}
├── scripts/                        # 根编排脚本（check/doctor/serve/docker/deploy/...）
├── tests/                          # 根级测试（tests/skills/ 公共技能测试）
├── deploy/helm/deer-flow/          # Helm Chart（生产 K8s 部署）
└── docs/                           # 跨组件文档（含本教程）
```

三个"不要动"的目录现在就记住：`config.yaml` / `extensions_config.json`（运行时生成，
gitignored）、`backend/.deer-flow/`（运行时数据目录，默认 `DEER_FLOW_HOME`，
见 `backend/Makefile:1`）。

---

## 1.3 模型 API Key 准备

DeerFlow 的模型供应商配置全部集中在 `config.yaml → models:` 段（模板在
`config.example.yaml:157`）。每个条目是一个 LangChain 模型类路径 + 供应商参数的组合。
官方样例（`backend/docs/CONFIGURATION.md:164`）：

```yaml
models:
  - name: gpt-4                    # Internal identifier
    display_name: GPT-4            # Human-readable name
    use: langchain_openai:ChatOpenAI  # LangChain class path
    model: gpt-4                   # Model identifier for API
    api_key: $OPENAI_API_KEY       # API key (use env var)
    max_tokens: 4096               # Max tokens per request
    temperature: 0.7               # Sampling temperature
```

三个关键约定：

1. **`use:` 是类路径**，格式为 `package.module:class`（`config.example.yaml:16`）。
   支持 OpenAI、Anthropic、DeepSeek、小米 MiMo、Claude Code OAuth、Codex CLI 以及任意
   LangChain 兼容供应商（`backend/docs/CONFIGURATION.md:174`）；
2. **密钥用 `$ENV_VAR` 引用**（`config.example.yaml:15`："Environment variables are
   available for all field values. Example: `api_key: $OPENAI_API_KEY`"），
   环境变量本身放在根目录 `.env` 里（模板 `.env.example`）；
3. **国产模型的典型写法**——例如火山方舟 Doubao（`config.example.yaml:158`）：

```yaml
  - name: doubao-seed-1.8
    display_name: Doubao-Seed-1.8
    aliases: [doubao, seed 1.8]  # Optional names for selecting this model in chat
    use: deerflow.models.patched_deepseek:PatchedChatDeepSeek
    model: doubao-seed-1-8-251228
    api_base: https://ark.cn-beijing.volces.com/api/v3
    api_key: $VOLCENGINE_API_KEY
    timeout: 600.0
    max_retries: 2
    context_window: 262144     # Total prompt + completion capacity
    supports_thinking: true
    supports_vision: true
    supports_reasoning_effort: true
```

### 模型能力位

模型条目上的布尔"能力位"决定了运行时中间件的行为（详见 `config.example.yaml:131` 起的
注释块）：

- `supports_vision: true`：启用 `ViewImageMiddleware` 的图片理解能力
  （`backend/AGENTS.md:314`）；
- `supports_thinking` / `supports_reasoning_effort`：声明思考/推理力度开关是否存在；
- `context_window`：总上下文容量，驱动聊天 UI 的"% context used"指示器，也供按比例触发的
  自动摘要使用（`config.example.yaml:133`）。

### `.env.example` 里的密钥地图

`.env` 承载所有密钥类环境变量（模板 `.env.example`，163 行）。按用途分组的核心变量：

| 用途 | 变量（行号在 `.env.example`） |
| --- | --- |
| 网络搜索 | `SERPER_API_KEY`（:1）、`TAVILY_API_KEY`、`EXA_API_KEY`、`JINA_API_KEY` 等 |
| 主流模型 | `OPENAI_API_KEY`（:69）、`GEMINI_API_KEY`、`DEEPSEEK_API_KEY`、`VOLCENGINE_API_KEY` 等（:66 起） |
| 沙箱（E2B 云沙箱才需要） | `E2B_API_KEY`（:91） |
| IM 渠道 | `FEISHU_APP_ID`/`FEISHU_APP_SECRET`（:92）、`SLACK_BOT_TOKEN`（:95）、`TELEGRAM_BOT_TOKEN`、`DISCORD_BOT_TOKEN` |
| 可观测性 | `LANGSMITH_TRACING` 等（:101） |
| 数据库（Postgres 模式） | `DATABASE_URL`（:110） |
| 部署绑定 | `BIND_HOST`（:52）、`PORT`（:53）、`DEER_FLOW_GATEWAY_STARTUP_TIMEOUT`（:42） |

注意：**`models:` 段里的 `api_key` 引用哪个变量名，取决于你抄的是哪个供应商样例**——
没有任何一个 Key 是"必填全家桶"，只配一条模型 + 对应一个 Key 就能跑起来。

---

## 1.4 体检命令：`make check` 与 `make doctor`

仓库提供两级体检，职责不同：

### `make check` —— 只查工具链

定义在 `Makefile:97`，调用 `scripts/check.py`（一个跨平台依赖检查器）。它依次检查
（`scripts/check.py:89` 起的 `main()`）：

```text
Checking Node.js...     # 解析 node -v，主版本 >= 22 才 OK
Checking pnpm...        # 经 scripts/pnpm.py 运行器取版本（可能走 Corepack）
Checking uv...          # shutil.which("uv") + uv --version
Checking nginx...       # shutil.which("nginx")
```

任一必需项缺失即失败，并打印平台对应的安装提示（例如 nginx 缺失时提示
"macOS: brew install nginx / Ubuntu: sudo apt install nginx / Windows: use WSL for local
mode or use Docker mode"）。`make dev` 和 `make start` 在启动前也会自动跑一遍它
（`Makefile:156`、`Makefile:163`）。

### `make doctor` —— 查配置 + 系统要求

定义在 `Makefile:75`，调用 `scripts/doctor.py`。脚本头部自述（`scripts/doctor.py:4`）：

```python
"""DeerFlow Health Check (make doctor).

Checks system requirements, configuration, LLM provider, and optional
components, then prints an actionable report.

Exit codes:
  0 — all required checks passed (warnings allowed)
  1 — one or more required checks failed
"""
```

它比 `check.py` 深一层：会实际加载 `config.yaml`、验证模型配置可解析、检查可选组件。
支持 `--json` 输出（argparse 定义），适合脚本化采集。

### 两者的分工记忆法

- `check`：**装没装**——工具在不在 PATH 里、版本够不够；
- `doctor`：**配没配对**——配置文件能不能加载、模型供应商通不通。

---

## 动手实验 1-1：完成第一次环境体检

目标：跑通 `make check` 与 `make doctor`，读懂输出，修复第一处环境问题。

```bash
# 1. 工具链检查（此时还没有 config.yaml 也照样能跑）
make check
```

观察输出：每一项前缀 `OK` / `FAIL` / `INFO`。若全部 `OK`，记录 Node/pnpm/uv 的版本号并与
1.1 节的最低要求对照。

```bash
# 2. 若你还没有配置文件，先生成（不会覆盖已有配置）
make config
```

`make config` 调用 `scripts/configure.py`（`Makefile:88`），逻辑是 `copy_if_missing`——
把 `config.example.yaml` → `config.yaml`、`extensions_config.example.json` →
`extensions_config.json`，已存在则跳过（`scripts/configure.py:12`）。

```bash
# 3. 配置诊断
make doctor
```

第一次运行大概率会有一条"模型未配置/供应商不可用"级别的提示，因为 `config.yaml` 里的
`models:` 默认是注释样例。按第 1.3 节挑一个你有 Key 的供应商，把对应样例取消注释、
在 `.env` 写入真实 Key，然后重跑 `make doctor`，直到必需项全部通过（退出码 0）。

自查清单：

- [ ] `make check` 四项全绿（或明确知道哪项为什么可以缺）；
- [ ] `config.yaml` 与 `extensions_config.json` 已生成且 `git status` 看不到它们（被
      gitignore）；
- [ ] `make doctor` 退出码为 0，报告里模型部分无 FAIL。

---

## 常见坑

1. **Windows 上 make 报"找不到 bash / 脚本跑不起来"**：根 `Makefile` 依赖 Git Bash 执行
   shell 脚本（`Makefile:13` 的 `run-with-git-bash.cmd`），先装 Git for Windows 并保证
   `bash` 在 PATH 里；不想折腾就直接用 Docker 模式。
2. **Node 版本 18/20 就开跑**：`scripts/check.py` 强制主版本 ≥ 22；用 nvm/conda 装一个
   Node 22 再继续，否则 `make dev` 会在预检阶段被拦下。
3. **pnpm 版本不对或没有 pnpm**：不要手工全局装错版本——仓库通过 `frontend/package.json`
   的 `packageManager: pnpm@10.26.2` 与 `scripts/pnpm.py` 运行器管理版本（含 Corepack
   回退），直接依赖 `make install` 即可。
4. **把 API Key 写进 `config.yaml` 明文**：模板约定用 `$ENV_VAR` 引用（如
   `api_key: $OPENAI_API_KEY`），真实值放 `.env`；`config.yaml` 虽然被 gitignore，
   但明文密钥会经 Gateway API 暴露给有权限的读取方。
5. **没配任何模型就点"启动"**：`models:` 段为空时 Gateway 可以起，但对话立刻失败；
   `make doctor` 会在启动前把这类问题暴露出来——先体检再启动。
6. **在仓库里找 `config.yaml` 却找不到**：它由 `make config` 从模板生成且 gitignored
   （`backend/docs/SETUP.md:46`），克隆下来的仓库里天然没有，这不是 bug。

---

## 下一步

工具链就绪、配置体检通过后，下一章《第 2 章 一键启动》用 `make config` → `make install`
→ `make dev` 三步把全栈跑起来，并完成第一次"上传文件 → 生成产物"的对话——见
`02-quickstart.md`。
