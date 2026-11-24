# ⚡ AGY Switch

> 专为 **macOS + Antigravity** 打造的原生多账号隔离池管理与**跨家庭组智能工作接力**工具。
> 零第三方依赖（模块化 SwiftUI 原生桌面端 + Python 3 标准库后端），低内存、无浏览器外壳、严守本地只读安全边界。

![Version](https://img.shields.io/badge/version-v5.0.0-111827?style=flat-square)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-0071E3?style=flat-square)
![Stack](https://img.shields.io/badge/stack-SwiftUI%20%2B%20Python%203-10B981?style=flat-square)

## 核心能力（v5.0）

- **跨家庭组智能接力引擎**：
  - 自动识别 `A–F` 家庭组与独享状态；点击「一键跨组接力」自动遵循 **避开当前家庭组 → 独享组优先 → 5h/7d 最空闲优先**，自动跳过待二次验证/异常标记账号。
- **顶部菜单栏 `⚡` 原生快捷控制台**：
  - 无需切出编码窗口，点击菜单栏 `⚡` 即可查看当前运行账号、按 `⌘R` 一键跨组接力、指定满血号切换或一键生成交接单。
- **账号池（家庭组折叠 + 主子账号强视觉区分 + 三视图）**：
  - 按家庭组分区（支持折叠/展开），组内主账号自动置顶，采用 **顶部渐变色带 + 皇冠圆章 + 实心胶囊** 与成员子账号一眼区分；
  - 内置**结构化家庭组与角色编辑器**（免手敲标签语法），支持网格 / 紧凑 / 列表三视图切换与右键快捷菜单。
- **总览舱 & 交接中心 & 7 项运行体检**：
  - 首页支持多工作区一键下拉快切、最近接力轨迹展示与低余量通知提醒；
  - 交接中心自动提取最新会话 + `git status` 生成 `HANDOFF_AUTO.md`，内置 `.handoff_history/` 最近 10 份归档时间轴一键恢复；
  - 7 项本地环境体检（实例防冲突、启动器、Skills 软链、工作区、brain 日志隔离、家庭组与风控巡检、`agy-relay`）。

## 目录结构

```text
agy-switch/
├── build.sh                  # 一键生成视网膜图标、编译签名并安装到 /Applications
├── server.py                 # Python 3 标准库核心引擎（排他文件锁、跨组选号、安全切号、体检）
├── macos/
│   ├── make_icon.swift       # CoreGraphics 1024px 视网膜图标生成器
│   └── Sources/              # 模块化原生客户端源码
│       ├── Models.swift      # 数据契约与单一真相版本号
│       ├── DesignSystem.swift# 三层冷灰色板、主题持久化与家庭组视觉映射
│       ├── SwitchStore.swift # 串行 CLI 队列与状态编排
│       ├── Components.swift  # 账号卡片、紧凑卡、列表行与结构化分组编辑器
│       ├── Views.swift       # 六大业务页面视图
│       └── main.swift        # 主窗口与顶部 NSMenu 实时快捷菜单
├── tests/
│   └── test_server.py        # 零副作用隔离单元测试
├── AGENTS.md                 # 工程架构与 oil-dev 快测规范
└── CHANGELOG.md              # 版本演进记录
```

## 快速构建与测试

```bash
# 运行隔离单元测试
python3 -m unittest discover -s tests -v

# 一键构建并安装到 /Applications/AGY Switch.app
./build.sh
```
