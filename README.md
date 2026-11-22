# ⚡ AGY Switch

> 专为 **macOS + Antigravity** 打造的原生多账号隔离池管理与**一键跨账号工作接力**工具。
> 零第三方依赖（SwiftUI 原生桌面端 + Python 3 标准库后端），低内存、无浏览器外壳、不触碰私有 OAuth 凭据。

## 核心能力

- **总览（Dashboard）**：顶部 Hero 卡片实时识别当前运行账号与 PID、5h 滚动重置倒计时、支持**校准真实剩余额度**并随对话自动递减，一键接力到最空闲的满血号。
- **账号池（Accounts）**：
  - 完整生命周期管理：**新增隔离账号**（自动建独立 HOME + 软链公共 Skills + 生成桌面 `.app` 启动器）、**安全删除**（移入 `~/.Trash` 防误删）、**加备注**、按状态与关键字实时筛选。
  - 自动检测登录态（`待登录` / `满血` / `冷却中` / `运行中`）。
- **交接中心（Handoff）**：支持选择任意历史会话、附带「给下一个号的特别交代」与当前目录 `git status`，实时预览并生成 `HANDOFF_AUTO.md`，接力词自动写入剪贴板。
- **运行体检（Doctor）**：6 项本地环境自检（单实例防冲突、启动器完整性、Skills 软链、brain 日志隔离、`HANDOFF_AUTO.md`、`agy-relay`）。
- **设置（Settings）**：原生文件夹选择器切换接力工作区、自定义 5h / 7d 预警参考线。

## 安全切号原理（防串号 + 不丢上下文）

```text
点击「一键接力」
  ├─ 1. 提取当前最新会话 + git status → 写入工作区 HANDOFF_AUTO.md
  ├─ 2. 接力提示词写入剪贴板，标记旧账号进入 5h 冷却
  ├─ 3. 发送优雅退出信号 (osascript quit)，每 0.25s 轮询确认旧进程彻底退出
  └─ 4. 拉起目标隔离账号 .app，弹出系统通知（新窗口 Cmd+V 即可继续）
```

## 快速构建与安装（macOS Apple Silicon / Intel）

前置依赖：macOS 系统自带 `swiftc`（Command Line Tools）与 `python3`。

```bash
chmod +x build.sh
./build.sh
```

脚本会自动生成视网膜图标 `AppIcon.icns`、编译原生二进制、安装到 `/Applications/AGY Switch.app` 并启动。

## 目录结构

```text
agy-switch/
├── build.sh              # 一键生成图标、编译并安装到 /Applications
├── server.py             # Python 3 标准库核心引擎（账号扫描、切号编排、体检、交接单）
├── macos/
│   ├── AgySwitch.swift   # 原生 SwiftUI 桌面端（NavigationSplitView 五栏架构）
│   └── make_icon.swift   # CoreGraphics 矢量视网膜图标生成器
├── index.html            # （可选）轻量本地 Web 控制台
└── README.md
```

## Roadmap

- [x] v1.0 原生 SwiftUI 侧边栏架构 + Hero 卡片 + 交接预览
- [x] v1.1 轮询安全退出等待机制 + PID 徽章 + 剩余电量条
- [x] v1.2 6 项本地运行环境体检（Doctor）
- [x] v1.3 账号池增删改备注 + 登录态自动检测
- [x] v1.4/1.5 刷新反馈 + 真实额度校准 + 一键构建脚本
- [ ] v1.6 菜单栏快捷切号下拉菜单 + 开机自启开关
- [ ] v1.7 跨工作区项目列表（支持为不同项目分别维护交接单）
