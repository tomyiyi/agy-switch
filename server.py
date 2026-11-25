#!/usr/bin/env python3
"""
AGY Switch v5.7 — Antigravity 原生多账号池管理与跨家庭组智能接力引擎
零第三方依赖，仅使用 Python 3 标准库，严格遵守本地只读安全边界（绝不触碰私有 OAuth Token API）。
"""

import argparse
import concurrent.futures
import contextlib
import fcntl
import glob
import http.client
import json
import os
import re
import signal
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

APP_VERSION = "5.7.0"

_raw_home = str(Path.home())
HOME = (
    Path(_raw_home.split("/.antigravity_multi_instances/")[0])
    if "/.antigravity_multi_instances/" in _raw_home
    else Path(_raw_home)
)
MULTI_DIR = HOME / ".antigravity_multi_instances"
APP_DIR = HOME / "Desktop" / "Antigravity多开管理"
STATE_DIR = HOME / ".agy-switch"
STATE_FILE = STATE_DIR / "state.json"
LOCK_FILE = STATE_DIR / "state.lock"
NET_CACHE_FILE = STATE_DIR / "network_cache.json"
NET_CACHE_TTL = 60.0
DEFAULT_WORKSPACE = str(HOME / "Desktop" / "workspace")
RELAY_PROMPT = "请先阅读 HANDOFF_AUTO.md，接力继续刚才未完成的工作。"
WARN_5H_LIMIT = 200
WARN_7D_LIMIT = 1000

VALID_ACC_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,47}$")
FAMILY_RE = re.compile(r"^\[家庭组\s*([A-Fa-f])\s*(?:[-·]\s*(主|子|管理员|成员))?\]\s*(.*)$")
FLAG_KEYWORDS = ("⚠️", "二次验证", "风控", "禁用", "封号")


def validate_isolated_acc_id(acc_id: str) -> str:
    """严格白名单校验隔离账号标识，彻底拦截 '.' / '..' / 路径穿越"""
    cleaned = (acc_id or "").strip()
    if not cleaned or cleaned == "main" or not VALID_ACC_ID_RE.match(cleaned):
        raise ValueError("账号标识仅支持 2-48 位字母、数字、点、横线或下划线（首字符须为字母或数字），且不能为 main")
    candidate = (MULTI_DIR / cleaned).resolve()
    if candidate.parent != MULTI_DIR.resolve():
        raise ValueError("非法的账号目录路径")
    return cleaned


@contextlib.contextmanager
def state_lock(shared: bool = False):
    """跨进程文件锁（读操作用 LOCK_SH，写临界区用 LOCK_EX，严禁包裹耗时外部调用）"""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOCK_FILE, "a+", encoding="utf-8") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def load_state() -> dict:
    """加载并严格做类型与防 null 归一化，兼容旧版或手工编辑的 state.json"""
    base = {
        "cooldowns": {},
        "notes": {},
        "calibrations": {},
        "workspace": DEFAULT_WORKSPACE,
        "workspaces": [DEFAULT_WORKSPACE],
        "warn_5h_limit": WARN_5H_LIMIT,
        "warn_7d_limit": WARN_7D_LIMIT,
        "last_switch": "",
        "switch_history": [],
        "auto_paste": False,
    }
    if STATE_FILE.exists():
        try:
            loaded = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                if isinstance(loaded.get("cooldowns"), dict):
                    base["cooldowns"] = loaded["cooldowns"]
                if isinstance(loaded.get("notes"), dict):
                    base["notes"] = loaded["notes"]
                if isinstance(loaded.get("calibrations"), dict):
                    base["calibrations"] = loaded["calibrations"]
                if isinstance(loaded.get("workspace"), str) and loaded["workspace"].strip():
                    base["workspace"] = loaded["workspace"].strip()
                if isinstance(loaded.get("workspaces"), list):
                    ws_clean = [w for w in loaded["workspaces"] if isinstance(w, str) and w.strip()]
                    if ws_clean:
                        base["workspaces"] = ws_clean
                if loaded.get("warn_5h_limit") is not None:
                    base["warn_5h_limit"] = int(loaded["warn_5h_limit"])
                if loaded.get("warn_7d_limit") is not None:
                    base["warn_7d_limit"] = int(loaded["warn_7d_limit"])
                if isinstance(loaded.get("last_switch"), str):
                    base["last_switch"] = loaded["last_switch"]
                if isinstance(loaded.get("switch_history"), list):
                    base["switch_history"] = [x for x in loaded["switch_history"] if isinstance(x, dict)]
                if isinstance(loaded.get("auto_paste"), bool):
                    base["auto_paste"] = loaded["auto_paste"]
        except Exception:
            pass
    return base


def save_state(state: dict) -> None:
    """使用临时文件 + os.replace 原子落盘，避免写入中断损坏 JSON"""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_DIR / f"state.json.{os.getpid()}.tmp"
    payload = json.dumps(state, ensure_ascii=False, indent=2)
    tmp.write_text(payload, encoding="utf-8")
    os.replace(tmp, STATE_FILE)


