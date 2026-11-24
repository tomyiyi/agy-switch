# AGENTS.md — AGY Switch 开发与维护规范

## 架构概览

- **后端引擎**：`server.py`（Python 3 标准库，零第三方依赖，通过 `state.lock` 排他锁 + 原子 `os.replace` 维护 `~/.agy-switch/state.json`）。
- **原生客户端**：`macos/Sources/*.swift`（模块化 SwiftUI + AppKit 菜单栏应用，打包内置 `server.py` 至 `.app/Contents/Resources/`）。
- **安全红线**：严格只读本地文件与进程状态，**严禁提取 Google OAuth `refresh_token` 或调用未公开私有云端额度接口**。

## oil-dev 开发约定

- **局部快测命令**：`python3 -m unittest discover -s tests -v`
- **完整构建与打包门禁**：`./build.sh`（须 0 错误、0 编译警告通过）
- **高风险模块**：`server.py`（进程退出编排、SQLite 跨号备份、`state.json` 并发锁）、`build.sh`（签名与应用包结构）
