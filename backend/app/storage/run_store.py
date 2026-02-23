from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from app.models.schemas import ActionPlan, ExecutionEvent, RunRecord


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
        legacy_rows: list[sqlite3.Row] = []
        with self._connect() as conn:
            existing_runs = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='runs'"
            ).fetchone()
            if existing_runs is not None:
                columns = conn.execute("PRAGMA table_info(runs)").fetchall()
                column_names = {row["name"] for row in columns}
                if "payload_json" in column_names:
                    legacy_rows = conn.execute("SELECT run_id, payload_json FROM runs").fetchall()
                    conn.execute("DROP TABLE runs")

            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS runs (
                    run_id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    utterance_text TEXT NOT NULL,
                    working_directory TEXT,
                    status TEXT NOT NULL,
                    plan_json TEXT,
                    summary TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS run_events (
                    run_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    action_index INTEGER,
                    message TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (run_id, seq),
                    FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_run_events_run_id_seq ON run_events(run_id, seq)"
            )

            if legacy_rows:
                for row in legacy_rows:
                    try:
                        payload = json.loads(row["payload_json"])
                        run = RunRecord.model_validate(payload)
                    except Exception:
                        continue
                    self._upsert_run_conn(conn, run)
                    for seq, event in enumerate(run.events):
                        self._append_event_conn(conn, run.run_id, seq, event)

    def upsert_run(self, run: RunRecord) -> None:
        with self._connect() as conn:
            self._upsert_run_conn(conn, run)

    def append_event(self, run_id: str, event: ExecutionEvent) -> None:
        with self._connect() as conn:
            next_seq_row = conn.execute(
                "SELECT COALESCE(MAX(seq), -1) + 1 AS next_seq FROM run_events WHERE run_id = ?",
                (run_id,),
            ).fetchone()
            next_seq = int(next_seq_row["next_seq"]) if next_seq_row is not None else 0
            self._append_event_conn(conn, run_id, next_seq, event)

    def update_run_status(self, run_id: str, status: str, summary: str) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE runs
                SET status = ?, summary = ?, updated_at = CURRENT_TIMESTAMP
                WHERE run_id = ?
                """,
                (status, summary, run_id),
            )

    def load_all(self) -> dict[str, RunRecord]:
        runs: dict[str, RunRecord] = {}
        with self._connect() as conn:
            run_rows = conn.execute(
                """
                SELECT run_id, session_id, utterance_text, working_directory, status, plan_json, summary
                FROM runs
                """
            ).fetchall()
            event_rows = conn.execute(
                """
                SELECT run_id, seq, type, action_index, message
                FROM run_events
                ORDER BY run_id, seq
                """
            ).fetchall()

        events_by_run: dict[str, list[ExecutionEvent]] = {}
        for row in event_rows:
            events_by_run.setdefault(row["run_id"], []).append(
                ExecutionEvent(
                    type=row["type"],
                    action_index=row["action_index"],
                    message=row["message"],
                )
            )

        for row in run_rows:
            plan: ActionPlan | None = None
            plan_json = row["plan_json"]
            if plan_json:
                try:
                    plan = ActionPlan.model_validate_json(plan_json)
                except Exception:
                    plan = None
            runs[row["run_id"]] = RunRecord(
                run_id=row["run_id"],
                session_id=row["session_id"],
                utterance_text=row["utterance_text"],
                working_directory=row["working_directory"],
                status=row["status"],
                plan=plan,
                events=events_by_run.get(row["run_id"], []),
                summary=row["summary"],
            )
        return runs

    def _upsert_run_conn(self, conn: sqlite3.Connection, run: RunRecord) -> None:
        plan_json = run.plan.model_dump_json() if run.plan is not None else None
        conn.execute(
            """
            INSERT INTO runs (
                run_id, session_id, utterance_text, working_directory, status, plan_json, summary, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(run_id) DO UPDATE SET
                session_id=excluded.session_id,
                utterance_text=excluded.utterance_text,
                working_directory=excluded.working_directory,
                status=excluded.status,
                plan_json=excluded.plan_json,
                summary=excluded.summary,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                run.run_id,
                run.session_id,
                run.utterance_text,
                run.working_directory,
                run.status,
                plan_json,
                run.summary,
            ),
        )

    def _append_event_conn(
        self,
        conn: sqlite3.Connection,
        run_id: str,
        seq: int,
        event: ExecutionEvent,
    ) -> None:
        conn.execute(
            """
            INSERT INTO run_events (run_id, seq, type, action_index, message)
            VALUES (?, ?, ?, ?, ?)
            """,
            (run_id, seq, event.type, event.action_index, event.message),
        )
