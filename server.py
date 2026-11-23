#!/usr/bin/env python3
"""
agy-switch: Antigravity 多账号池监控与一键接力控制台（借鉴 cc-switch 设计）
零第三方依赖，Python 3 标准库直接运行。
"""

import argparse
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

_raw_home = str(Path.home())
HOME = Path(_raw_home.split("/.antigravity_multi_instances/")[0]) if "/.antigravity_multi_instances/" in _raw_home else Path(_raw_home)
MULTI_DIR = HOME / ".antigravity_multi_instances"
APP_DIR = HOME / "Desktop" / "Antigravity多开管理"
STATE_DIR = HOME / ".agy-switch"
STATE_FILE = STATE_DIR / "state.json"
DEFAULT_WORKSPACE = str(HOME / "Desktop" / "workspace")
RELAY_PROMPT = "请先阅读 HANDOFF_AUTO.md，接力继续刚才未完成的工作。"
WARN_5H_LIMIT = 200
WARN_7D_LIMIT = 1000


def load_state() -> dict:
    base = {
        "cooldowns": {},
        "notes": {},
        "calibrations": {},
        "workspace": DEFAULT_WORKSPACE,
        "warn_5h_limit": WARN_5H_LIMIT,
        "warn_7d_limit": WARN_7D_LIMIT,
    }
    if STATE_FILE.exists():
        try:
            loaded = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            base.update(loaded)
        except Exception:
            pass
    return base


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def natural_sort_key(name: str):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


def detect_running_ide_instance():
    """检测当前正在运行的 Antigravity IDE 属于哪个实例，返回 (instance_id, pid)"""
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid,command"], text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return "", 0
    found_main = None
    for line in out.splitlines():
        if "--type=" in line:
            continue
        if "Antigravity IDE.app/Contents/MacOS" in line:
            parts = line.strip().split(None, 1)
            pid = int(parts[0]) if parts and parts[0].isdigit() else 0
            m_dir = re.search(r"\.antigravity_multi_instances/([^/\s\"']+)", line)
            if m_dir:
                return m_dir.group(1), pid
            if found_main is None:
                found_main = ("main", pid)
    return found_main if found_main else ("", 0)


