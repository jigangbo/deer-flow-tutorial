# DeerFlow 从入门到精通 · 源码教程

一套基于 [**bytedance/deer-flow**](https://github.com/bytedance/deer-flow)（DeerFlow 开源项目）
真实源码编写的中文系统教程：**21 章 + 附录**，引用源码位置 1200+ 处（`相对路径:行号`）。

> 📖 **在线阅读**：<https://jigangbo.github.io/deer-flow-tutorial/>
>
> 🔗 源码仓库：[bytedance/deer-flow](https://github.com/bytedance/deer-flow)
> —— 本仓库是教程的独立发布仓，与源码仓库**仅建立链接关系**（非 fork）；
> 教程正文在源码仓库 `docs/tutorials/` 中创作，经 `sync.sh` 同步至本仓库发布。

## 教程结构

| 篇 | 章节 |
| --- | --- |
| 导读 | 第 0 章 全景鸟瞰 |
| 第一篇 入门篇（环境配置与一键运行） | 第 1–5 章：准备环境 · 一键启动 · 配置系统 · 前端导览 · 运行方式 |
| 第二篇 进阶篇（核心组件拆解） | 第 6–13 章：请求生命周期 ★ · 工具与 Skills ★ · 沙箱 ★ · Multi-Agent ★ · 记忆 · 上下文工程 · 定时任务与 IM · Gateway API |
| 第三篇 精通篇（二次开发与 MCP 集成） | 第 14–20 章：架构分层 · MCP 集成 ★ · 扩展开发 ★ · 业务实战 ★ · 前端开发 · 测试与质量 · 生产部署 |
| 附录 | A 命令速查 · B 配置速查 · C 术语表 · D 验收清单 · E FAQ · F 官方文档映射 |

每章固定骨架：**学习目标 → 概念讲解 → 源码走读 → 动手实验 → 常见坑**。

## 本地构建

```bash
pip install mkdocs mkdocs-material mkdocs-awesome-pages-plugin jieba
mkdocs serve     # http://127.0.0.1:8000 预览
mkdocs build     # 产物输出到 site/
```

## 从创作仓库同步内容

教程正文的创作与评审发生在源码仓库 `deer-flow/docs/tutorials/`；更新后同步过来：

```bash
./sync.sh                          # 默认读取 ../deer-flow/docs/tutorials
./sync.sh /path/to/deer-flow/docs/tutorials
```

同步后检查 `git diff`，提交推送即可 —— GitHub Actions 会自动重建并发布到 Pages。

## 仓库说明

- `mkdocs.yml` — Material 主题（中文搜索、明暗切换、代码复制）
- `docs/` — 教程正文（`index.md` 首页含架构图 / 主流程图 / 代码-流程映射表）
- `TUTORIAL_OUTLINE.md` — 教程大纲定稿
- `sync.sh` — 从创作仓库同步脚本
- `.github/workflows/deploy-docs.yml` — 推送自动部署
