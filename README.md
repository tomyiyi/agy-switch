# ⚡ AGY Switch

> 专为 **macOS + Antigravity** 打造的原生多账号隔离池管理与**一键跨账号工作接力**工具。
> 零第三方依赖（SwiftUI 原生桌面端 + Python 3 标准库后端），低内存、无浏览器外壳、不触碰私有 OAuth 凭据。

![Version](https://img.shields.io/badge/version-v4.0.0-111827?style=flat-square)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-0071E3?style=flat-square)
![Stack](https://img.shields.io/badge/stack-SwiftUI%20%2B%20Python%203-10B981?style=flat-square)

## 核心能力（v4.0）

- **总览（Dashboard）**：
  - Apple 冷灰三层通透视觉体系，支持 **跟随系统 / 浅色 / 深色** 外观切换。
  - 实时识别当前运行账号与 PID、本地统计近 `5h / 7d` 对话轮数与最近活跃时间，**拒绝虚假云端百分比**。
  - 首页 **3 步无缝接力引导条** + **低余量主动预警**（自定义阈值，默认 ≤ 15%，弹窗横幅 + macOS 系统通知）。
- **账号池（Accounts）**：
  - 支持 **网格 / 紧凑 / 列表** 三种视图布局自由切换，按状态与关键字实时筛选。
  - 完整生命周期管理：**新增隔离账号**（自动建独立 HOME + 软链公共 Skills + 生成桌面 `.app` 启动器）、**安全删除**（移入 `~/.Trash` 防误删）、**家庭组/自定义备注**、**一键解除全部冷却**。
  - 真实登录态检测（基于 `.gemini/jetski-standalone-oauth-token` 自动识别 `已登录` / `待登录` / `冷却中` / `运行中`）。
- **交接中心（Handoff）**：
  - 提取任意历史会话 + 当前目录 `git status` +「给下一个号的特别交代」，实时预览并生成 `HANDOFF_AUTO.md`，接力词自动写入剪贴板。
  - 内置 `.handoff_history/` **历史交接单归档时间轴**（自动保留最近 10 份）与一键恢复。
- **运行体检（Doctor）**：
  - 6 项本地环境自检（单实例防冲突、启动器完整性、Skills 软链、brain 日志隔离、`HANDOFF_AUTO.md`、`agy-relay`）。
- **通用设置（Settings） & 关于（About）**：
  - 原生文件夹选择器 + **多工作区快捷切换列表**、LaunchAgent **开机自启开关**、外观主题与低额度预警线配置。
  - 独立「关于」页面，直达 GitHub 仓库、版本更新日志与 Star 入口。

## 安全切号原理（防串号 + 不丢上下文）

```text
点击「一键接力」
  ├─ 1. 提取当前最新会话 + git status → 写入工作区 HANDOFF_AUTO.md（并自动归档到 .handoff_history/）
  ├─ 2. 接力提示词写入剪贴板，标记旧账号进入 5h 冷却
  ├─ 3. 发送优雅退出信号 (osascript quit)，每 0.25s 轮询确认旧进程彻底退出（最长 6s）
  └─ 4. 拉起目标隔离账号 .app，弹出系统通知（新窗口 Cmd+V 即可继续）
```

> **安全边界**：本工具仅读取本地目录与进程状态，**绝不提取 Google OAuth `refresh_token`，绝不调用任何私有/未公开云端额度接口**。

## 快速构建与安装（macOS Apple Silicon / Intel）

前置依赖：macOS 系统自带 `swiftc`（Command Line Tools）与 `python3`。

```bash
chmod +x build.sh
./build.sh
```

脚本会自动生成 1024px 视网膜图标 `AppIcon.icns`、将 `server.py` 打包进 `.app/Contents/Resources/`、编译原生二进制、安装到 `/Applications/AGY Switch.app` 并启动。

## 目录结构

```text
agy-switch/
├── build.sh              # 一键生成图标、编译并安装到 /Applications
├── server.py             # Python 3 标准库核心引擎（账号扫描、切号编排、体检、交接单）
├── macos/
│   ├── AgySwitch.swift   # 原生 SwiftUI 桌面端（NavigationSplitView 六栏架构）
│   └── make_icon.swift   # CoreGraphics 矢量视网膜图标生成器
├── CHANGELOG.md          # 版本更新日志
└── README.md
```

## 版本演进

- [x] **v1.0 ~ v1.6** 原生 SwiftUI 侧边栏架构、轮询安全退出防串号、6 项运行体检、账号池增删改备注、LaunchAgent 开机自启
- [x] **v2.0 ~ v2.1** 3 层表面深度视觉重塑、全局 Telemetry 汇总条、一键解除全部冷却
- [x] **v3.0 ~ v3.4** Apple 冷灰通透风、交接历史归档恢复、多工作区快捷切换、≤ 15% 低额度双重预警、明暗主题切换与「关于」页面
- [x] **v4.0** 真实数据卡片重构（移除虚假云端百分比，展示真实登录态、5h/7d 本地轮数与家庭组备注）、网格/紧凑/列表三视图切换

完整变更记录见 [CHANGELOG.md](./CHANGELOG.md)。