def notify_macos(message: str, title: str = "AGY Switch") -> None:
    """安全转义 AppleScript 字符串并发送 macOS 系统通知"""
    safe_msg = message.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", " ")
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", " ")
    try:
        subprocess.run(
            ["/usr/bin/osascript", "-e", f'display notification "{safe_msg}" with title "{safe_title}"'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
    except Exception:
        pass


def parse_family_meta(note: str) -> dict:
    """从备注字符串提取结构化家庭组、角色、干净说明与风险标记"""
    raw = (note or "").strip()
    flagged = any(k in raw for k in FLAG_KEYWORDS)
    m = FAMILY_RE.match(raw)
    if m:
        grp = m.group(1).upper()
        role_raw = m.group(2) or ""
        is_mgr = role_raw in ("主", "管理员")
        clean = (m.group(3) or "").strip()
        return {
            "family_group": grp,
            "is_manager": is_mgr,
            "clean_note": clean,
            "explicit_solo": "独享" in raw,
            "flagged": flagged,
        }
    return {
        "family_group": "",
        "is_manager": False,
        "clean_note": raw,
        "explicit_solo": "独享" in raw,
        "flagged": flagged,
    }


def natural_sort_key(name: str):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


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
            m_dir = re.search(r"\.antigravity_multi_instances/([^/\s\"']+)", line)
            if m_dir:
                return m_dir.group(1), pid
            m_app = re.search(r"Antigravity-([^/\s]+)\.app", line)
            if m_app:
                return m_app.group(1), pid
            if "/Applications/Antigravity.app" in line and found_main is None:
                found_main = ("main", pid)
    return found_main if found_main else ("", 0)


def _parse_iso_ts(ts_str: str) -> float:
    if not ts_str:
        return 0.0
    try:
        return datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def scan_account_metrics(gemini_dir: Path):
    """统计该账号近 5 小时窗口与近 7 天窗口的真实本地对话轮数、重置倒计时与最近活跃时间"""
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
        sessions.append({"path": f, "real_path": os.path.realpath(f), "conv_id": conv_id, "mtime": mtime})

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


def _infer_active_group(accounts: list, active_acc: Optional[dict]) -> str:
    """推导当前运行账号的家庭组：优先使用手动标注；若未标注（如 main），按真实邮箱/前缀自动关联已有同组账号防碰撞。"""
    if not active_acc:
        return ""
    if active_acc.get("family_group"):
        return active_acc["family_group"]
    active_email = (active_acc.get("email") or "").strip().lower()
    if not active_email:
        return ""
    active_prefix = active_email.split("@")[0]
    for a in accounts:
        if a["id"] == active_acc["id"] or not a.get("family_group"):
            continue
        other_email = (a.get("email") or "").strip().lower()
        if other_email and other_email == active_email:
            return a["family_group"]
        if len(active_prefix) >= 5 and active_prefix in a["id"].lower():
            return a["family_group"]
    return ""


def pick_best_candidates(accounts: list, running_id: str) -> list:
    """
    跨家庭组智能选号排序引擎：
    优先级：1. 排除同家庭组（含同邮箱自动关联）  2. 独享组优先  3. 近 5h 轮数最少  4. 近 7d 轮数最少  5. 最久未活跃
    自动跳过未登录、冷却中、启动器缺失、当前运行中、同邮箱重复实例及带风控/二次验证标记的账号。
    """
    active_acc = next((a for a in accounts if a["id"] == running_id), None)
    active_grp = _infer_active_group(accounts, active_acc)
    active_email = (active_acc.get("email") or "").strip().lower() if active_acc else ""

    eligible = [
        a for a in accounts
        if a["logged_in"]
        and a["health"] != "cooldown"
        and a["app_exists"]
        and not a["running"]
        and not a["flagged"]
        and not (active_email and (a.get("email") or "").strip().lower() == active_email)
    ]

    def sort_key(a: dict):
        same_grp = 1 if (active_grp and a["family_group"] == active_grp) else 0
        not_solo = 0 if a["solo_group"] else 1
        return (same_grp, not_solo, a["turns_5h"], a["turns_7d"], a["latest_mtime"])

    eligible.sort(key=sort_key)
    for idx, a in enumerate(eligible):
        same_grp = bool(active_grp and a["family_group"] == active_grp)
        if same_grp:
            a["recommend_reason"] = f"同组兜底 ({a['family_group']}组)"
        elif a["solo_group"]:
            a["recommend_reason"] = f"跨组首选 · {a['family_group'] or '独立'}组独享"
        elif a["family_group"]:
            a["recommend_reason"] = f"跨组满血 · {a['family_group']}组" if idx == 0 else f"跨组可用 · {a['family_group']}组"
        else:
            a["recommend_reason"] = "空闲可用"
    return eligible



def get_instance_real_email(acc_id: str) -> str:
    """从 app_storage.json 安全提取该实例实际登录绑定的 Google 邮箱账号"""
    if acc_id == "main":
        p = HOME / "Library" / "Application Support" / "Antigravity" / "app_storage.json"
    else:
        p = MULTI_DIR / acc_id / "data" / "app_storage.json"
    if p.exists():
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
            return d.get("agy.onboarding.lastLoginUsername", "").strip()
        except Exception:
            pass
    return ""


def list_accounts(state: dict):
    running_id, running_pid = detect_running_instance()
    now = time.time()
    cooldowns = state.get("cooldowns") or {}
    notes = state.get("notes") or {}
    calibrations = state.get("calibrations") or {}
    limit_5h = int(state.get("warn_5h_limit", WARN_5H_LIMIT))
    limit_7d = int(state.get("warn_7d_limit", WARN_7D_LIMIT))

    accounts = []
    seen_real_sessions = set()
    all_sessions = []

    main_metrics = scan_account_metrics(HOME / ".gemini")
    main_email = get_instance_real_email("main")
    candidates = [("main", "主账号 (~/.gemini)", "/Applications/Antigravity.app", main_metrics, main_email)]

    if MULTI_DIR.exists():
        dirs = [d for d in MULTI_DIR.iterdir() if d.is_dir()]
        dirs.sort(key=lambda d: natural_sort_key(d.name))
        for d in dirs:
            acc_id = d.name
            app_path = str(APP_DIR / f"Antigravity-{acc_id}.app")
            metrics = scan_account_metrics(d / ".gemini")
            real_email = get_instance_real_email(acc_id)
            candidates.append((acc_id, acc_id, app_path, metrics, real_email))

    # 收集去重后的最近会话（优先挂在当前运行账号名下，避免软链 brain 重复展示同一会话）
    ordered_for_sessions = sorted(candidates, key=lambda c: 0 if c[0] == running_id else 1)
    for acc_id, label, _, metrics, _ in ordered_for_sessions:
        for s in metrics["sessions"]:
            rp = s.get("real_path", s["path"])
            if rp in seen_real_sessions:
                continue
            seen_real_sessions.add(rp)
            s_copy = dict(s)
            s_copy["account_id"] = acc_id
            s_copy["account_label"] = label
            all_sessions.append(s_copy)

    group_counts = {}
    parsed_notes = {}
    for acc_id, _, _, _, _ in candidates:
        meta = parse_family_meta(notes.get(acc_id, ""))
        parsed_notes[acc_id] = meta
        grp = meta["family_group"]
        if grp:
            group_counts[grp] = group_counts.get(grp, 0) + 1

    for acc_id, label, app_path, metrics, real_email in candidates:
        cd_until = float(cooldowns.get(acc_id, 0) or 0)
        in_cooldown = cd_until > now
        remaining_min = int((cd_until - now) / 60) + 1 if in_cooldown else 0

        if acc_id == "main":
            tok = HOME / ".gemini" / "jetski-standalone-oauth-token"
            logged_in = (tok.exists() and tok.stat().st_size > 0) or (HOME / ".gemini" / "antigravity").exists()
        else:
            tok = MULTI_DIR / acc_id / ".gemini" / "jetski-standalone-oauth-token"
            logged_in = tok.exists() and tok.stat().st_size > 0

        cal = calibrations.get(acc_id)
        is_calibrated = False
        if isinstance(cal, dict):
            cal_ts = float(cal.get("ts", 0) or 0)
            age_sec = (now - cal_ts) if cal_ts > 0 else 0
            # 5h 窗口超过 5 小时或本轮对话已完全归零时，自动恢复 5h 为 100%；7d 超过 7 天自动失效
            if age_sec < 7 * 86400:
                is_calibrated = True
                if age_sec >= 5 * 3600 or (metrics["turns_5h"] == 0 and int(cal.get("base_5h", 0)) > 0):
                    remain_5h_pct = 100
                else:
                    delta_5h = max(0, metrics["turns_5h"] - int(cal.get("base_5h", metrics["turns_5h"])))
                    remain_5h_pct = max(0, min(100, int(round(float(cal.get("pct_5h", 100)) - delta_5h * 0.5))))
                delta_7d = max(0, metrics["turns_7d"] - int(cal.get("base_7d", metrics["turns_7d"])))
                remain_7d_pct = max(0, min(100, int(round(float(cal.get("pct_7d", 100)) - delta_7d * 0.2))))
            else:
                remain_5h_pct = max(0, 100 - int(round(metrics["turns_5h"] / max(1, limit_5h) * 100)))
                remain_7d_pct = max(0, 100 - int(round(metrics["turns_7d"] / max(1, limit_7d) * 100)))
        else:
            remain_5h_pct = max(0, 100 - int(round(metrics["turns_5h"] / max(1, limit_5h) * 100)))
            remain_7d_pct = max(0, 100 - int(round(metrics["turns_7d"] / max(1, limit_7d) * 100)))

        meta = parsed_notes[acc_id]
        grp = meta["family_group"]
        is_solo = bool(meta["explicit_solo"] or (grp and group_counts.get(grp, 0) == 1))

        if not logged_in:
            health = "unverified"
        elif in_cooldown:
            health = "cooldown"
        elif meta["flagged"] or remain_5h_pct <= 20 or remain_7d_pct <= 20:
            health = "warning"
        else:
            health = "ready"

        accounts.append({
            "id": acc_id,
            "label": label,
            "email": real_email,
            "note": notes.get(acc_id, ""),
            "family_group": grp,
            "is_manager": meta["is_manager"],
            "solo_group": is_solo,
            "explicit_solo": meta["explicit_solo"],
            "flagged": meta["flagged"],
            "clean_note": meta["clean_note"],
            "recommend_reason": "",
            "logged_in": logged_in,
            "calibrated": is_calibrated,
            "remain_5h_pct": remain_5h_pct,
            "remain_7d_pct": remain_7d_pct,
            "app_path": app_path,
            "app_exists": os.path.exists(app_path),
            "running": running_id == acc_id,
            "pid": running_pid if running_id == acc_id else 0,
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
            "duplicate_of": "",
        })

    # 标记同邮箱撞车实例（便于 UI 提示避免重复登录浪费配置）
    email_owners: Dict[str, str] = {}
    for a in sorted(accounts, key=lambda x: (not x["running"], not x["logged_in"], x["id"] != "main", x["id"])):
        em = str(a.get("email") or "").strip().lower()
        if em and em not in email_owners:
            email_owners[em] = a["id"]
    prefix_owners = {em.split("@", 1)[0]: oid for em, oid in email_owners.items() if "@" in em}
    for a in accounts:
        em = str(a.get("email") or "").strip().lower()
        if em and em in email_owners and email_owners[em] != a["id"]:
            a["duplicate_of"] = email_owners[em]
        elif not a.get("logged_in"):
            short_id = a["id"].split("-", 1)[-1].lower()
            if short_id in prefix_owners and prefix_owners[short_id] != a["id"]:
                a["duplicate_of"] = prefix_owners[short_id]

    ranked = pick_best_candidates(accounts, running_id)
    recommended_ids = [a["id"] for a in ranked[:6]]

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
    return accounts, recent_sessions, running_id, recommended_ids



def _atomic_write_text(target: Path, content: str) -> None:
    """临时文件 + os.replace 原子写入，防止 SMB/磁盘断流写坏目标文件。"""
    tmp = target.parent / f".{target.name}.{os.getpid()}.tmp"
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, target)


def detect_3tb_brain_dir(timeout_sec: float = 0.8) -> Optional[Path]:
    """探测本地挂载的黑苹果 3TB 知识库中心仓 (SSOT)，带超时保护防止 stale SMB 假死。"""
    vol_root = Path("/Volumes")
    try:
        mounted_names = set(os.listdir(vol_root)) if vol_root.exists() else set()
    except Exception:
        return None
    candidates = [vol_root / name for name in ("100.124.49.41", "3TB_DATA", "E") if name in mounted_names]
    if not candidates:
        return None

    def _probe() -> Optional[Path]:
        for cand in candidates:
            target = cand / "02-知识库" / "tom-brain-2026"
            try:
                if target.exists():
                    return target
            except Exception:
                continue
        return None

    ex = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    fut = ex.submit(_probe)
    try:
        res = fut.result(timeout=timeout_sec)
        ex.shutdown(wait=False)
        return res
    except Exception:
        ex.shutdown(wait=False)
        return None


def sync_handoff_to_3tb(content: str, filename: str = "HANDOFF_AUTO.md") -> Optional[str]:
    """安全原子镜像交接单至 3TB 母本，实现跨机器无缝上下文共享"""
    brain = detect_3tb_brain_dir()
    if not brain:
        return None
    try:
        dest_dir = brain / "06-Codex对话" / "AGY_Handoff"
        dest_dir.mkdir(parents=True, exist_ok=True)
        target = dest_dir / filename
        _atomic_write_text(target, content)
        latest = dest_dir / "HANDOFF_LATEST.md"
        _atomic_write_text(latest, content)
        return str(target)
    except Exception:
        return None


def generate_handoff(workspace: str, transcript_path: str = "", max_turns: int = 12, extra_note: str = "") -> dict:
    """生成 HANDOFF_AUTO.md（附带 git status 摘要与用户特别交代），归档旧交接单并复制接力词到剪贴板"""
    ws = Path(workspace)
    if not ws.exists():
        raise ValueError(f"工作区目录不存在: {workspace}")

    if not transcript_path:
        state = load_state()
        _, sessions, _, _ = list_accounts(state)
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
    if out_path.exists() and out_path.stat().st_size > 0:
        hist_dir = ws / ".handoff_history"
        hist_dir.mkdir(exist_ok=True)
        stamp = datetime.fromtimestamp(out_path.stat().st_mtime).strftime("%Y%m%d_%H%M%S")
        backup = hist_dir / f"HANDOFF_{stamp}.md"
        if backup.exists():
            backup = hist_dir / f"HANDOFF_{stamp}_{int(time.time() * 1000) % 1000:03d}.md"
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

    try:
        subprocess.run(["/usr/bin/pbcopy"], input=RELAY_PROMPT, text=True, check=False, timeout=2)
    except Exception:
        pass

    # 3TB 中心仓远程同步 (SSOT)
    tb_synced_path = sync_handoff_to_3tb("\n".join(lines), filename=f"HANDOFF_{datetime.now().strftime('%Y%m%d_%H%M%S')}.md")

    return {"handoff_path": str(out_path), "turns": len(turns), "clipboard": RELAY_PROMPT, "tb3_path": tb_synced_path}


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
    """递归合并 src 中独有的文件/子目录到 dst，绝不删除冲突未迁移文件"""
    dst.mkdir(parents=True, exist_ok=True)
    for item in list(src.iterdir()):
        target = dst / item.name
        if not target.exists():
            try:
                shutil.move(str(item), str(target))
            except Exception:
                pass
        elif item.is_dir() and target.is_dir() and not target.is_symlink():
            _merge_dir_into(item, target)
            try:
                item.rmdir()
            except OSError:
                pass


def sync_conversations(source_id: str, target_id: str):
    """
    跨账号安全同步本地会话列表与历史索引（仅在旧进程已确认退出后执行）：
    - 仅共享 conversations 与 annotations 目录（保持每个隔离账号 brain 日志统计独立，不污染轮数！）
    - 安全备份同步 conversation_summaries.db 与 agyhub_summaries_proto.pb
    """
    canonical = HOME / ".gemini" / "antigravity"
    source_ag = account_ag_dir(source_id)
    target_ag = account_ag_dir(target_id)
    if not canonical.exists():
        return
    target_ag.mkdir(parents=True, exist_ok=True)

    for dname in ("conversations", "annotations"):
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
                # 仅在目录已完全排空时才移除并建软链；若有冲突文件则移入备份目录保留，绝不丢数据
                remaining = list(d.iterdir())
                if remaining:
                    bak = ag_dir / f"{dname}.conflict_bak_{int(time.time())}"
                    d.rename(bak)
                else:
                    d.rmdir()
            try:
                d.symlink_to(canon_d)
            except Exception:
                pass

    canon_db = canonical / "conversation_summaries.db"
    src_db = source_ag / "conversation_summaries.db"
    tgt_db = target_ag / "conversation_summaries.db"

    def _db_score(p: Path) -> tuple:
        if not p.exists():
            return (0, 0.0)
        try:
            st = p.stat()
            return (1 if st.st_size > 131072 else 0, st.st_mtime)
        except Exception:
            return (0, 0.0)

    if src_db.exists() and src_db.resolve() != canon_db.resolve():
        if _db_score(src_db) > _db_score(canon_db):
            _sqlite_safe_copy(src_db, canon_db)

    if canon_db.exists() and tgt_db.resolve() != canon_db.resolve():
        _sqlite_safe_copy(canon_db, tgt_db)

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


def unify_shared_assets() -> dict:
    """
    一键无损合流并全池共享 Skills / Plugins / Rules：
    1. 将旧 ~/.gemini/antigravity/skills 及各隔离账号独有的 skills 无损合入唯一真相源 ~/.gemini/config/skills；
    2. 将各隔离账号独有的官方 plugins 与 rules 无损合入 ~/.gemini/config/{plugins,rules}；
    3. 统一将 ~/.gemini/antigravity/skills 与全部隔离实例的 skills / plugins / rules 软链指向主目录；
    4. 增量合并 config.json 中的 plugins 注册表（保留各账号独立 userSettings 与 0600 权限，绝不触碰任何 OAuth 凭据）。
    """
    canon_cfg = HOME / ".gemini" / "config"
    canon_skills = canon_cfg / "skills"
    canon_plugins = canon_cfg / "plugins"
    canon_rules = canon_cfg / "rules"
    for d in (canon_skills, canon_plugins, canon_rules):
        d.mkdir(parents=True, exist_ok=True)

    bak_root = STATE_DIR / "asset_merge_backups" / datetime.now().strftime("%Y%m%d_%H%M%S")

    def _link_to_canon(target_path: Path, canon_dir: Path, tag: str):
        target_path.parent.mkdir(parents=True, exist_ok=True)
        if target_path.is_symlink():
            try:
                if target_path.resolve() == canon_dir.resolve():
                    return
            except Exception:
                pass
            target_path.unlink()
        elif target_path.exists() and target_path.is_dir():
            if target_path.resolve() == canon_dir.resolve():
                return
            for item in list(target_path.iterdir()):
                dst_item = canon_dir / item.name
                if not dst_item.exists():
                    try:
                        shutil.move(str(item), str(dst_item))
                    except Exception:
                        pass
            remaining = list(target_path.iterdir())
            if remaining:
                bak_dir = bak_root / tag
                bak_dir.parent.mkdir(parents=True, exist_ok=True)
                target_path.rename(bak_dir)
            else:
                target_path.rmdir()
        elif target_path.exists():
            bak_dir = bak_root / tag
            bak_dir.parent.mkdir(parents=True, exist_ok=True)
            target_path.rename(bak_dir)
        target_path.symlink_to(canon_dir)

    # 1. 合流旧版 ~/.gemini/antigravity/skills
    legacy_skills = HOME / ".gemini" / "antigravity" / "skills"
    if legacy_skills.exists() or legacy_skills.is_symlink():
        _link_to_canon(legacy_skills, canon_skills, "legacy_antigravity_skills")

    # 2. 遍历全部隔离实例，合流并软链 skills / plugins / rules + 公共 npm 缓存
    inst_dirs = [d for d in MULTI_DIR.iterdir() if d.is_dir()] if MULTI_DIR.exists() else []
    npm_cache = HOME / ".npm"
    for inst in inst_dirs:
        _link_to_canon(inst / ".gemini" / "config" / "skills", canon_skills, f"{inst.name}_skills")
        _link_to_canon(inst / ".gemini" / "config" / "plugins", canon_plugins, f"{inst.name}_plugins")
        _link_to_canon(inst / ".gemini" / "config" / "rules", canon_rules, f"{inst.name}_rules")
        inst_npm = inst / ".npm"
        if npm_cache.exists() and not inst_npm.exists() and not inst_npm.is_symlink():
            try:
                inst_npm.symlink_to(npm_cache)
            except Exception:
                pass

    # 3. 增量合流各账号 config.json 中的 plugins 启用注册表
    cfg_paths = [canon_cfg / "config.json"] + [d / ".gemini" / "config" / "config.json" for d in inst_dirs]
    merged_plugins = {}
    for cp in cfg_paths:
        if cp.is_file():
            try:
                obj = json.loads(cp.read_text(encoding="utf-8"))
                if isinstance(obj, dict) and isinstance(obj.get("plugins"), dict):
                    for pk, pv in obj["plugins"].items():
                        if isinstance(pv, dict):
                            cur = merged_plugins.setdefault(pk, {})
                            cur.update(pv)
            except Exception:
                pass

    if merged_plugins:
        for cp in cfg_paths:
            cp.parent.mkdir(parents=True, exist_ok=True)
            doc = {}
            if cp.is_file():
                try:
                    loaded = json.loads(cp.read_text(encoding="utf-8"))
                    if isinstance(loaded, dict):
                        doc = loaded
                except Exception:
                    doc = {}
            cur_p = doc.get("plugins") if isinstance(doc.get("plugins"), dict) else {}
            changed = False
            for pk, pv in merged_plugins.items():
                if pk not in cur_p:
                    cur_p[pk] = dict(pv)
                    changed = True
            if changed or not cp.exists():
                doc["plugins"] = cur_p
                tmp = cp.parent / f".config.json.{os.getpid()}.tmp"
                tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
                os.chmod(tmp, 0o600)
                os.replace(tmp, cp)

    skill_cnt = len([p for p in canon_skills.iterdir() if p.is_dir() and not p.name.startswith(".")])
    plugin_cnt = len([p for p in canon_plugins.iterdir() if p.is_dir() and not p.name.startswith(".")])
    return {
        "ok": True,
        "instances_synced": len(inst_dirs),
        "skills_count": skill_cnt,
        "plugins_count": plugin_cnt,
    }



def read_cached_network_status(max_age_sec: float = NET_CACHE_TTL) -> Optional[dict]:
    """零阻塞读取最近一次网络哨兵缓存（--cli-status 专用，绝不在主刷新路径做公网 I/O）。"""
    if not NET_CACHE_FILE.exists():
        return None
    try:
        data = json.loads(NET_CACHE_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return None
        ts = float(data.get("checked_ts", 0) or 0)
        if max_age_sec > 0 and (time.time() - ts) > max_age_sec:
            return None
        return data
    except Exception:
        return None


def _save_network_cache(payload: dict) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        _atomic_write_text(NET_CACHE_FILE, json.dumps(payload, ensure_ascii=False))
    except Exception:
        pass


def probe_network_quality(save_cache: bool = True) -> dict:
    """
    并发探测当前代理与出口网络质量（3 路并发，单路超时 2s，总耗时通常 < 0.8s）：
    1. 测 antigravity.google 官方鉴权端点；
    2. 测 accounts.google.com 登录通行证；
    3. 测出口 IP 与国家/地区（避开 HK/CN/RU/IR 等受限区，并容错 ipinfo.io 限流）。
    """
    result = {
        "ok": False,
        "exit_ip": "",
        "country": "",
        "region": "",
        "org": "",
        "latency_ms": 0,
        "antigravity_ok": False,
        "auth_ok": False,
        "clean_for_antigravity": False,
        "error_message": "",
        "checked_ts": time.time(),
    }

    def _check_ag():
        t0 = time.time()
        req = urllib.request.Request("https://antigravity.google/favicon.svg", headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            return resp.status == 200, int((time.time() - t0) * 1000)

    def _check_auth():
        req = urllib.request.Request("https://accounts.google.com/generate_204", headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            return resp.status == 204

    def _check_ip():
        req = urllib.request.Request("https://ipinfo.io/json", headers={"User-Agent": "curl/7.68.0"})
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            return json.loads(resp.read().decode())

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
        f_ag = ex.submit(_check_ag)
        f_auth = ex.submit(_check_auth)
        f_ip = ex.submit(_check_ip)

        try:
            ag_ok, lat = f_ag.result(timeout=2.5)
            result["antigravity_ok"] = ag_ok
            result["latency_ms"] = lat
        except Exception as e:
            result["error_message"] = f"反重力鉴权连接失败: {e}"

        try:
            result["auth_ok"] = bool(f_auth.result(timeout=2.5))
        except Exception as e:
            if not result["error_message"]:
                result["error_message"] = f"Google 登录通道不可达: {e}"

        try:
            ip_data = f_ip.result(timeout=2.5)
            if isinstance(ip_data, dict):
                result["exit_ip"] = str(ip_data.get("ip", "") or "")
                result["country"] = str(ip_data.get("country", "") or "").upper()
                result["region"] = f"{ip_data.get('city', '')}, {ip_data.get('region', '')}".strip(", ")
                result["org"] = str(ip_data.get("org", "") or "")
        except Exception:
            pass

    blocked_regions = {"HK", "CN", "RU", "IR"}
    is_blocked = result["country"] in blocked_regions
    if is_blocked and not result["error_message"]:
        result["error_message"] = f"当前出口地区 ({result['country']}) 不支持 Antigravity，请切换美/日/台/新节点"
    result["ok"] = bool(result["antigravity_ok"] or result["auth_ok"])
    result["clean_for_antigravity"] = bool(result["antigravity_ok"] and result["auth_ok"] and not is_blocked)
    if save_cache:
        _save_network_cache(result)
    return result


class _UnixHTTPConnection(http.client.HTTPConnection):
    """通过 Unix Domain Socket 连接本地 Clash Verge Mihomo 控制接口（零外部依赖）。"""

    def __init__(self, socket_path: str, timeout: float = 2.0):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


def detect_clash_socket() -> str:
    env_sock = os.environ.get("AGY_CLASH_SOCKET", "").strip()
    if env_sock:
        return env_sock if os.path.exists(env_sock) else ""
    uid = os.getuid()
    direct = f"/var/run/clash-verge-service/users/{uid}/verge-mihomo.sock"
    if os.path.exists(direct):
        return direct
    for p in sorted(glob.glob("/var/run/clash-verge-service/users/*/verge-mihomo.sock")):
        if os.path.exists(p):
            return p
    return ""


def _clash_request(sock_path: str, method: str, path: str, body: Optional[dict] = None, timeout: float = 2.0):
    conn = _UnixHTTPConnection(sock_path, timeout=timeout)
    try:
        headers = {"Host": "localhost"}
        payload = None
        if body is not None:
            payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        data = json.loads(raw.decode("utf-8")) if raw else {}
        return resp.status, data
    finally:
        conn.close()


def _pick_primary_clash_group(proxies: dict) -> Optional[str]:
    """优先匹配 AI / Gemini / 自动选择代理组（兼容不同 emoji 或命名）。"""
    keywords = ("gemini", "ai", "自动", "select", "proxy")
    selectors = [
        (name, info)
        for name, info in proxies.items()
        if isinstance(info, dict) and info.get("type") in ("Selector", "URLTest") and name != "GLOBAL"
    ]
    for kw in keywords:
        for name, _ in selectors:
            if kw in name.lower():
                return name
    return selectors[0][0] if selectors else None


def _is_blocked_node_name(name: str) -> bool:
    low = name.lower()
    return any(tok in low for tok in ("香港", "hk", "hong kong", "china", "cn", "russia", "ru", "iran", "direct", "reject", "剩余", "套餐", "过期", "官网"))


def get_clash_status() -> dict:
    sock_path = detect_clash_socket()
    if not sock_path:
        return {"available": False, "active_group": "", "active_node": "", "delay_ms": 0, "candidates": []}
    try:
        status_code, data = _clash_request(sock_path, "GET", "/proxies", timeout=1.2)
        if status_code != 200 or not isinstance(data, dict):
            return {"available": False, "active_group": "", "active_node": "", "delay_ms": 0, "candidates": []}
        proxies = data.get("proxies", {})
        group_name = _pick_primary_clash_group(proxies)
        if not group_name or group_name not in proxies:
            return {"available": False, "active_group": "", "active_node": "", "delay_ms": 0, "candidates": []}

        ginfo = proxies[group_name]
        active_node = str(ginfo.get("now") or "")
        active_hist = (proxies.get(active_node) or {}).get("history") or []
        active_delay = int(active_hist[-1].get("delay", 0)) if active_hist else 0

        candidates = []
        for n in ginfo.get("all", []):
            if _is_blocked_node_name(n):
                continue
            ninfo = proxies.get(n) or {}
            hist = ninfo.get("history") or []
            delay = int(hist[-1].get("delay", 0)) if hist else 0
            if delay > 0 or n == active_node:
                candidates.append({
                    "name": n,
                    "delay_ms": delay,
                    "type": str(ninfo.get("type") or ""),
                    "selected": (n == active_node),
                })
        candidates.sort(key=lambda c: (not c["selected"], c["delay_ms"] if c["delay_ms"] > 0 else 99999, c["name"]))
        return {
            "available": True,
            "active_group": group_name,
            "active_node": active_node,
            "delay_ms": active_delay,
            "candidates": candidates[:8],
        }
    except Exception:
        return {"available": False, "active_group": "", "active_node": "", "delay_ms": 0, "candidates": []}


def switch_clash_node(node: str, group: str = "") -> dict:
    sock_path = detect_clash_socket()
    if not sock_path:
        return {"error": "未检测到本地 Clash Verge 控制通道 (verge-mihomo.sock)"}
    try:
        code, data = _clash_request(sock_path, "GET", "/proxies", timeout=1.5)
        if code != 200:
            return {"error": f"读取 Clash 代理组失败 (HTTP {code})"}
        proxies = data.get("proxies", {})
        target_group = group or _pick_primary_clash_group(proxies) or ""
        if not target_group or target_group not in proxies:
            return {"error": "未找到可用的 Clash 代理组"}
        enc_group = urllib.parse.quote(target_group, safe="")
        put_code, _ = _clash_request(sock_path, "PUT", f"/proxies/{enc_group}", body={"name": node}, timeout=1.5)
        if put_code not in (200, 204):
            return {"error": f"切换节点失败 (HTTP {put_code})"}
        net = probe_network_quality(save_cache=True)
        return {"ok": True, "group": target_group, "node": node, "network": net, "clash": get_clash_status()}
    except Exception as e:
        return {"error": f"切换 Clash 节点异常: {e}"}


def auto_select_clash_node(group: str = "") -> dict:
    """并发用 antigravity.google/favicon.svg 对当前代理组候选节点测活，自动切换至最低延迟健康节点。"""
    sock_path = detect_clash_socket()
    if not sock_path:
        return {"error": "未检测到本地 Clash Verge 控制通道 (verge-mihomo.sock)"}
    try:
        code, data = _clash_request(sock_path, "GET", "/proxies", timeout=1.5)
        if code != 200:
            return {"error": f"读取 Clash 代理组失败 (HTTP {code})"}
        proxies = data.get("proxies", {})
        target_group = group or _pick_primary_clash_group(proxies) or ""
        if not target_group or target_group not in proxies:
            return {"error": "未找到可用的 Clash 代理组"}

        all_nodes = [n for n in proxies[target_group].get("all", []) if not _is_blocked_node_name(n)]
        if not all_nodes:
            return {"error": f"代理组 {target_group} 中没有可测速的合规节点"}

        def _probe_one(node_name: str):
            enc_n = urllib.parse.quote(node_name, safe="")
            q_url = urllib.parse.quote("https://antigravity.google/favicon.svg", safe="")
            try:
                sc, res = _clash_request(sock_path, "GET", f"/proxies/{enc_n}/delay?timeout=2500&url={q_url}", timeout=3.2)
                if sc == 200 and isinstance(res, dict) and int(res.get("delay", 0)) > 0:
                    return (node_name, int(res["delay"]))
            except Exception:
                pass
            return None

        healthy = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
            for item in ex.map(_probe_one, all_nodes[:24]):
                if item:
                    healthy.append(item)

        if not healthy:
            return {"error": f"代理组 {target_group} 中所有候选节点均无法连通 Antigravity"}
        healthy.sort(key=lambda x: x[1])
        best_node, best_delay = healthy[0]
        res = switch_clash_node(best_node, group=target_group)
        if res.get("ok"):
            res["best_delay_ms"] = best_delay
        return res
    except Exception as e:
        return {"error": f"自动优选 Clash 节点失败: {e}"}


def perform_switch(
    target_app: str,
    target_label: str,
    source_id: str = "",
    target_id: str = "",
    auto_paste: bool = False,
    is_login: bool = False,
) -> None:
    """
    安全切号编排（在 state_lock 之外运行，不阻塞状态查询）：
    1. 发送优雅退出 -> 轮询最多 6 秒；
    2. 若仍未退出，向该主进程发送 SIGTERM 再等 2 秒；
    3. 若依然未退出，抛出异常中止拉起新号，彻底杜绝双实例并发串号！
    """
    rid, pid = detect_running_instance()
    if rid:
        try:
            subprocess.run(
                ["/usr/bin/osascript", "-e", 'tell application "Antigravity" to quit'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
        except Exception:
            pass

        for _ in range(24):
            rid, pid = detect_running_instance()
            if not rid:
                break
            time.sleep(0.25)

        if rid and pid > 0:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
            for _ in range(8):
                rid, _ = detect_running_instance()
                if not rid:
                    break
                time.sleep(0.25)

        if rid:
            raise RuntimeError(f"旧实例 ({rid}) 未完全退出，已中止启动新号以防 Keychain 串号，请先保存并关闭当前窗口后重试")

    if target_id:
        try:
            unify_shared_assets()
            sync_conversations(source_id or "main", target_id)
        except Exception:
            pass

    time.sleep(0.25)
    subprocess.Popen(["/usr/bin/open", "-n", target_app])
    if is_login:
        notify_macos(f"已拉起 {target_label} 登录窗口，请完成 Google 授权登录")
    else:
        notify_macos(f"已切换到 {target_label}，接力词已复制，Cmd+V 即可继续")

    # 自动粘贴辅助：默认关闭；仅当用户显式开启、非「去登录」且最前窗口确为 Antigravity 时触发，绝不误贴到其他应用
    if auto_paste and not is_login:
        try:
            auto_paste_script = (
                'delay 2.5\n'
                'tell application "System Events"\n'
                '    set frontApp to name of first application process whose frontmost is true\n'
                '    if frontApp is "Antigravity" then\n'
                '        keystroke "v" using {command down}\n'
                '    end if\n'
                'end tell'
            )
            subprocess.Popen(["/usr/bin/osascript", "-e", auto_paste_script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def add_account(acc_id: str, note: str, state: dict) -> dict:
    """新建隔离账号实例 + 公共环境软链 + 桌面 .app 启动器"""
    acc_id = validate_isolated_acc_id(acc_id)

    inst_dir = MULTI_DIR / acc_id
    app_bundle = APP_DIR / f"Antigravity-{acc_id}.app"
    if inst_dir.exists() or app_bundle.exists():
        raise ValueError(f"账号 {acc_id} 已存在")

    (inst_dir / ".gemini" / "config").mkdir(parents=True, exist_ok=True)
    (inst_dir / "data").mkdir(parents=True, exist_ok=True)
    for rel in [".zshrc", ".zprofile", ".gitconfig", ".ssh", ".local", ".visionpower", ".config", ".npm"]:
        src = HOME / rel
        dst = inst_dir / rel
        if src.exists() and not dst.exists() and not dst.is_symlink():
            os.symlink(str(src), str(dst))
    for cfg_sub in ("skills", "plugins", "rules"):
        c_src = HOME / ".gemini" / "config" / cfg_sub
        c_src.mkdir(parents=True, exist_ok=True)
        c_dst = inst_dir / ".gemini" / "config" / cfg_sub
        if not c_dst.exists() and not c_dst.is_symlink():
            os.symlink(str(c_src), str(c_dst))

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
exec "/Applications/Antigravity.app/Contents/MacOS/Antigravity" --user-data-dir="{inst_dir}/data" "$@"
""",
        encoding="utf-8",
    )
    os.chmod(launcher, 0o755)

    if note.strip():
        state.setdefault("notes", {})[acc_id] = note.strip()
        save_state(state)
    return {"ok": True, "id": acc_id, "app_path": str(app_bundle)}


def delete_account(acc_id: str, state: dict) -> dict:
    """安全删除隔离账号：白名单路径校验后移入 ~/.Trash 防误删"""
    acc_id = validate_isolated_acc_id(acc_id)
    trash = HOME / ".Trash"
    trash.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    inst_dir = MULTI_DIR / acc_id
    app_bundle = APP_DIR / f"Antigravity-{acc_id}.app"
    if inst_dir.exists():
        inst_dir.rename(trash / f"agy_inst_{acc_id}_{stamp}")
    if app_bundle.exists():
        app_bundle.rename(trash / f"Antigravity-{acc_id}_{stamp}.app")
    state.setdefault("cooldowns", {}).pop(acc_id, None)
    state.setdefault("notes", {}).pop(acc_id, None)
    state.setdefault("calibrations", {}).pop(acc_id, None)
    save_state(state)
    return {"ok": True, "deleted": acc_id}


def run_doctor(state: dict) -> dict:
    """本地运行环境 7 项深度体检"""
    checks = []

    running_procs = []
    try:
        out = subprocess.check_output(["ps", "-eo", "pid,rss,command"], text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            if (
                "Antigravity.app/Contents/MacOS/Electron" in line
                or "Antigravity.app/Contents/MacOS/Antigravity" in line
            ) and "--type=" not in line:
                parts = line.strip().split(None, 2)
                if len(parts) >= 2:
                    running_procs.append((int(parts[0]), round(int(parts[1]) / 1024, 1)))
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

    inst_dirs = [d for d in MULTI_DIR.iterdir() if d.is_dir()] if MULTI_DIR.exists() else []
    missing_apps = [d.name for d in inst_dirs if not (APP_DIR / f"Antigravity-{d.name}.app").exists()]
    if not inst_dirs:
        checks.append({"name": "多开隔离实例", "status": "warn", "detail": f"未在 {MULTI_DIR} 找到隔离实例"})
    elif not missing_apps:
        checks.append({"name": "多开启动器 (.app)", "status": "ok", "detail": f"{len(inst_dirs)}/{len(inst_dirs)} 个隔离实例均有对应桌面启动器"})
    else:
        checks.append({"name": "多开启动器 (.app)", "status": "error", "detail": f"缺少启动器: {', '.join(missing_apps[:3])}"})

    canon_skills_real = (HOME / ".gemini" / "config" / "skills").resolve()
    canon_plugins_real = (HOME / ".gemini" / "config" / "plugins").resolve()
    misaligned_skills = [
        d.name for d in inst_dirs
        if not (d / ".gemini" / "config" / "skills").exists()
        or (d / ".gemini" / "config" / "skills").resolve() != canon_skills_real
    ]
    misaligned_plugins = [
        d.name for d in inst_dirs
        if not (d / ".gemini" / "config" / "plugins").exists()
        or (d / ".gemini" / "config" / "plugins").resolve() != canon_plugins_real
    ]
    skill_cnt = len([p for p in canon_skills_real.iterdir() if p.is_dir() and not p.name.startswith(".")]) if canon_skills_real.exists() else 0
    plugin_cnt = len([p for p in canon_plugins_real.iterdir() if p.is_dir() and not p.name.startswith(".")]) if canon_plugins_real.exists() else 0

    if not misaligned_skills and not misaligned_plugins:
        checks.append({
            "name": "全账号 Skills 与官方插件共享",
            "status": "ok",
            "detail": f"全部 {len(inst_dirs)} 个隔离实例已统一共享 {skill_cnt} 个 Skills 与 {plugin_cnt} 个官方插件",
        })
    else:
        issues = []
        if misaligned_skills:
            issues.append(f"Skills 未统一({len(misaligned_skills)}个)")
        if misaligned_plugins:
            issues.append(f"Plugins 未共享({len(misaligned_plugins)}个)")
        checks.append({
            "name": "全账号 Skills 与官方插件共享",
            "status": "warn",
            "detail": f"检测到 {', '.join(issues)}，点击右上角「一键对齐 Skills 与插件」即可全池打通",
        })

    ws = Path(state.get("workspace", DEFAULT_WORKSPACE))
    hf = ws / "HANDOFF_AUTO.md"
    if not ws.exists():
        checks.append({"name": "接力工作区与交接单", "status": "error", "detail": f"工作区目录不存在: {ws}"})
    elif hf.exists():
        upd = datetime.fromtimestamp(hf.stat().st_mtime).strftime("%m-%d %H:%M")
        kb = round(hf.stat().st_size / 1024, 1)
        checks.append({"name": "接力工作区与交接单", "status": "ok", "detail": f"工作区正常 · HANDOFF_AUTO.md 就绪 ({kb} KB, 更新于 {upd})"})
    else:
        checks.append({"name": "接力工作区与交接单", "status": "warn", "detail": "工作区正常，但尚未生成 HANDOFF_AUTO.md"})

    shared_brains = [d.name for d in inst_dirs if (d / ".gemini" / "antigravity" / "brain").is_symlink()]
    if not shared_brains:
        checks.append({"name": "对话日志隔离 (brain)", "status": "ok", "detail": "所有隔离实例均拥有独立 brain 日志目录"})
    else:
        checks.append({"name": "对话日志隔离 (brain)", "status": "warn", "detail": f"{', '.join(shared_brains)} 的历史 brain 软链到了主账号（v5.0 新切号仅共享 conversations 索引，不再软链 brain）"})

    notes = state.get("notes") or {}
    flagged_accs = [k for k, v in notes.items() if parse_family_meta(v)["flagged"]]
    grouped_accs = [k for k, v in notes.items() if parse_family_meta(v)["family_group"]]
    if flagged_accs:
        checks.append({
            "name": "家庭组与风控标记",
            "status": "warn",
            "detail": f"已标注 {len(grouped_accs)} 个家庭组账号；检测到异常/待验证标记：{', '.join(flagged_accs)}（自动选号已跳过）",
        })
    else:
        checks.append({
            "name": "家庭组与风控标记",
            "status": "ok",
            "detail": f"已标注 {len(grouped_accs)} 个家庭组账号，无风控或二次验证警告",
        })

    relay_bin = HOME / ".local" / "bin" / "agy-relay"
    if relay_bin.exists() and os.access(relay_bin, os.X_OK):
        checks.append({"name": "agy-relay 接力脚本", "status": "ok", "detail": f"就绪 ({relay_bin})"})
    else:
        checks.append({"name": "agy-relay 接力脚本", "status": "warn", "detail": "未找到 ~/.local/bin/agy-relay（不影响本 App 内置接力）"})

    tb3_dir = detect_3tb_brain_dir()
    if tb3_dir:
        checks.append({"name": "3TB 中心仓 (SSOT)", "status": "ok", "detail": f"已在线挂载 ({tb3_dir})，交接单自动原子镜像"})
    else:
        checks.append({"name": "3TB 中心仓 (SSOT)", "status": "warn", "detail": "未检测到 3TB SMB 挂载卷（交接单仍保存在本地，不影响切号）"})

    net = probe_network_quality(save_cache=True)
    if net.get("clean_for_antigravity"):
        region_txt = f"{net.get('country') or '未知地区'} {net.get('region') or ''}".strip()
        checks.append({"name": "反重力代理节点哨兵", "status": "ok", "detail": f"鉴权通道畅通 · {region_txt} ({net.get('latency_ms', 0)}ms · {net.get('exit_ip') or 'IP未知'})"})
    else:
        err_txt = net.get("error_message") or f"出口地区 ({net.get('country') or '未知'}) 或鉴权异常"
        checks.append({"name": "反重力代理节点哨兵", "status": "error", "detail": f"{err_txt} · 请在 Clash Verge 切至美/日有效节点"})

    return {
        "checked_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "checks": checks,
    }


def _read_state_snapshot() -> dict:
    with state_lock(shared=True):
        return load_state()


def main():
    parser = argparse.ArgumentParser(description="AGY Switch v5.7 CLI Engine")
    parser.add_argument("--cli-status", action="store_true", help="输出当前账号池状态 JSON（零公网阻塞）")
    parser.add_argument("--cli-network", action="store_true", help="并发探测当前代理节点与反重力鉴权通道并刷新缓存")
    parser.add_argument("--cli-clash-switch", nargs=2, metavar=("GROUP", "NODE"), help="切换指定 Clash 代理组节点（GROUP 可为空串自动匹配）")
    parser.add_argument("--cli-clash-auto", nargs="?", const="", default=None, metavar="GROUP", help="自动对当前代理组节点并发测活并切至最快健康节点")
    parser.add_argument("--cli-doctor", action="store_true", help="输出本地运行环境体检 JSON")
    parser.add_argument("--cli-sync-assets", action="store_true", help="一键合流并全池共享 Skills / Plugins / Rules")
    parser.add_argument("--cli-add", nargs=2, metavar=("ACC_ID", "NOTE"), help="新增隔离账号实例与启动器")
    parser.add_argument("--cli-delete", metavar="ACC_ID", help="安全删除隔离账号（移入废纸篓）")
    parser.add_argument("--cli-note", nargs=2, metavar=("ACC_ID", "NOTE"), help="更新账号备注")
    parser.add_argument("--cli-calibrate", nargs=3, metavar=("ACC_ID", "PCT_5H", "PCT_7D"), help="校准账号真实剩余百分比")
    parser.add_argument("--cli-autostart", choices=["status", "on", "off"], help="查询或开关 macOS 开机自启")
    parser.add_argument("--cli-autopaste", choices=["status", "on", "off"], help="查询或开关切号后自动粘贴接力词")
    parser.add_argument("--cli-handoff", action="store_true", help="生成 HANDOFF_AUTO.md 并复制接力词")
    parser.add_argument("--cli-handoff-save", nargs=2, metavar=("TRANSCRIPT", "NOTE"), help="按指定日志与特别交代生成交接单")
    parser.add_argument("--cli-config", nargs=3, metavar=("WORKSPACE", "LIMIT_5H", "LIMIT_7D"), help="更新工作区与预警阈值")
    parser.add_argument("--cli-switch", nargs="?", const="", default=None, help="一键切换账号（空串=跨家庭组智能选满血号）")
    parser.add_argument("--force", action="store_true", help="配合 --cli-switch 跳过网络哨兵拦截强制启动")
    parser.add_argument("--cli-cooldown", nargs=2, metavar=("ACC_ID", "HOURS"), help="设置账号冷却小时数（0=恢复满血）")
    parser.add_argument("--cli-clear-cooldowns", action="store_true", help="一键解除全部账号冷却")
    parser.add_argument("--cli-restore-handoff", metavar="FILENAME", help="从 .handoff_history 恢复指定交接单")
    parser.add_argument("--cli-workspaces", nargs=2, metavar=("ACTION", "PATH"), help="管理常用工作区列表 (add|use|remove)")
    args = parser.parse_args()

    try:
        if args.cli_network:
            net = probe_network_quality(save_cache=True)
            net["clash"] = get_clash_status()
            print(json.dumps(net, ensure_ascii=False))
            return

        if args.cli_clash_switch:
            grp, node = args.cli_clash_switch
            print(json.dumps(switch_clash_node(node=node, group=grp), ensure_ascii=False))
            return

        if args.cli_clash_auto is not None:
            print(json.dumps(auto_select_clash_node(group=args.cli_clash_auto), ensure_ascii=False))
            return

        if args.cli_autopaste:
            if args.cli_autopaste == "status":
                st = _read_state_snapshot()
                print(json.dumps({"enabled": bool(st.get("auto_paste", False))}, ensure_ascii=False))
            else:
                enabled = args.cli_autopaste == "on"
                with state_lock(shared=False):
                    st = load_state()
                    st["auto_paste"] = enabled
                    save_state(st)
                print(json.dumps({"ok": True, "enabled": enabled}, ensure_ascii=False))
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

        # 只读命令：毫秒级读取快照后立即释放共享锁，绝不阻塞并发写操作
        if args.cli_doctor:
            state = _read_state_snapshot()
            print(json.dumps(run_doctor(state), ensure_ascii=False))
            return

        if args.cli_sync_assets:
            with state_lock(shared=False):
                print(json.dumps(unify_shared_assets(), ensure_ascii=False))
            return

        if args.cli_status:
            state = _read_state_snapshot()
            ws = state.get("workspace", DEFAULT_WORKSPACE)
            accounts, sessions, running_id, recommended_ids = list_accounts(state)
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
            ws_list = list(dict.fromkeys([ws] + [w for w in (state.get("workspaces") or []) if w]))
            tb3_dir = detect_3tb_brain_dir()
            cached_net = read_cached_network_status(max_age_sec=300.0)
            print(json.dumps({
                "version": APP_VERSION,
                "relay_prompt": RELAY_PROMPT,
                "workspace": ws,
                "workspaces": ws_list,
                "running_id": running_id,
                "recommended_ids": recommended_ids,
                "accounts": accounts,
                "sessions": sessions[:8],
                "warn_5h_limit": int(state.get("warn_5h_limit", WARN_5H_LIMIT)),
                "warn_7d_limit": int(state.get("warn_7d_limit", WARN_7D_LIMIT)),
                "handoff_preview": hf_preview,
                "handoff_updated": hf_updated,
                "handoff_history": hist_items,
                "last_switch": state.get("last_switch", ""),
                "switch_history": (state.get("switch_history") or [])[:10],
                "auto_paste": bool(state.get("auto_paste", False)),
                "tb3_online": bool(tb3_dir),
                "tb3_mount": str(tb3_dir or ""),
                "network": cached_net,
                "clash": get_clash_status(),
            }, ensure_ascii=False))
            return

        if args.cli_restore_handoff:
            state = _read_state_snapshot()
            ws = Path(state.get("workspace", DEFAULT_WORKSPACE))
            fname = os.path.basename(args.cli_restore_handoff)
            src = ws / ".handoff_history" / fname
            if not fname or not src.is_file():
                print(json.dumps({"error": "历史交接单不存在"}, ensure_ascii=False))
                return
            (ws / "HANDOFF_AUTO.md").write_bytes(src.read_bytes())
            try:
                subprocess.run(["/usr/bin/pbcopy"], input=RELAY_PROMPT, text=True, check=False, timeout=2)
            except Exception:
                pass
            print(json.dumps({"ok": True, "restored": src.name}, ensure_ascii=False))
            return

        if args.cli_handoff_save:
            state = _read_state_snapshot()
            tr, note = args.cli_handoff_save
            res = generate_handoff(state.get("workspace", DEFAULT_WORKSPACE), tr, extra_note=note)
            print(json.dumps({"ok": True, **res}, ensure_ascii=False))
            return

        if args.cli_handoff:
            state = _read_state_snapshot()
            res = generate_handoff(state.get("workspace", DEFAULT_WORKSPACE))
            print(json.dumps({"ok": True, **res}, ensure_ascii=False))
            return

        # 切号命令：先在锁外扫描并执行退旧号/拉新号，仅在切换真正成功后的毫秒级临界区内写入 state.json！
        if args.cli_switch is not None:
            target_id = args.cli_switch.strip()
            snap = _read_state_snapshot()
            accounts, sessions, running_id, _ = list_accounts(snap)
            if not target_id:
                ranked = pick_best_candidates(accounts, running_id)
                if not ranked:
                    print(json.dumps({"error": "没有可用的已登录账号（请检查冷却或风控状态）"}, ensure_ascii=False))
                    return
                target = ranked[0]
            else:
                if target_id != "main":
                    target_id = validate_isolated_acc_id(target_id)
                matched = [a for a in accounts if a["id"] == target_id]
                if not matched:
                    print(json.dumps({"error": f"未找到账号 {target_id}"}, ensure_ascii=False))
                    return
                target = matched[0]
                if not target["app_exists"]:
                    print(json.dumps({"error": f"桌面启动器不存在: {target['app_path']}"}, ensure_ascii=False))
                    return

            is_login = not bool(target.get("logged_in", False))

            # 启动前节点健康前置拦截：支持 --force 强制旁路；未登录账号「去登录」仅告警不硬阻断
            if not args.force and not is_login:
                net_status = probe_network_quality(save_cache=True)
                if not net_status.get("clean_for_antigravity", False):
                    err_tip = net_status.get("error_message") or f"当前代理节点处于不可用地区({net_status.get('country') or '未知'})或鉴权失败"
                    print(json.dumps({
                        "error": f"节点网络异常，已拦截启动：{err_tip}。请在 Clash Verge 切换至有效美国/日本节点后重试！",
                        "code": "NETWORK_BLOCKED",
                        "target_id": target["id"],
                        "network": net_status,
                    }, ensure_ascii=False))
                    return

            ws = snap.get("workspace", DEFAULT_WORKSPACE)
            latest_tr = sessions[0]["path"] if sessions else ""
            if not is_login:
                try:
                    generate_handoff(ws, transcript_path=latest_tr)
                except Exception:
                    pass

            # 先执行安全退出与拉起（若旧实例拒绝退出则抛异常直接返回 error，不污染冷却与历史状态！）
            perform_switch(
                target["app_path"],
                target["label"],
                running_id or "main",
                target["id"],
                auto_paste=bool(snap.get("auto_paste", False)),
                is_login=is_login,
            )

            src_acc = next((a for a in accounts if a["id"] == running_id), None)
            src_grp = src_acc["family_group"] if src_acc else ""
            tgt_grp = target["family_group"]
            cross_group = bool(not src_grp or not tgt_grp or src_grp != tgt_grp)
            now_fmt = datetime.now().strftime("%m-%d %H:%M")
            reason_str = target.get("recommend_reason") or "手动指定"

            with state_lock(shared=False):
                state = load_state()
                if running_id and running_id != target["id"]:
                    state.setdefault("cooldowns", {})[running_id] = time.time() + 5 * 3600
                state["last_switch"] = f"{now_fmt} · {running_id or '无'} → {target['id']}"
                hist = list(state.get("switch_history") or [])
                hist.insert(0, {
                    "time": now_fmt,
                    "from_id": running_id or "无",
                    "to_id": target["id"],
                    "from_group": src_grp,
                    "to_group": tgt_grp,
                    "cross_group": cross_group,
                    "reason": reason_str,
                })
                state["switch_history"] = hist[:15]
                save_state(state)

            print(json.dumps({
                "ok": True,
                "switched_to": target["label"],
                "target_id": target["id"],
                "reason": reason_str,
                "cross_group": cross_group,
            }, ensure_ascii=False))
            return

        # 其余纯状态修改命令：极短排他锁临界区
        with state_lock(shared=False):
            state = load_state()

            if args.cli_add:
                print(json.dumps(add_account(args.cli_add[0], args.cli_add[1], state), ensure_ascii=False))
                return

            if args.cli_delete:
                print(json.dumps(delete_account(args.cli_delete, state), ensure_ascii=False))
                return

            if args.cli_calibrate:
                acc_id, p5, p7 = args.cli_calibrate
                if acc_id != "main":
                    acc_id = validate_isolated_acc_id(acc_id)
                accounts, _, _, _ = list_accounts(state)
                matched = [a for a in accounts if a["id"] == acc_id]
                base_5h = matched[0]["turns_5h"] if matched else 0
                base_7d = matched[0]["turns_7d"] if matched else 0
                state.setdefault("calibrations", {})[acc_id] = {
                    "pct_5h": max(0, min(100, int(float(p5)))),
                    "pct_7d": max(0, min(100, int(float(p7)))),
                    "base_5h": base_5h,
                    "base_7d": base_7d,
                    "ts": time.time(),
                    "updated_at": datetime.now().strftime("%m-%d %H:%M"),
                }
                save_state(state)
                print(json.dumps({"ok": True}, ensure_ascii=False))
                return

            if args.cli_note:
                acc_id, note = args.cli_note
                if acc_id != "main":
                    acc_id = validate_isolated_acc_id(acc_id)
                if note.strip():
                    state.setdefault("notes", {})[acc_id] = note.strip()
                else:
                    state.setdefault("notes", {}).pop(acc_id, None)
                save_state(state)
                print(json.dumps({"ok": True}, ensure_ascii=False))
                return

            if args.cli_workspaces:
                act, path_val = args.cli_workspaces
                path_val = path_val.strip()
                ws_list = list(state.get("workspaces") or [DEFAULT_WORKSPACE])
                if act in ("add", "use"):
                    if not os.path.isdir(path_val):
                        raise ValueError(f"工作区目录不存在: {path_val}")
                    if path_val not in ws_list:
                        ws_list.append(path_val)
                    state["workspaces"] = ws_list
                    state["workspace"] = path_val
                    save_state(state)
                elif act == "remove":
                    ws_list = [w for w in ws_list if w != path_val] or [DEFAULT_WORKSPACE]
                    state["workspaces"] = ws_list
                    if state.get("workspace") == path_val:
                        state["workspace"] = ws_list[0]
                    save_state(state)
                print(json.dumps({"ok": True, "workspace": state["workspace"], "workspaces": state.get("workspaces", ws_list)}, ensure_ascii=False))
                return

            if args.cli_config:
                ws, l5, l7 = args.cli_config
                if ws and os.path.isdir(ws):
                    state["workspace"] = ws
                state["warn_5h_limit"] = max(10, int(float(l5)))
                state["warn_7d_limit"] = max(50, int(float(l7)))
                save_state(state)
                print(json.dumps({"ok": True}, ensure_ascii=False))
                return

            if args.cli_clear_cooldowns:
                state["cooldowns"] = {}
                save_state(state)
                print(json.dumps({"ok": True}, ensure_ascii=False))
                return

            if args.cli_cooldown:
                acc_id, hours_str = args.cli_cooldown
                if acc_id != "main":
                    acc_id = validate_isolated_acc_id(acc_id)
                hours = float(hours_str)
                if hours <= 0:
                    state.setdefault("cooldowns", {}).pop(acc_id, None)
                else:
                    state.setdefault("cooldowns", {})[acc_id] = time.time() + hours * 3600
                save_state(state)
                print(json.dumps({"ok": True}, ensure_ascii=False))
                return

    except Exception as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
