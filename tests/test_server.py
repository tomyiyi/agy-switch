import json
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


if __name__ == "__main__":
    unittest.main()
