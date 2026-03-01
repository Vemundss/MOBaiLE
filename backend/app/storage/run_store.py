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
                    executor TEXT NOT NULL DEFAULT 'local',
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
            columns = conn.execute("PRAGMA table_info(runs)").fetchall()
            column_names = {row["name"] for row in columns}
            if "executor" not in column_names:
                conn.execute(
                    "ALTER TABLE runs ADD COLUMN executor TEXT NOT NULL DEFAULT 'local'"
                )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS run_events (
                    run_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    event_id TEXT,
                    type TEXT NOT NULL,
                    action_index INTEGER,
                    message TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (run_id, seq),
                    FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
                )
                """
            )
            columns = conn.execute("PRAGMA table_info(run_events)").fetchall()
            column_names = {row["name"] for row in columns}
            if "event_id" not in column_names:
                conn.execute("ALTER TABLE run_events ADD COLUMN event_id TEXT")
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_run_events_run_id_seq ON run_events(run_id, seq)"
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS codex_thread_map (
                    session_id TEXT NOT NULL,
                    client_thread_id TEXT NOT NULL,
                    codex_thread_id TEXT NOT NULL,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (session_id, client_thread_id)
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_codex_thread_map_updated_at ON codex_thread_map(updated_at)"
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
                SELECT run_id, session_id, executor, utterance_text, working_directory, status, plan_json, summary, created_at, updated_at
                FROM runs
                """
            ).fetchall()
            event_rows = conn.execute(
                """
                SELECT run_id, seq, event_id, type, action_index, message, created_at
                FROM run_events
                ORDER BY run_id, seq
                """
            ).fetchall()

        events_by_run: dict[str, list[ExecutionEvent]] = {}
        for row in event_rows:
            events_by_run.setdefault(row["run_id"], []).append(
                ExecutionEvent(
                    event_id=row["event_id"],
                    type=row["type"],
                    action_index=row["action_index"],
                    message=row["message"],
                    created_at=row["created_at"],
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
                executor=row["executor"] or "local",
                utterance_text=row["utterance_text"],
                working_directory=row["working_directory"],
                status=row["status"],
                plan=plan,
                events=events_by_run.get(row["run_id"], []),
                summary=row["summary"],
                created_at=row["created_at"],
                updated_at=row["updated_at"],
            )
        return runs

    def list_runs_for_session(self, session_id: str, limit: int = 20) -> list[RunRecord]:
        with self._connect() as conn:
            run_rows = conn.execute(
                """
                SELECT run_id, session_id, executor, utterance_text, working_directory, status, plan_json, summary, created_at, updated_at
                FROM runs
                WHERE session_id = ?
                ORDER BY datetime(updated_at) DESC
                LIMIT ?
                """,
                (session_id, limit),
            ).fetchall()
            run_ids = [row["run_id"] for row in run_rows]
            event_rows = conn.execute(
                f"""
                SELECT run_id, seq, event_id, type, action_index, message, created_at
                FROM run_events
                WHERE run_id IN ({",".join(["?"] * len(run_ids))})
                ORDER BY run_id, seq
                """,
                run_ids,
            ).fetchall() if run_ids else []

        events_by_run: dict[str, list[ExecutionEvent]] = {}
        for row in event_rows:
            events_by_run.setdefault(row["run_id"], []).append(
                ExecutionEvent(
                    event_id=row["event_id"],
                    type=row["type"],
                    action_index=row["action_index"],
                    message=row["message"],
                    created_at=row["created_at"],
                )
            )

        results: list[RunRecord] = []
        for row in run_rows:
            plan: ActionPlan | None = None
            plan_json = row["plan_json"]
            if plan_json:
                try:
                    plan = ActionPlan.model_validate_json(plan_json)
                except Exception:
                    plan = None
            results.append(
                RunRecord(
                    run_id=row["run_id"],
                    session_id=row["session_id"],
                    executor=row["executor"] or "local",
                    utterance_text=row["utterance_text"],
                    working_directory=row["working_directory"],
                    status=row["status"],
                    plan=plan,
                    events=events_by_run.get(row["run_id"], []),
                    summary=row["summary"],
                    created_at=row["created_at"],
                    updated_at=row["updated_at"],
                )
            )
        return results

    def get_codex_thread_id(self, session_id: str, client_thread_id: str) -> str | None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT codex_thread_id
                FROM codex_thread_map
                WHERE session_id = ? AND client_thread_id = ?
                """,
                (session_id, client_thread_id),
            ).fetchone()
        if row is None:
            return None
        value = str(row["codex_thread_id"]).strip()
        return value or None

    def set_codex_thread_id(self, session_id: str, client_thread_id: str, codex_thread_id: str) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO codex_thread_map (
                    session_id, client_thread_id, codex_thread_id, updated_at
                )
                VALUES (?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(session_id, client_thread_id) DO UPDATE SET
                    codex_thread_id=excluded.codex_thread_id,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (session_id, client_thread_id, codex_thread_id),
            )

    def _upsert_run_conn(self, conn: sqlite3.Connection, run: RunRecord) -> None:
        plan_json = run.plan.model_dump_json() if run.plan is not None else None
        conn.execute(
            """
            INSERT INTO runs (
                run_id, session_id, executor, utterance_text, working_directory, status, plan_json, summary, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(run_id) DO UPDATE SET
                session_id=excluded.session_id,
                executor=excluded.executor,
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
                run.executor,
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
            INSERT INTO run_events (run_id, seq, event_id, type, action_index, message, created_at)
            VALUES (?, ?, ?, ?, ?, ?, COALESCE(?, CURRENT_TIMESTAMP))
            """,
            (
                run_id,
                seq,
                event.event_id,
                event.type,
                event.action_index,
                event.message,
                event.created_at,
            ),
        )
