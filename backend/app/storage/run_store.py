from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from app.models.schemas import RunRecord


class RunStore:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS runs (
                    run_id TEXT PRIMARY KEY,
                    payload_json TEXT NOT NULL,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """
            )

    def upsert(self, run: RunRecord) -> None:
        payload = json.dumps(run.model_dump())
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO runs (run_id, payload_json, updated_at)
                VALUES (?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(run_id) DO UPDATE SET
                    payload_json=excluded.payload_json,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (run.run_id, payload),
            )

    def load_all(self) -> dict[str, RunRecord]:
        runs: dict[str, RunRecord] = {}
        with self._connect() as conn:
            rows = conn.execute("SELECT run_id, payload_json FROM runs").fetchall()
        for row in rows:
            try:
                payload = json.loads(row["payload_json"])
                runs[row["run_id"]] = RunRecord.model_validate(payload)
            except Exception:
                continue
        return runs
