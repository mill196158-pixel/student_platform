import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "audit_forward_rollback.py"


class RollbackAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forward_audit_qa_")
        self.db = Path(self.tmp.name) / "forward_outbox_v1.db"
        with sqlite3.connect(self.db) as conn:
            conn.executescript("""
              PRAGMA user_version=5;
              CREATE TABLE forward_item (backend TEXT, uid TEXT, chat TEXT, op TEXT,
                version INTEGER, state TEXT, source TEXT, source_urls TEXT, source_ids TEXT,
                prepared TEXT, prepared_ids TEXT, sent_text TEXT, reply_id TEXT, sent_ids TEXT,
                message_id TEXT, PRIMARY KEY (backend,uid,chat));
              CREATE TABLE forward_terminal (backend TEXT, uid TEXT, chat TEXT, operation TEXT,
                kind TEXT, PRIMARY KEY (backend,uid,chat,operation));
              CREATE TABLE forward_sent (backend TEXT, uid TEXT, chat TEXT, operation TEXT,
                PRIMARY KEY (backend,uid,chat,operation));
              CREATE TABLE forward_legacy_import (backend TEXT, uid TEXT, chat TEXT, fingerprint TEXT,
                operation TEXT, PRIMARY KEY (backend,uid,chat,fingerprint));
            """)

    def tearDown(self):
        root = Path(tempfile.gettempdir()).resolve(strict=True)
        target = Path(self.tmp.name).resolve(strict=True)
        if not target.is_relative_to(root) or not target.name.startswith("forward_audit_qa_"):
            raise RuntimeError("Unsafe QA directory")
        self.tmp.cleanup()

    def run_guard(self):
        run = subprocess.run([sys.executable, str(SCRIPT), str(self.db)],
                             capture_output=True, text=True, check=False)
        self.assertEqual(run.returncode, 2)
        return json.loads(run.stdout)

    def test_empty_is_never_approved_and_database_is_unchanged(self):
        before = hashlib.sha256(self.db.read_bytes()).digest()
        result = self.run_guard()
        self.assertFalse(result["rollback_authorized"])
        self.assertEqual(result["states"], {})
        self.assertEqual(before, hashlib.sha256(self.db.read_bytes()).digest())

    def test_unknown_and_sent_counts_do_not_expose_private_values(self):
        with sqlite3.connect(self.db) as conn:
            conn.executemany("INSERT INTO forward_item (backend,uid,chat,op,version,state) VALUES (?,?,?,?,?,?)", [
                ("secret_backend", "secret_uid", "private_chat", "op", 1, "sending_unknown"),
                ("secret_backend", "secret_uid", "another_chat", "op2", 1, "sent"),
            ])
            conn.execute("INSERT INTO forward_terminal VALUES (?,?,?,?,?)",
                         ("secret_backend", "secret_uid", "private_chat", "op", "canceled"))
        result = self.run_guard()
        self.assertEqual(result["states"], {"sending_unknown": 1, "sent": 1})
        self.assertEqual(result["markers"]["forward_terminal"], 1)
        self.assertNotIn("secret", json.dumps(result))
        self.assertFalse(result["rollback_authorized"])

    def test_unexpected_state_version_and_sidecar_fail_closed(self):
        with sqlite3.connect(self.db) as conn:
            conn.execute("INSERT INTO forward_item (backend,uid,chat,op,version,state) VALUES (?,?,?,?,?,?)", ("b", "u", "c", "o", 1, "future"))
        self.assertNotIn("states", self.run_guard())
        with sqlite3.connect(self.db) as conn:
            conn.execute("DELETE FROM forward_item")
            conn.execute("PRAGMA user_version=6")
        self.assertNotIn("states", self.run_guard())
        with sqlite3.connect(self.db) as conn:
            conn.execute("PRAGMA user_version=5")
        Path(str(self.db) + "-wal").write_bytes(b"uncheckpointed")
        self.assertNotIn("states", self.run_guard())

    def test_missing_and_malformed_fail_closed(self):
        self.db.unlink()
        self.assertNotIn("states", self.run_guard())
        self.db.write_bytes(b"not sqlite")
        self.assertNotIn("states", self.run_guard())

    def test_impostor_table_with_right_columns_but_no_primary_key_is_rejected(self):
        with sqlite3.connect(self.db) as conn:
            conn.executescript("""
              ALTER TABLE forward_item RENAME TO old_item;
              CREATE TABLE forward_item AS SELECT * FROM old_item;
              DROP TABLE old_item;
            """)
        self.assertNotIn("states", self.run_guard())


if __name__ == "__main__":
    unittest.main()