def launch_ide_for_account(acc_id: str, workspace: str = ""):
    """用指定账号隔离环境启动 Antigravity IDE（不关闭 Antigravity 主客户端，实现双 App 错号并行）"""
    ide_bin = "/Applications/Antigravity IDE.app/Contents/MacOS/Electron"
    if not os.path.exists(ide_bin):
        raise ValueError("未在本机 /Applications 找到 Antigravity IDE.app")

    # 只优雅退出旧的 Antigravity IDE，不动 Antigravity 主客户端
    try:
        subprocess.run(
            ["osascript", "-e", 'tell application "Antigravity IDE" to quit'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=4,
        )
    except Exception:
        pass
    for _ in range(16):
        rid, _ = detect_running_ide_instance()
        if not rid:
            break
        time.sleep(0.25)

    if acc_id == "main":
        cmd = ["open", "-a", "/Applications/Antigravity IDE.app"]
        if workspace and os.path.isdir(workspace):
            cmd.append(workspace)
        subprocess.Popen(cmd)
    else:
        inst_dir = MULTI_DIR / acc_id
        ide_data = inst_dir / "ide-data"
        ide_data.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["HOME"] = str(inst_dir)
        env["USERPROFILE"] = str(inst_dir)
        cmd = [ide_bin, f"--user-data-dir={ide_data}"]
        if workspace and os.path.isdir(workspace):
            cmd.append(workspace)
        subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    try:
        msg = f"已用 {acc_id} 启动 Antigravity IDE（不影响当前 Antigravity）"
        subprocess.run(
            ["osascript", "-e", f'display notification "{msg}" with title "AGY Switch"'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def detect_running_instance():
    """检测当前正在运行的 Antigravity 属于哪个实例，返回 (instance_id, pid)"""
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid,command"], text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return "", 0
    found_main = None
    for line in out.splitlines():
        if "--type=" in line:
            continue
        if "Antigravity.app/Contents/MacOS" in line or "Antigravity-" in line:
            parts = line.strip().split(None, 1)
            pid = int(parts[0]) if parts and parts[0].isdigit() else 0
            # 1. 优先匹配隔离实例的 --user-data-dir 路径（最准确）
            m_dir = re.search(r"\.antigravity_multi_instances/([^/\s\"']+)", line)
            if m_dir:
                return m_dir.group(1), pid
            # 2. 其次匹配桌面 .app 名称
            m_app = re.search(r"Antigravity-([^/\s]+)\.app", line)
            if m_app:
                return m_app.group(1), pid
            # 3. 最后才是主账号
            if "/Applications/Antigravity.app" in line and found_main is None:
                found_main = ("main", pid)
    return found_main if found_main else ("", 0)


def _parse_iso_ts(ts_str: str) -> float:
    if not ts_str:
        return 0.0
    try:
        s = ts_str.replace("Z", "+00:00")
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return 0.0


def scan_account_metrics(gemini_dir: Path):
    """统计该账号近 5 小时窗口与近 7 天（周）窗口的对话轮数、重置倒计时与最近活跃时间"""
    pattern = str(gemini_dir / "antigravity" / "brain" / "*" / ".system_generated" / "logs" / "transcript.jsonl")
    files = [f for f in glob.glob(pattern) if os.path.isfile(f) and os.path.getsize(f) > 0]
    now = time.time()
    cutoff_5h = now - 5 * 3600
    cutoff_7d = now - 7 * 86400

    turns_5h = 0
    turns_7d = 0
    bytes_7d = 0
    earliest_5h_ts = 0.0
    latest_mtime = 0.0
    sessions = []

    for f in files:
        mtime = os.path.getmtime(f)
        if mtime > latest_mtime:
            latest_mtime = mtime
        conv_id = Path(f).parts[-4] if len(Path(f).parts) >= 4 else "unknown"
        sessions.append({"path": f, "conv_id": conv_id, "mtime": mtime})

        # 只扫描近 7 天内有更新的 transcript，保证毫秒级速度
        if mtime >= cutoff_7d:
            bytes_7d += os.path.getsize(f)
            try:
                with open(f, "r", encoding="utf-8", errors="replace") as fp:
                    for line in fp:
                        if '"USER_INPUT"' not in line:
                            continue
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        if obj.get("type") != "USER_INPUT":
                            continue
                        ts = _parse_iso_ts(obj.get("created_at", "")) or mtime
                        if ts >= cutoff_7d:
                            turns_7d += 1
                        if ts >= cutoff_5h:
                            turns_5h += 1
                            if earliest_5h_ts == 0.0 or ts < earliest_5h_ts:
                                earliest_5h_ts = ts
            except Exception:
                pass

    reset_5h_min = int((earliest_5h_ts + 5 * 3600 - now) / 60) + 1 if earliest_5h_ts > 0 else 0

    return {
        "turns_5h": turns_5h,
        "turns_7d": turns_7d,
        "kb_7d": round(bytes_7d / 1024, 1),
        "reset_5h_min": max(0, reset_5h_min),
        "latest_mtime": latest_mtime,
        "latest_active": datetime.fromtimestamp(latest_mtime).strftime("%m-%d %H:%M") if latest_mtime else "从未",
        "sessions": sessions,
    }


def list_accounts(state: dict):
    running_id, running_pid = detect_running_instance()
    running_ide_id, running_ide_pid = detect_running_ide_instance()
    now = time.time()
    cooldowns = state.get("cooldowns", {})
    accounts = []
    all_sessions = []

    # 1. 主账号
    main_metrics = scan_account_metrics(HOME / ".gemini")
    for s in main_metrics["sessions"]:
        s["account_id"] = "main"
        s["account_label"] = "主账号 (~/.gemini)"
        all_sessions.append(s)

    candidates = [("main", "主账号 (~/.gemini)", "/Applications/Antigravity.app", main_metrics)]

    # 2. 隔离多开实例
    if MULTI_DIR.exists():
        dirs = [d for d in MULTI_DIR.iterdir() if d.is_dir()]
        dirs.sort(key=lambda d: natural_sort_key(d.name))
        for d in dirs:
            acc_id = d.name
            app_path = str(APP_DIR / f"Antigravity-{acc_id}.app")
            metrics = scan_account_metrics(d / ".gemini")
            for s in metrics["sessions"]:
                s["account_id"] = acc_id
                s["account_label"] = acc_id
                all_sessions.append(s)
            candidates.append((acc_id, acc_id, app_path, metrics))

    limit_5h = int(state.get("warn_5h_limit", WARN_5H_LIMIT))
    limit_7d = int(state.get("warn_7d_limit", WARN_7D_LIMIT))
    notes = state.get("notes", {})
    calibrations = state.get("calibrations", {})

    for acc_id, label, app_path, metrics in candidates:
        cd_until = float(cooldowns.get(acc_id, 0) or 0)
        in_cooldown = cd_until > now
        remaining_min = int((cd_until - now) / 60) + 1 if in_cooldown else 0

        if acc_id == "main":
            logged_in = (HOME / ".gemini" / "antigravity").exists()
        else:
            vscdb = MULTI_DIR / acc_id / "data" / "User" / "globalStorage" / "state.vscdb"
            logged_in = vscdb.exists() and vscdb.stat().st_size > 0

        cal = calibrations.get(acc_id)
        if cal:
            delta_5h = max(0, metrics["turns_5h"] - int(cal.get("base_5h", metrics["turns_5h"])))
            delta_7d = max(0, metrics["turns_7d"] - int(cal.get("base_7d", metrics["turns_7d"])))
            remain_5h_pct = max(0, min(100, int(round(float(cal.get("pct_5h", 100)) - delta_5h * 0.5))))
            remain_7d_pct = max(0, min(100, int(round(float(cal.get("pct_7d", 100)) - delta_7d * 0.2))))
            is_calibrated = True
        else:
            remain_5h_pct = max(0, 100 - int(round(metrics["turns_5h"] / max(1, limit_5h) * 100)))
            remain_7d_pct = max(0, 100 - int(round(metrics["turns_7d"] / max(1, limit_7d) * 100)))
            is_calibrated = False

        if not logged_in:
            health = "unverified"
        elif in_cooldown:
            health = "cooldown"
        elif remain_5h_pct <= 20 or remain_7d_pct <= 20:
            health = "warning"
        else:
            health = "ready"

        accounts.append({
            "id": acc_id,
            "label": label,
            "note": notes.get(acc_id, ""),
            "logged_in": logged_in,
            "calibrated": is_calibrated,
            "remain_5h_pct": remain_5h_pct,
            "remain_7d_pct": remain_7d_pct,
            "app_path": app_path,
            "app_exists": os.path.exists(app_path),
            "running": running_id == acc_id,
            "pid": running_pid if running_id == acc_id else 0,
            "running_ide": running_ide_id == acc_id,
            "ide_pid": running_ide_pid if running_ide_id == acc_id else 0,
            "health": health,
            "turns_5h": metrics["turns_5h"],
            "limit_5h": limit_5h,
            "reset_5h_min": metrics["reset_5h_min"],
            "turns_7d": metrics["turns_7d"],
            "limit_7d": limit_7d,
            "kb_7d": metrics["kb_7d"],
            "latest_active": metrics["latest_active"],
            "latest_mtime": metrics["latest_mtime"],
            "cooldown_remaining_min": remaining_min,
        })

    all_sessions.sort(key=lambda x: x["mtime"], reverse=True)
    recent_sessions = [
        {
            "account_id": s["account_id"],
            "account_label": s["account_label"],
            "conv_id": s["conv_id"],
            "path": s["path"],
            "time": datetime.fromtimestamp(s["mtime"]).strftime("%Y-%m-%d %H:%M:%S"),
        }
        for s in all_sessions[:8]
    ]
    return accounts, recent_sessions, running_id


def generate_handoff(workspace: str, transcript_path: str = "", max_turns: int = 12, extra_note: str = "") -> dict:
    """生成 HANDOFF_AUTO.md（附带 git status 摘要与用户特别交代），并复制接力词到剪贴板"""
    ws = Path(workspace)
    if not ws.exists():
        raise ValueError(f"工作区目录不存在: {workspace}")

    if not transcript_path:
        state = load_state()
        _, sessions, _ = list_accounts(state)
        if not sessions:
            raise ValueError("未找到任何可用的 transcript.jsonl 日志")
        transcript_path = sessions[0]["path"]

    turns = []
    with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = obj.get("type", "")
            content = (obj.get("content") or "").strip()
            if t not in ("USER_INPUT", "PLANNER_RESPONSE") or not content:
                continue
            role = "用户" if t == "USER_INPUT" else "AI"
            if len(content) > 1200:
                content = content[:1200] + "\n...(内容过长已截断)"
            turns.append((role, obj.get("created_at", ""), content))
    turns = turns[-max_turns:]

    git_summary = ""
    try:
        gs = subprocess.check_output(
            ["git", "-C", str(ws), "status", "--short"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        ).strip()
        if gs:
            git_summary = f"\n## 当前工作区 Git 变更\n```text\n{gs}\n```\n"
    except Exception:
        pass

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    note_block = f"\n## 给下一个号的特别交代\n{extra_note.strip()}\n" if extra_note.strip() else ""
    lines = [
        "# Antigravity 跨账号自动交接单 (HANDOFF_AUTO)",
        "",
        f"- **生成时间**: {now_str}",
        f"- **工作区**: `{workspace}`",
        f"- **原始日志**: `{transcript_path}`",
        note_block,
        git_summary,
        "## 最近对话上下文（按时间顺序）",
        "",
    ]
    for role, ts, content in turns:
        ts_clean = ts.replace("T", " ")[:19] if ts else ""
        lines.append(f"### [{role}] {ts_clean}")
        lines.append("")
        lines.append(content)
        lines.append("")

    out_path = ws / "HANDOFF_AUTO.md"
    # 归档旧交接单，防止覆盖丢失上下文（最多保留 10 份）
    if out_path.exists() and out_path.stat().st_size > 0:
        hist_dir = ws / ".handoff_history"
        hist_dir.mkdir(exist_ok=True)
        stamp = datetime.fromtimestamp(out_path.stat().st_mtime).strftime("%Y%m%d_%H%M%S")
        backup = hist_dir / f"HANDOFF_{stamp}.md"
        if not backup.exists():
            try:
                backup.write_bytes(out_path.read_bytes())
            except Exception:
                pass
        old_files = sorted(hist_dir.glob("HANDOFF_*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
        for stale in old_files[10:]:
            try:
                stale.unlink()
            except Exception:
                pass

    out_path.write_text("\n".join(lines), encoding="utf-8")

    # 写入剪贴板
    try:
        subprocess.run(["pbcopy"], input=RELAY_PROMPT, text=True, check=False)
    except Exception:
        pass

    return {"handoff_path": str(out_path), "turns": len(turns), "clipboard": RELAY_PROMPT}


def account_ag_dir(acc_id: str) -> Path:
    if not acc_id or acc_id == "main":
        return HOME / ".gemini" / "antigravity"
    return MULTI_DIR / acc_id / ".gemini" / "antigravity"


def _sqlite_safe_copy(src: Path, dst: Path):
    """使用 SQLite 在线备份 API 安全复制数据库，避免 WAL 损坏。"""
    if not src.exists() or src.resolve() == dst.resolve():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    for suffix in ("-wal", "-shm"):
        stale = Path(str(dst) + suffix)
        if stale.exists():
            try:
                stale.unlink()
            except Exception:
                pass
    tmp = Path(str(dst) + ".sync.tmp")
    try:
        src_conn = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        dst_conn = sqlite3.connect(str(tmp))
        with dst_conn:
            src_conn.backup(dst_conn)
        dst_conn.close()
        src_conn.close()
        os.replace(tmp, dst)
    except Exception:
        try:
            if tmp.exists():
                tmp.unlink()
        except Exception:
            pass


def _merge_dir_into(src: Path, dst: Path):
    """将 src 中独有的文件/目录合并到 dst，不覆盖已有项。"""
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if not target.exists():
            try:
                shutil.move(str(item), str(target))
            except Exception:
                pass


def sync_conversations(source_id: str, target_id: str):
    """
    跨账号安全同步纯本地对话历史与索引（仅在旧 Antigravity 彻底退出后、新实例启动前调用）。
    - conversations / brain / annotations：统一软链共享主目录，零重复占用空间。
    - conversation_summaries.db / agyhub_summaries_proto.pb：安全同步最新索引。
    - 绝不触碰 installation_id、state.vscdb、登录凭据等隔离文件。
    """
    canonical = HOME / ".gemini" / "antigravity"
    source_ag = account_ag_dir(source_id)
    target_ag = account_ag_dir(target_id)
    if not canonical.exists():
        return
    target_ag.mkdir(parents=True, exist_ok=True)

    # 1. 目录软链共享（先合并独有对话再软链，绝不丢数据）
    for dname in ("conversations", "brain", "annotations"):
        canon_d = canonical / dname
        canon_d.mkdir(parents=True, exist_ok=True)
        for ag_dir in (source_ag, target_ag):
            if ag_dir.resolve() == canonical.resolve():
                continue
            d = ag_dir / dname
            if d.is_symlink():
                try:
                    if d.resolve() == canon_d.resolve():
                        continue
                except Exception:
                    pass
                d.unlink()
            elif d.exists() and d.is_dir():
                _merge_dir_into(d, canon_d)
                shutil.rmtree(d, ignore_errors=True)
            try:
                d.symlink_to(canon_d)
            except Exception:
                pass

    # 2. 同步 conversation_summaries.db（优先取记录更全/更新的库回写到主库，再同步到目标号）
    canon_db = canonical / "conversation_summaries.db"
    src_db = source_ag / "conversation_summaries.db"
    tgt_db = target_ag / "conversation_summaries.db"

    def _db_score(p: Path) -> tuple:
        if not p.exists():
            return (0, 0.0)
        try:
            st = p.stat()
            # 超过 128KB 才视为包含完整历史，避免空新号覆盖主库
            has_history = 1 if st.st_size > 131072 else 0
            return (has_history, st.st_mtime)
        except Exception:
            return (0, 0.0)

    if src_db.exists() and src_db.resolve() != canon_db.resolve():
        if _db_score(src_db) > _db_score(canon_db):
            _sqlite_safe_copy(src_db, canon_db)

    if canon_db.exists() and tgt_db.resolve() != canon_db.resolve():
        _sqlite_safe_copy(canon_db, tgt_db)

    # 3. 同步 agyhub_summaries_proto.pb
    canon_pb = canonical / "agyhub_summaries_proto.pb"
    src_pb = source_ag / "agyhub_summaries_proto.pb"
    tgt_pb = target_ag / "agyhub_summaries_proto.pb"
    if src_pb.exists() and src_pb.resolve() != canon_pb.resolve():
        try:
            if not canon_pb.exists() or (
                src_pb.stat().st_size > 4096 and src_pb.stat().st_mtime > canon_pb.stat().st_mtime
            ):
                shutil.copy2(src_pb, canon_pb)
        except Exception:
            pass
    if canon_pb.exists() and tgt_pb.resolve() != canon_pb.resolve():
        try:
            shutil.copy2(canon_pb, tgt_pb)
        except Exception:
            pass


def switch_account_async(target_app: str, target_label: str, source_id: str = "", target_id: str = ""):
    """后台执行：优雅退出当前 Antigravity -> 轮询确认完全退出 -> 同步对话历史 -> 拉起目标账号"""
    try:
        subprocess.run(
            ["osascript", "-e", 'tell application "Antigravity" to quit'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except Exception:
        pass

    # 轮询等待旧进程彻底退出（最多 6 秒），避免新旧实例抢占 Keychain
    for _ in range(24):
        rid, _ = detect_running_instance()
        if not rid:
            break
        time.sleep(0.25)

    # 旧进程彻底退出后，安全同步跨账号对话历史
    if target_id:
        try:
            sync_conversations(source_id or "main", target_id)
        except Exception:
            pass

    time.sleep(0.3)
    subprocess.Popen(["open", "-n", target_app])
    try:
        msg = f"已切换到 {target_label}，接力词已复制，Cmd+V 即可继续"
        subprocess.run(
            ["osascript", "-e", f'display notification "{msg}" with title "AGY Switch"'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send_json(self, data: dict, status: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            html_path = Path(__file__).parent / "index.html"
            body = html_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == "/api/status":
            state = load_state()
            workspace = state.get("workspace", DEFAULT_WORKSPACE)
            accounts, sessions, running_id = list_accounts(state)
            handoff_file = Path(workspace) / "HANDOFF_AUTO.md"
            handoff_info = None
            if handoff_file.exists():
                st = handoff_file.stat()
                handoff_info = {
                    "path": str(handoff_file),
                    "updated": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                    "size_kb": round(st.st_size / 1024, 1),
                }
            self._send_json({
                "workspace": workspace,
                "running_id": running_id,
                "accounts": accounts,
                "sessions": sessions,
                "handoff": handoff_info,
                "warn_5h_limit": WARN_5H_LIMIT,
                "warn_7d_limit": WARN_7D_LIMIT,
            })
            return

        self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        try:
            payload = self._read_json()
        except Exception as e:
            self._send_json({"error": f"Invalid JSON: {e}"}, 400)
            return

        state = load_state()

        if parsed.path == "/api/workspace":
            ws = (payload.get("workspace") or "").strip()
            if not ws or not os.path.isdir(ws):
                self._send_json({"error": "目录不存在"}, 400)
                return
            state["workspace"] = ws
            save_state(state)
            self._send_json({"ok": True, "workspace": ws})
            return

        if parsed.path == "/api/cooldown":
            acc_id = payload.get("account_id")
            hours = float(payload.get("hours", 5))
            if not acc_id:
                self._send_json({"error": "缺少 account_id"}, 400)
                return
            if hours <= 0:
                state.setdefault("cooldowns", {}).pop(acc_id, None)
            else:
                state.setdefault("cooldowns", {})[acc_id] = time.time() + hours * 3600
            save_state(state)
            self._send_json({"ok": True})
            return

        if parsed.path == "/api/handoff":
            ws = payload.get("workspace") or state.get("workspace", DEFAULT_WORKSPACE)
            transcript = payload.get("transcript_path", "")
            try:
                res = generate_handoff(ws, transcript)
                self._send_json({"ok": True, **res})
            except Exception as e:
                self._send_json({"error": str(e)}, 500)
            return

        if parsed.path == "/api/switch":
            target_id = payload.get("target_id", "")
            mark_current_cooldown = bool(payload.get("mark_current_cooldown", True))
            accounts, _, running_id = list_accounts(state)

            # 若未指定目标，自动挑选最空闲的满血号
            if not target_id:
                ready = [a for a in accounts if a["health"] == "ready" and not a["running"] and a["app_exists"]]
                ready.sort(key=lambda a: (a["turns_5h"], a["turns_7d"], a["latest_mtime"]))
                if not ready:
                    self._send_json({"error": "没有可用的满血账号，请先重置某个账号的冷却状态"}, 400)
                    return
                target = ready[0]
            else:
                matched = [a for a in accounts if a["id"] == target_id]
                if not matched:
                    self._send_json({"error": f"未找到账号 {target_id}"}, 404)
                    return
                target = matched[0]
                if not target["app_exists"]:
                    self._send_json({"error": f"启动器不存在: {target['app_path']}"}, 400)
                    return

            ws = state.get("workspace", DEFAULT_WORKSPACE)
            handoff_res = generate_handoff(ws)

            if mark_current_cooldown and running_id and running_id != target["id"]:
                state.setdefault("cooldowns", {})[running_id] = time.time() + 5 * 3600
                save_state(state)

            threading.Thread(
                target=switch_account_async,
                args=(target["app_path"], target["label"], running_id or "main", target["id"]),
                daemon=True,
            ).start()

            self._send_json({
                "ok": True,
                "switched_to": target["label"],
                "handoff": handoff_res,
            })
            return

        self._send_json({"error": "Not found"}, 404)


def add_account(acc_id: str, note: str, state: dict) -> dict:
    """新建隔离账号实例 + 公共环境软链 + 桌面 .app 启动器"""
    acc_id = acc_id.strip()
    if not acc_id or not re.match(r"^[A-Za-z0-9._-]{2,48}$", acc_id) or acc_id == "main":
        raise ValueError("账号标识仅支持 2-48 位字母、数字、点、横线或下划线，且不能为 main")

    inst_dir = MULTI_DIR / acc_id
    app_bundle = APP_DIR / f"Antigravity-{acc_id}.app"
    if inst_dir.exists() or app_bundle.exists():
        raise ValueError(f"账号 {acc_id} 已存在")

    # 1. 创建隔离目录并软链公共环境
    (inst_dir / ".gemini" / "config").mkdir(parents=True, exist_ok=True)
    (inst_dir / "data").mkdir(parents=True, exist_ok=True)
    for rel in [".zshrc", ".zprofile", ".gitconfig", ".ssh", ".local", ".visionpower", ".config"]:
        src = HOME / rel
        dst = inst_dir / rel
        if src.exists() and not dst.exists():
            os.symlink(str(src), str(dst))
    skills_src = HOME / ".gemini" / "config" / "skills"
    skills_dst = inst_dir / ".gemini" / "config" / "skills"
    if skills_src.exists() and not skills_dst.exists():
        os.symlink(str(skills_src), str(skills_dst))

    # 2. 创建 .app 启动器
    macos_dir = app_bundle / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True, exist_ok=True)
    info_plist = app_bundle / "Contents" / "Info.plist"
    info_plist.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>launcher</string>
  <key>CFBundleIdentifier</key>
  <string>com.antigravity.multi.{acc_id}</string>
  <key>CFBundleName</key>
  <string>Antigravity-{acc_id}</string>
</dict>
</plist>
""",
        encoding="utf-8",
    )
    launcher = macos_dir / "launcher"
    launcher.write_text(
        f"""#!/bin/bash
export HOME="{inst_dir}"
export USERPROFILE="{inst_dir}"
export SSH_TTY=1
exec "/Applications/Antigravity.app/Contents/MacOS/Antigravity" --user-data-dir="{inst_dir}/data"
""",
        encoding="utf-8",
    )
    os.chmod(launcher, 0o755)

    if note.strip():
        state.setdefault("notes", {})[acc_id] = note.strip()
        save_state(state)
    return {"ok": True, "id": acc_id, "app_path": str(app_bundle)}


def delete_account(acc_id: str, state: dict) -> dict:
    """安全删除隔离账号：移入 ~/.Trash 防误删"""
    if not acc_id or acc_id == "main":
        raise ValueError("主账号受保护，不可删除")
    trash = HOME / ".Trash"
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    inst_dir = MULTI_DIR / acc_id
    app_bundle = APP_DIR / f"Antigravity-{acc_id}.app"
    if inst_dir.exists():
        inst_dir.rename(trash / f"agy_inst_{acc_id}_{stamp}")
    if app_bundle.exists():
        app_bundle.rename(trash / f"Antigravity-{acc_id}_{stamp}.app")
    state.setdefault("cooldowns", {}).pop(acc_id, None)
    state.setdefault("notes", {}).pop(acc_id, None)
    save_state(state)
    return {"ok": True, "deleted": acc_id}


def run_doctor(state: dict) -> dict:
    """本地运行环境体检：实例冲突、启动器、软链、交接单、进程内存"""
    checks = []

    # 1. 检测当前运行的 Antigravity 主进程数量（防止多开抢 Keychain）
    running_procs = []
    try:
        out = subprocess.check_output(["ps", "-eo", "pid,rss,command"], text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            if ("Antigravity.app/Contents/MacOS/Electron" in line or "Antigravity.app/Contents/MacOS/Antigravity" in line) and "--type=" not in line:
                parts = line.strip().split(None, 2)
                if len(parts) >= 2:
                    pid = int(parts[0])
                    mem_mb = round(int(parts[1]) / 1024, 1)
                    running_procs.append((pid, mem_mb))
    except Exception:
        pass

    if len(running_procs) == 0:
        checks.append({"name": "Antigravity 运行实例", "status": "ok", "detail": "当前未运行任何实例（随时可安全启动任意账号）"})
    elif len(running_procs) == 1:
        pid, mem = running_procs[0]
        checks.append({"name": "Antigravity 运行实例", "status": "ok", "detail": f"单实例安全运行中 · PID {pid} · 主进程内存 {mem} MB"})
    else:
        pids = ", ".join(str(p[0]) for p in running_procs)
        checks.append({"name": "Antigravity 运行实例", "status": "warn", "detail": f"检测到 {len(running_procs)} 个实例同时运行 (PID: {pids})，建议只开 1 个防 Keychain 串号"})

    # 2. 检查隔离实例目录与启动器 .app 匹配度
    inst_dirs = [d for d in MULTI_DIR.iterdir() if d.is_dir()] if MULTI_DIR.exists() else []
    missing_apps = [d.name for d in inst_dirs if not (APP_DIR / f"Antigravity-{d.name}.app").exists()]
    if not inst_dirs:
        checks.append({"name": "多开隔离实例", "status": "warn", "detail": f"未在 {MULTI_DIR} 找到隔离实例"})
    elif not missing_apps:
        checks.append({"name": "多开启动器 (.app)", "status": "ok", "detail": f"{len(inst_dirs)}/{len(inst_dirs)} 个隔离实例均有对应桌面启动器"})
    else:
        checks.append({"name": "多开启动器 (.app)", "status": "error", "detail": f"缺少启动器: {', '.join(missing_apps[:3])}"})

    # 3. 检查公共环境软链 (.gemini/config/skills & .local)
    broken_links = []
    for d in inst_dirs:
        skills_link = d / ".gemini" / "config" / "skills"
        if not skills_link.exists():
            broken_links.append(d.name)
    if not broken_links:
        checks.append({"name": "公共环境与 Skills 软链", "status": "ok", "detail": f"全部 {len(inst_dirs)} 个隔离实例已正常软链公共 Skills"})
    else:
        checks.append({"name": "公共环境与 Skills 软链", "status": "warn", "detail": f"{len(broken_links)} 个实例缺少 Skills 软链: {', '.join(broken_links[:3])}"})

    # 4. 检查工作区与 HANDOFF_AUTO.md
    ws = Path(state.get("workspace", DEFAULT_WORKSPACE))
    hf = ws / "HANDOFF_AUTO.md"
    if not ws.exists():
        checks.append({"name": "接力工作区与交接单", "status": "error", "detail": f"工作区目录不存在: {ws}"})
    elif hf.exists():
        upd = datetime.fromtimestamp(hf.stat().st_mtime).strftime("%m-%d %H:%M")
        kb = round(hf.stat().st_size / 1024, 1)
        checks.append({"name": "接力工作区与交接单", "status": "ok", "detail": f"工作区正常 · HANDOFF_AUTO.md 就绪 ({kb} KB, 更新于 {upd})"})
    else:
        checks.append({"name": "接力工作区与交接单", "status": "warn", "detail": f"工作区正常，但尚未生成 HANDOFF_AUTO.md"})

    # 5. 检查隔离实例 brain 是否被软链共享（会导致统计与主账号重叠）
    shared_brains = []
    for d in inst_dirs:
        b = d / ".gemini" / "antigravity" / "brain"
        if b.is_symlink():
            shared_brains.append(d.name)
    if not shared_brains:
        checks.append({"name": "对话日志隔离 (brain)", "status": "ok", "detail": "所有隔离实例均拥有独立 brain 日志目录"})
    else:
        checks.append({"name": "对话日志隔离 (brain)", "status": "warn", "detail": f"{', '.join(shared_brains)} 的 brain 软链到了主账号，本地轮数统计会与主账号重叠"})

    # 6. 检查 agy-relay CLI
    relay_bin = HOME / ".local" / "bin" / "agy-relay"
    if relay_bin.exists() and os.access(relay_bin, os.X_OK):
        checks.append({"name": "agy-relay 接力脚本", "status": "ok", "detail": f"就绪 ({relay_bin})"})
    else:
        checks.append({"name": "agy-relay 接力脚本", "status": "warn", "detail": "未找到 ~/.local/bin/agy-relay（不影响本 App 内置接力）"})

    return {
        "checked_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "checks": checks,
    }


def main():
    parser = argparse.ArgumentParser(description="AGY Switch - Antigravity 多账号池监控与一键接力")
    parser.add_argument("--port", type=int, default=17980, help="监听端口（默认 17980）")
    parser.add_argument("--host", default="127.0.0.1", help="监听地址（默认 127.0.0.1）")
    parser.add_argument("--cli-status", action="store_true", help="输出当前账号池状态 JSON")
    parser.add_argument("--cli-doctor", action="store_true", help="输出本地运行环境体检 JSON")
    parser.add_argument("--cli-add", nargs=2, metavar=("ACC_ID", "NOTE"), help="新增隔离账号实例与启动器")
    parser.add_argument("--cli-delete", metavar="ACC_ID", help="安全删除隔离账号（移入废纸篓）")
    parser.add_argument("--cli-note", nargs=2, metavar=("ACC_ID", "NOTE"), help="更新账号备注")
    parser.add_argument("--cli-calibrate", nargs=3, metavar=("ACC_ID", "PCT_5H", "PCT_7D"), help="校准账号真实剩余百分比")
    parser.add_argument("--cli-autostart", choices=["status", "on", "off"], help="查询或开关 macOS 开机自启")
    parser.add_argument("--cli-handoff", action="store_true", help="生成 HANDOFF_AUTO.md 并复制接力词")
    parser.add_argument("--cli-handoff-save", nargs=2, metavar=("TRANSCRIPT", "NOTE"), help="按指定日志与特别交代生成交接单")
    parser.add_argument("--cli-config", nargs=3, metavar=("WORKSPACE", "LIMIT_5H", "LIMIT_7D"), help="更新工作区与预警阈值")
    parser.add_argument("--cli-switch", nargs="?", const="", default=None, help="一键切换账号（空串=自动选满血号）")
    parser.add_argument("--cli-launch-ide", metavar="ACC_ID", help="用指定账号启动 Antigravity IDE（双 App 错号并行）")
    parser.add_argument("--cli-cooldown", nargs=2, metavar=("ACC_ID", "HOURS"), help="设置账号冷却小时数（0=恢复满血）")
    parser.add_argument("--cli-clear-cooldowns", action="store_true", help="一键解除全部账号冷却")
    parser.add_argument("--cli-restore-handoff", metavar="FILENAME", help="从 .handoff_history 恢复指定交接单")
    parser.add_argument("--cli-workspaces", nargs=2, metavar=("ACTION", "PATH"), help="管理常用工作区列表 (add|use|remove)")
    args = parser.parse_args()

    state = load_state()
    if args.cli_add:
        try:
            print(json.dumps(add_account(args.cli_add[0], args.cli_add[1], state), ensure_ascii=False))
        except Exception as e:
            print(json.dumps({"error": str(e)}, ensure_ascii=False))
        return

    if args.cli_delete:
        try:
            print(json.dumps(delete_account(args.cli_delete, state), ensure_ascii=False))
        except Exception as e:
            print(json.dumps({"error": str(e)}, ensure_ascii=False))
        return

    if args.cli_autostart:
        plist = HOME / "Library" / "LaunchAgents" / "io.agyswitch.app.plist"
        if args.cli_autostart == "status":
            print(json.dumps({"enabled": plist.exists()}, ensure_ascii=False))
        elif args.cli_autostart == "on":
            plist.parent.mkdir(parents=True, exist_ok=True)
            plist.write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.agyswitch.app</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>/Applications/AGY Switch.app</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
""",
                encoding="utf-8",
            )
            print(json.dumps({"ok": True, "enabled": True}, ensure_ascii=False))
        else:
            if plist.exists():
                plist.unlink()
            print(json.dumps({"ok": True, "enabled": False}, ensure_ascii=False))
        return

    if args.cli_calibrate:
        acc_id, p5, p7 = args.cli_calibrate
        accounts, _, _ = list_accounts(state)
        matched = [a for a in accounts if a["id"] == acc_id]
        base_5h = matched[0]["turns_5h"] if matched else 0
        base_7d = matched[0]["turns_7d"] if matched else 0
        state.setdefault("calibrations", {})[acc_id] = {
            "pct_5h": max(0, min(100, int(float(p5)))),
            "pct_7d": max(0, min(100, int(float(p7)))),
            "base_5h": base_5h,
            "base_7d": base_7d,
            "updated_at": datetime.now().strftime("%m-%d %H:%M"),
        }
        save_state(state)
        print(json.dumps({"ok": True}, ensure_ascii=False))
        return

    if args.cli_note:
        acc_id, note = args.cli_note
        if note.strip():
            state.setdefault("notes", {})[acc_id] = note.strip()
        else:
            state.setdefault("notes", {}).pop(acc_id, None)
        save_state(state)
        print(json.dumps({"ok": True}, ensure_ascii=False))
        return

    if args.cli_doctor:
        print(json.dumps(run_doctor(state), ensure_ascii=False))
        return

    if args.cli_status:
        ws = state.get("workspace", DEFAULT_WORKSPACE)
        accounts, sessions, running_id = list_accounts(state)
        hf_path = Path(ws) / "HANDOFF_AUTO.md"
        hf_preview = ""
        hf_updated = ""
        if hf_path.exists():
            try:
                hf_preview = hf_path.read_text(encoding="utf-8", errors="replace")[:4000]
                hf_updated = datetime.fromtimestamp(hf_path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
            except Exception:
                pass
        hist_items = []
        hist_dir = Path(ws) / ".handoff_history"
        if hist_dir.exists():
            for p in sorted(hist_dir.glob("HANDOFF_*.md"), key=lambda x: x.stat().st_mtime, reverse=True)[:10]:
                st = p.stat()
                hist_items.append({
                    "name": p.name,
                    "kb": round(st.st_size / 1024, 1),
                    "time": datetime.fromtimestamp(st.st_mtime).strftime("%m-%d %H:%M"),
                })
        ws_list = list(dict.fromkeys([ws] + [w for w in state.get("workspaces", []) if w]))
        print(json.dumps({
            "workspace": ws,
            "workspaces": ws_list,
            "running_id": running_id,
            "accounts": accounts,
            "sessions": sessions[:8],
            "warn_5h_limit": int(state.get("warn_5h_limit", WARN_5H_LIMIT)),
            "warn_7d_limit": int(state.get("warn_7d_limit", WARN_7D_LIMIT)),
            "handoff_preview": hf_preview,
            "handoff_updated": hf_updated,
            "handoff_history": hist_items,
            "last_switch": state.get("last_switch", ""),
        }, ensure_ascii=False))
        return

    if args.cli_restore_handoff:
        ws = Path(state.get("workspace", DEFAULT_WORKSPACE))
        src = ws / ".handoff_history" / os.path.basename(args.cli_restore_handoff)
        if not src.exists():
            print(json.dumps({"error": "历史交接单不存在"}, ensure_ascii=False))
            return
        (ws / "HANDOFF_AUTO.md").write_bytes(src.read_bytes())
        try:
            subprocess.run(["pbcopy"], input=RELAY_PROMPT, text=True, check=False)
        except Exception:
            pass
        print(json.dumps({"ok": True, "restored": src.name}, ensure_ascii=False))
        return

    if args.cli_workspaces:
        act, path_val = args.cli_workspaces
        path_val = path_val.strip()
        ws_list = list(state.get("workspaces", [DEFAULT_WORKSPACE]))
        if act == "add" and os.path.isdir(path_val):
            if path_val not in ws_list:
                ws_list.append(path_val)
            state["workspaces"] = ws_list
            state["workspace"] = path_val
            save_state(state)
        elif act == "use" and os.path.isdir(path_val):
            if path_val not in ws_list:
                ws_list.append(path_val)
            state["workspaces"] = ws_list
            state["workspace"] = path_val
            save_state(state)
        elif act == "remove":
            ws_list = [w for w in ws_list if w != path_val]
            if not ws_list:
                ws_list = [DEFAULT_WORKSPACE]
            state["workspaces"] = ws_list
            if state.get("workspace") == path_val:
                state["workspace"] = ws_list[0]
            save_state(state)
        print(json.dumps({"ok": True, "workspace": state["workspace"], "workspaces": state["workspaces"]}, ensure_ascii=False))
        return

    if args.cli_config:
        ws, l5, l7 = args.cli_config
        if ws and os.path.isdir(ws):
            state["workspace"] = ws
        state["warn_5h_limit"] = max(10, int(l5))
        state["warn_7d_limit"] = max(50, int(l7))
        save_state(state)
        print(json.dumps({"ok": True}, ensure_ascii=False))
        return

    if args.cli_handoff_save:
        tr, note = args.cli_handoff_save
        res = generate_handoff(state.get("workspace", DEFAULT_WORKSPACE), tr, extra_note=note)
        print(json.dumps({"ok": True, **res}, ensure_ascii=False))
        return

    if args.cli_handoff:
        res = generate_handoff(state.get("workspace", DEFAULT_WORKSPACE))
        print(json.dumps({"ok": True, **res}, ensure_ascii=False))
        return

    if args.cli_clear_cooldowns:
        state["cooldowns"] = {}
        save_state(state)
        print(json.dumps({"ok": True}, ensure_ascii=False))
        return

    if args.cli_cooldown:
        acc_id, hours_str = args.cli_cooldown
        hours = float(hours_str)
        if hours <= 0:
            state.setdefault("cooldowns", {}).pop(acc_id, None)
        else:
            state.setdefault("cooldowns", {})[acc_id] = time.time() + hours * 3600
        save_state(state)
        print(json.dumps({"ok": True}, ensure_ascii=False))
        return

    if args.cli_launch_ide:
        try:
            ws = state.get("workspace", DEFAULT_WORKSPACE)
            launch_ide_for_account(args.cli_launch_ide, ws)
            print(json.dumps({"ok": True, "ide_account": args.cli_launch_ide}, ensure_ascii=False))
        except Exception as e:
            print(json.dumps({"error": str(e)}, ensure_ascii=False))
        return

    if args.cli_switch is not None:
        target_id = args.cli_switch
        accounts, _, running_id = list_accounts(state)
        if not target_id:
            ready = [a for a in accounts if a["health"] == "ready" and not a["running"] and a["app_exists"]]
            ready.sort(key=lambda a: (a["turns_5h"], a["turns_7d"], a["latest_mtime"]))
            if not ready:
                print(json.dumps({"error": "没有可用的满血账号"}, ensure_ascii=False))
                return
            target = ready[0]
        else:
            matched = [a for a in accounts if a["id"] == target_id]
            if not matched:
                print(json.dumps({"error": f"未找到账号 {target_id}"}, ensure_ascii=False))
                return
            target = matched[0]
        generate_handoff(state.get("workspace", DEFAULT_WORKSPACE))
        if running_id and running_id != target["id"]:
            state.setdefault("cooldowns", {})[running_id] = time.time() + 5 * 3600
            save_state(state)
        switch_account_async(target["app_path"], target["label"], running_id or "main", target["id"])
        print(json.dumps({"ok": True, "switched_to": target["label"]}, ensure_ascii=False))
        return

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"🚀 AGY Switch 已启动: http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止 AGY Switch")


if __name__ == "__main__":
    main()
