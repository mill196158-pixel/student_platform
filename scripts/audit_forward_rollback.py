"""Read-only inspection of an exported durable-forward SQLite snapshot.

This tool never approves or performs an APK rollback. A stopped application,
snapshot provenance and drafts outside this database cannot be verified here.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path


TABLES = {
    "forward_item": {"backend": 1, "uid": 2, "chat": 3, "op": 0, "version": 0,
                     "state": 0, "source": 0, "source_urls": 0, "source_ids": 0,
                     "prepared": 0, "prepared_ids": 0, "sent_text": 0,
                     "reply_id": 0, "sent_ids": 0, "message_id": 0},
    "forward_terminal": {"backend": 1, "uid": 2, "chat": 3, "operation": 4, "kind": 0},
    "forward_sent": {"backend": 1, "uid": 2, "chat": 3, "operation": 4},
    "forward_legacy_import": {"backend": 1, "uid": 2, "chat": 3, "fingerprint": 4, "operation": 0},
}
STATES = {
    "reserved_unverified", "queued", "preparing_unknown", "ready",
    "sending_unknown", "sent",
}


def inspect_snapshot(path: Path) -> dict:
    """Return counts only; no account identifiers or forward contents."""
    path = path.resolve(strict=True)
    if path.name != "forward_outbox_v1.db" or not path.is_file():
        raise ValueError("Expected a durable-forward database snapshot")
    if any(Path(str(path) + suffix).exists() for suffix in ("-wal", "-shm", "-journal")):
        raise ValueError("SQLite sidecar present; require a consistent offline snapshot")
    # immutable prevents SQLite from creating or updating files. It is safe
    # only for a known consistent snapshot with no sidecars, checked above.
    connection = sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True)
    try:
        if connection.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise ValueError("Database integrity check failed")
        if connection.execute("PRAGMA user_version").fetchone() != (5,):
            raise ValueError("Unknown database version")
        for table, required in TABLES.items():
            kind = connection.execute("SELECT type FROM sqlite_master WHERE name=?", (table,)).fetchone()
            columns = {row[1]: row[5] for row in connection.execute(f"PRAGMA table_info({table})")}
            if kind != ("table",) or any(columns.get(name) != pk for name, pk in required.items()):
                raise ValueError("Unknown database schema")
        grouped = connection.execute(
            "SELECT state, COUNT(*) FROM forward_item GROUP BY state"
        ).fetchall()
        if any(state not in STATES for state, _ in grouped):
            raise ValueError("Unknown queue state")
        states = {state: count for state, count in grouped}
        terminal = {
            table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("forward_terminal", "forward_sent", "forward_legacy_import")
        }
        return {"states": states, "markers": terminal,
                "rollback_authorized": False,
                "reason": "Snapshot alone cannot establish safe downgrade."}
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path, help="Path to a verified offline snapshot")
    args = parser.parse_args()
    try:
        result = inspect_snapshot(args.database)
    except (OSError, sqlite3.Error, ValueError):
        print(json.dumps({"rollback_authorized": False,
                          "reason": "Snapshot missing, inconsistent, or unsupported."}))
        return 2
    print(json.dumps(result, sort_keys=True))
    # Always deny: even an empty file does not prove the running device is
    # quiescent or that legacy drafts and the rollback APK are safe.
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
