import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server


class TestAgySwitchEngine(unittest.TestCase):
    def test_parse_family_meta(self):
        m1 = server.parse_family_meta("[家庭组B-主] AI Pro管理员(余4名额)")
        self.assertEqual(m1["family_group"], "B")
        self.assertTrue(m1["is_manager"])
        self.assertEqual(m1["clean_note"], "AI Pro管理员(余4名额)")
        self.assertFalse(m1["flagged"])

        m2 = server.parse_family_meta("[家庭组 A · 子] ⚠️触发Google二次验证")
        self.assertEqual(m2["family_group"], "A")
        self.assertFalse(m2["is_manager"])
        self.assertTrue(m2["flagged"])

        m3 = server.parse_family_meta("[家庭组D-主] 独享AI Pro(未共享)")
        self.assertEqual(m3["family_group"], "D")
        self.assertTrue(m3["explicit_solo"])

    def test_validate_isolated_acc_id_blocks_traversal(self):
        for bad in ("", "main", ".", "..", "../etc", "a/b", "-bad", "a"):
            with self.assertRaises(ValueError):
                server.validate_isolated_acc_id(bad)
        self.assertEqual(server.validate_isolated_acc_id("11-new_acc.test"), "11-new_acc.test")

    def test_load_state_handles_null_fields_safely(self):
        with tempfile.TemporaryDirectory() as td:
            sf = Path(td) / "state.json"
            sf.write_text(
                json.dumps({
                    "cooldowns": None,
                    "notes": None,
                    "calibrations": None,
                    "workspaces": None,
                    "switch_history": None,
                    "last_switch": None,
                }),
                encoding="utf-8",
            )
            with mock.patch.object(server, "STATE_FILE", sf):
                st = server.load_state()
                self.assertEqual(st["cooldowns"], {})
                self.assertEqual(st["notes"], {})
                self.assertTrue(isinstance(st["workspaces"], list) and len(st["workspaces"]) >= 1)
                self.assertEqual(st["switch_history"], [])
                self.assertEqual(st["last_switch"], "")

    def test_pick_best_candidates_cross_group_and_solo_first(self):
        accounts = [
            {"id": "3-rew", "family_group": "B", "solo_group": False, "logged_in": True, "health": "ready", "app_exists": True, "running": True, "flagged": False, "turns_5h": 12, "turns_7d": 200, "latest_mtime": 100},
            {"id": "8-0701", "family_group": "B", "solo_group": False, "logged_in": True, "health": "ready", "app_exists": True, "running": False, "flagged": False, "turns_5h": 0, "turns_7d": 0, "latest_mtime": 10},
            {"id": "10-sut", "family_group": "A", "solo_group": False, "logged_in": True, "health": "warning", "app_exists": True, "running": False, "flagged": True, "turns_5h": 0, "turns_7d": 0, "latest_mtime": 0},
            {"id": "2-dj", "family_group": "A", "solo_group": False, "logged_in": True, "health": "ready", "app_exists": True, "running": False, "flagged": False, "turns_5h": 0, "turns_7d": 5, "latest_mtime": 50},
            {"id": "6-0705", "family_group": "D", "solo_group": True, "logged_in": True, "health": "ready", "app_exists": True, "running": False, "flagged": False, "turns_5h": 0, "turns_7d": 20, "latest_mtime": 90},
        ]
        ranked = server.pick_best_candidates(accounts, "3-rew")
        ids = [a["id"] for a in ranked]
        self.assertEqual(ids, ["6-0705", "2-dj", "8-0701"])
        self.assertIn("独享", ranked[0]["recommend_reason"])
        self.assertIn("跨组", ranked[1]["recommend_reason"])
        self.assertIn("同组兜底", ranked[2]["recommend_reason"])

    def test_perform_switch_aborts_if_old_process_refuses_to_exit(self):
        with mock.patch.object(server, "detect_running_instance", return_value=("3-rew", 999999)), \
             mock.patch("subprocess.run"), \
             mock.patch("subprocess.Popen") as popen_mock, \
             mock.patch("os.kill"), \
             mock.patch("time.sleep"):
            with self.assertRaises(RuntimeError):
                server.perform_switch("/tmp/Fake.app", "Fake", "3-rew", "6-0705")
            popen_mock.assert_not_called()

    def test_sync_conversations_preserves_conflicts_and_copies_sqlite(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            canon = root / "home" / ".gemini" / "antigravity"
            multi = root / "multi"
            (canon / "conversations").mkdir(parents=True)
            (canon / "conversations" / "shared.pb").write_text("canon-v1", encoding="utf-8")

            src_db = canon / "conversation_summaries.db"
            conn = sqlite3.connect(str(src_db))
            conn.execute("CREATE TABLE t (id INT)")
            conn.execute("INSERT INTO t VALUES (42)")
            conn.commit()
            conn.close()

            tgt_conv = multi / "acc2" / ".gemini" / "antigravity" / "conversations"
            tgt_conv.mkdir(parents=True)
            # 冲突同名文件 + 独有新文件
            (tgt_conv / "shared.pb").write_text("acc2-conflict", encoding="utf-8")
            (tgt_conv / "unique.pb").write_text("acc2-unique", encoding="utf-8")

            with mock.patch.object(server, "HOME", root / "home"), \
                 mock.patch.object(server, "MULTI_DIR", multi):
                server.sync_conversations("main", "acc2")

            # 独有文件已合入主目录
            self.assertEqual((canon / "conversations" / "unique.pb").read_text(encoding="utf-8"), "acc2-unique")
            # 冲突文件被安全重命名备份，未丢失！
            baks = list((multi / "acc2" / ".gemini" / "antigravity").glob("conversations.conflict_bak_*"))
            self.assertEqual(len(baks), 1)
            self.assertEqual((baks[0] / "shared.pb").read_text(encoding="utf-8"), "acc2-conflict")
            # 目标 conversations 已变为软链且 SQLite 已安全备份过去
            self.assertTrue((multi / "acc2" / ".gemini" / "antigravity" / "conversations").is_symlink())
            tgt_db = multi / "acc2" / ".gemini" / "antigravity" / "conversation_summaries.db"
            self.assertTrue(tgt_db.exists())

    def test_atomic_state_and_handoff_isolation(self):
        with tempfile.TemporaryDirectory() as td:
            tmp_root = Path(td)
            with mock.patch.object(server, "STATE_DIR", tmp_root / "state"), \
                 mock.patch.object(server, "STATE_FILE", tmp_root / "state" / "state.json"), \
                 mock.patch.object(server, "LOCK_FILE", tmp_root / "state" / "state.lock"), \
                 mock.patch.object(server, "detect_3tb_brain_dir", return_value=None), \
                 mock.patch("subprocess.run"):
                with server.state_lock():
                    st = server.load_state()
                    st["notes"]["acc1"] = "[家庭组A-主] 测试"
                    server.save_state(st)
                    reloaded = server.load_state()
                    self.assertEqual(reloaded["notes"]["acc1"], "[家庭组A-主] 测试")

                ws = tmp_root / "ws"
                ws.mkdir()
                tr = tmp_root / "transcript.jsonl"
                tr.write_text(
                    json.dumps({"type": "USER_INPUT", "created_at": "2026-11-24T10:00:00Z", "content": "继续实现 v5.0"}) + "\n",
                    encoding="utf-8",
                )
                res1 = server.generate_handoff(str(ws), str(tr), extra_note="先跑单测")
                self.assertEqual(res1["turns"], 1)
                self.assertTrue((ws / "HANDOFF_AUTO.md").exists())

                server.generate_handoff(str(ws), str(tr), extra_note="第二次交接")
                hist = list((ws / ".handoff_history").glob("HANDOFF_*.md"))
                self.assertEqual(len(hist), 1)
                self.assertIn("第二次交接", (ws / "HANDOFF_AUTO.md").read_text(encoding="utf-8"))


    def test_unify_shared_assets_merges_skills_and_plugins_without_loss(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            home = root / "home"
            multi = root / "multi"
            state_dir = root / "state"

            # 旧目录独有 skill + 主目录已有 skill
            (home / ".gemini" / "antigravity" / "skills" / "hyperframes").mkdir(parents=True)
            (home / ".gemini" / "config" / "skills" / "oil-ui").mkdir(parents=True)

            # 隔离实例 3 独有官方插件 + config.json
            inst3 = multi / "3-rew"
            (inst3 / ".gemini" / "config" / "plugins" / "modern-web-guidance-plugin").mkdir(parents=True)
            (inst3 / ".gemini" / "config" / "config.json").write_text(
                json.dumps({"plugins": {"modern-web-guidance-plugin": {"enabled": True}}}),
                encoding="utf-8",
            )
            # 隔离实例 6 空插件目录
            inst6 = multi / "6-0705"
            (inst6 / ".gemini" / "config").mkdir(parents=True)

            with mock.patch.object(server, "HOME", home), \
                 mock.patch.object(server, "MULTI_DIR", multi), \
                 mock.patch.object(server, "STATE_DIR", state_dir):
                res = server.unify_shared_assets()

            self.assertEqual(res["instances_synced"], 2)
            self.assertEqual(res["skills_count"], 2)
            self.assertEqual(res["plugins_count"], 1)
            self.assertTrue((inst6 / ".gemini" / "config" / "skills" / "hyperframes").exists())
            self.assertTrue((inst6 / ".gemini" / "config" / "skills" / "oil-ui").exists())
            self.assertTrue((inst6 / ".gemini" / "config" / "plugins" / "modern-web-guidance-plugin").exists())
            cfg6 = json.loads((inst6 / ".gemini" / "config" / "config.json").read_text(encoding="utf-8"))
            self.assertIn("modern-web-guidance-plugin", cfg6["plugins"])

    def test_sync_handoff_to_3tb_atomic_write(self):
        with tempfile.TemporaryDirectory() as td:
            fake_brain = Path(td) / "tom-brain-2026"
            fake_brain.mkdir(parents=True)
            with mock.patch.object(server, "detect_3tb_brain_dir", return_value=fake_brain):
                out = server.sync_handoff_to_3tb("# Handoff OK", filename="HANDOFF_TEST.md")
            self.assertIsNotNone(out)
            handoff_dir = fake_brain / "06-Codex对话" / "AGY_Handoff"
            self.assertEqual((handoff_dir / "HANDOFF_TEST.md").read_text(encoding="utf-8"), "# Handoff OK")
            self.assertEqual((handoff_dir / "HANDOFF_LATEST.md").read_text(encoding="utf-8"), "# Handoff OK")
            # 确保临时文件已清理
            self.assertEqual(list(handoff_dir.glob("*.tmp")), [])

    def test_probe_network_quality_region_and_ok_flags(self):
        class FakeResp:
            def __init__(self, status, body=b""):
                self.status = status
                self._body = body
            def read(self):
                return self._body
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False

        # 1. 美国干净节点放行
        def urlopen_us(req, timeout=2.0):
            url = req.full_url if hasattr(req, "full_url") else str(req)
            if "antigravity.google" in url:
                return FakeResp(200)
            if "accounts.google.com" in url:
                return FakeResp(204)
            return FakeResp(200, json.dumps({"ip": "1.2.3.4", "country": "US", "city": "LA", "region": "CA"}).encode())

        with mock.patch("urllib.request.urlopen", side_effect=urlopen_us):
            res_us = server.probe_network_quality(save_cache=False)
        self.assertTrue(res_us["ok"])
        self.assertTrue(res_us["clean_for_antigravity"])
        self.assertEqual(res_us["country"], "US")

        # 2. 香港受限地区拦截
        def urlopen_hk(req, timeout=2.0):
            url = req.full_url if hasattr(req, "full_url") else str(req)
            if "antigravity.google" in url:
                return FakeResp(200)
            if "accounts.google.com" in url:
                return FakeResp(204)
            return FakeResp(200, json.dumps({"ip": "5.6.7.8", "country": "HK"}).encode())

        with mock.patch("urllib.request.urlopen", side_effect=urlopen_hk):
            res_hk = server.probe_network_quality(save_cache=False)
        self.assertTrue(res_hk["ok"])
        self.assertFalse(res_hk["clean_for_antigravity"])
        self.assertIn("HK", res_hk["error_message"])

        # 3. 全链路超时 ok 必须为 False
        with mock.patch("urllib.request.urlopen", side_effect=OSError("timeout")):
            res_fail = server.probe_network_quality(save_cache=False)
        self.assertFalse(res_fail["ok"])
        self.assertFalse(res_fail["clean_for_antigravity"])

    def test_same_email_active_account_infers_family_group_collision(self):
        accounts = [
            {
                "id": "main", "email": "busmusbrw@gmail.com", "family_group": "", "solo_group": False,
                "logged_in": True, "health": "ready", "app_exists": True, "running": True, "flagged": False,
                "turns_5h": 10, "turns_7d": 50, "latest_mtime": 100.0,
            },
            {
                "id": "9-busmusbrw", "email": "busmusbrw@gmail.com", "family_group": "A", "solo_group": False,
                "logged_in": True, "health": "ready", "app_exists": True, "running": False, "flagged": False,
                "turns_5h": 0, "turns_7d": 0, "latest_mtime": 0.0,
            },
            {
                "id": "2-djgarbage", "email": "djgarbage@gmail.com", "family_group": "A", "solo_group": False,
                "logged_in": True, "health": "ready", "app_exists": True, "running": False, "flagged": False,
                "turns_5h": 0, "turns_7d": 0, "latest_mtime": 0.0,
            },
            {
                "id": "5-tomyi0703", "email": "tomyi0703@gmail.com", "family_group": "C", "solo_group": False,
                "logged_in": True, "health": "ready", "app_exists": True, "running": False, "flagged": False,
                "turns_5h": 2, "turns_7d": 5, "latest_mtime": 20.0,
            },
        ]
        ranked = server.pick_best_candidates(accounts, "main")
        ids = [a["id"] for a in ranked]
        # 跳过同邮箱重复实例 9-busmusbrw，且识别 main 属 A 组，优先推跨组 C 组而非同组 A 组 2-djgarbage
        self.assertNotIn("9-busmusbrw", ids)
        self.assertEqual(ids[0], "5-tomyi0703")
        self.assertEqual(ids[1], "2-djgarbage")
        self.assertIn("同组兜底", ranked[1]["recommend_reason"])

    def test_perform_switch_auto_paste_respects_flag_and_login_state(self):
        with mock.patch.object(server, "detect_running_instance", return_value=("", 0)), \
             mock.patch.object(server, "unify_shared_assets"), \
             mock.patch.object(server, "sync_conversations"), \
             mock.patch.object(server, "notify_macos"), \
             mock.patch("time.sleep"), \
             mock.patch("subprocess.Popen") as popen_mock:
            # 1. 默认 auto_paste=False，仅 open 不发 osascript
            server.perform_switch("/tmp/fake.app", "fake", auto_paste=False, is_login=False)
            self.assertEqual(popen_mock.call_count, 1)

            # 2. auto_paste=True 但 is_login=True，去登录绝不发 Cmd+V
            popen_mock.reset_mock()
            server.perform_switch("/tmp/fake.app", "fake", auto_paste=True, is_login=True)
            self.assertEqual(popen_mock.call_count, 1)

            # 3. auto_paste=True 且非登录，才触发安全校验的 osascript
            popen_mock.reset_mock()
            server.perform_switch("/tmp/fake.app", "fake", auto_paste=True, is_login=False)
            self.assertEqual(popen_mock.call_count, 2)
            script_arg = popen_mock.call_args_list[1][0][0][2]
            self.assertIn('if frontApp is "Antigravity"', script_arg)

    def test_clash_status_graceful_fallback_and_node_filtering(self):
        # 1. Socket 缺失时优雅降级
        with mock.patch.dict(os.environ, {"AGY_CLASH_SOCKET": "/tmp/nonexistent-clash.sock"}):
            res = server.get_clash_status()
            self.assertFalse(res["available"])
            self.assertEqual(res["candidates"], [])

        # 2. Mock Clash proxies 响应：应自动过滤香港/CN/低延迟死节点(delay=0)
        fake_proxies = {
            "proxies": {
                "GLOBAL": {"type": "Selector", "now": "🤖 AI 专用"},
                "🤖 AI 专用": {
                    "type": "Selector",
                    "now": "美国东部",
                    "all": ["美国东部", "香港 01", "美国 B05 Error", "日本 B02", "剩余流量: 99GB"],
                },
                "美国东部": {"type": "AnyTLS", "history": [{"delay": 180}]},
                "香港 01": {"type": "AnyTLS", "history": [{"delay": 35}]},
                "美国 B05 Error": {"type": "AnyTLS", "history": [{"delay": 0}]},
                "日本 B02": {"type": "Vless", "history": [{"delay": 88}]},
                "剩余流量: 99GB": {"type": "Direct", "history": []},
            }
        }
        with mock.patch.object(server, "detect_clash_socket", return_value="/tmp/mock.sock"), \
             mock.patch.object(server, "_clash_request", return_value=(200, fake_proxies)):
            res = server.get_clash_status()
            self.assertTrue(res["available"])
            self.assertEqual(res["active_group"], "🤖 AI 专用")
            self.assertEqual(res["active_node"], "美国东部")
            cand_names = [c["name"] for c in res["candidates"]]
            self.assertEqual(cand_names, ["美国东部", "日本 B02"])
            self.assertNotIn("香港 01", cand_names)
            self.assertNotIn("美国 B05 Error", cand_names)


if __name__ == "__main__":
    unittest.main()
