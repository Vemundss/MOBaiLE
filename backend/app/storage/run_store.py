from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from app.models.schemas import ActionPlan, ExecutionEvent, HumanUnblockRequest, RunRecord

LEGACY_CODEX_THREAD_MAP_COMPAT_REMOVE_AFTER = "2026-07-01"


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
                    pending_human_unblock_json TEXT,
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
            if "pending_human_unblock_json" not in column_names:
                conn.execute("ALTER TABLE runs ADD COLUMN pending_human_unblock_json TEXT")
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
                CREATE TABLE IF NOT EXISTS session_context (
                    session_id TEXT PRIMARY KEY,
                    executor TEXT,
                    working_directory TEXT,
                    codex_model TEXT,
                    codex_reasoning_effort TEXT,
                    claude_model TEXT,
                    latest_run_id TEXT,
                    latest_run_status TEXT,
                    latest_run_summary TEXT,
                    latest_run_pending_human_unblock_json TEXT,
                    latest_run_updated_at TEXT,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            columns = conn.execute("PRAGMA table_info(session_context)").fetchall()
            column_names = {row["name"] for row in columns}
            if "codex_model" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN codex_model TEXT")
            if "codex_reasoning_effort" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN codex_reasoning_effort TEXT")
            if "claude_model" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN claude_model TEXT")
            if "latest_run_id" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN latest_run_id TEXT")
            if "latest_run_status" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN latest_run_status TEXT")
            if "latest_run_summary" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN latest_run_summary TEXT")
            if "latest_run_pending_human_unblock_json" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN latest_run_pending_human_unblock_json TEXT")
            if "latest_run_updated_at" not in column_names:
                conn.execute("ALTER TABLE session_context ADD COLUMN latest_run_updated_at TEXT")
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS agent_session_map (
                    executor TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    client_thread_id TEXT NOT NULL,
                    agent_session_id TEXT NOT NULL,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (executor, session_id, client_thread_id)
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_agent_session_map_updated_at ON agent_session_map(updated_at)"
            )
            legacy_thread_map = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='codex_thread_map'"
            ).fetchone()
            if legacy_thread_map is not None:
                # Remove after 2026-07-01 once installs have migrated to agent_session_map.
                conn.execute(
                    """
                    INSERT OR IGNORE INTO agent_session_map (
                        executor, session_id, client_thread_id, agent_session_id, updated_at
                    )
                    SELECT 'codex', session_id, client_thread_id, codex_thread_id, updated_at
                    FROM codex_thread_map
                    """
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

    def update_run_status(
        self,
        run_id: str,
        status: str,
        summary: str,
        *,
        pending_human_unblock: HumanUnblockRequest | None = None,
    ) -> None:
        pending_human_unblock_json = (
            pending_human_unblock.model_dump_json() if pending_human_unblock is not None else None
        )
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE runs
                SET status = ?, summary = ?, pending_human_unblock_json = ?, updated_at = CURRENT_TIMESTAMP
                WHERE run_id = ?
                """,
                (status, summary, pending_human_unblock_json, run_id),
            )

    def load_run(self, run_id: str) -> RunRecord | None:
        with self._connect() as conn:
            run_row = conn.execute(
                """
                SELECT run_id, session_id, executor, utterance_text, working_directory, status, pending_human_unblock_json, plan_json, summary, created_at, updated_at
                FROM runs
                WHERE run_id = ?
                """,
                (run_id,),
            ).fetchone()
            if run_row is None:
                return None
            event_rows = conn.execute(
                """
                SELECT run_id, seq, event_id, type, action_index, message, created_at
                FROM run_events
                WHERE run_id = ?
                ORDER BY seq
                """,
                (run_id,),
            ).fetchall()
        return self._hydrate_run(run_row, event_rows)

    def load_all(self) -> dict[str, RunRecord]:
        runs: dict[str, RunRecord] = {}
        with self._connect() as conn:
            run_rows = conn.execute(
                """
                SELECT run_id, session_id, executor, utterance_text, working_directory, status, pending_human_unblock_json, plan_json, summary, created_at, updated_at
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

        for row in run_rows:
            runs[row["run_id"]] = self._hydrate_run(
                row,
                [event_row for event_row in event_rows if event_row["run_id"] == row["run_id"]],
            )
        return runs

    def list_runs_for_session(self, session_id: str, limit: int = 20) -> list[RunRecord]:
        with self._connect() as conn:
            run_rows = conn.execute(
                """
                SELECT run_id, session_id, executor, utterance_text, working_directory, status, pending_human_unblock_json, plan_json, summary, created_at, updated_at
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

        results: list[RunRecord] = []
        for row in run_rows:
            results.append(
                self._hydrate_run(
                    row,
                    [event_row for event_row in event_rows if event_row["run_id"] == row["run_id"]],
                )
            )
        return results

    def get_session_context(self, session_id: str) -> sqlite3.Row | None:
        with self._connect() as conn:
            return conn.execute(
                """
                SELECT
                    session_id,
                    executor,
                    working_directory,
                    codex_model,
                    codex_reasoning_effort,
                    claude_model,
                    latest_run_id,
                    latest_run_status,
                    latest_run_summary,
                    latest_run_pending_human_unblock_json,
                    latest_run_updated_at,
                    updated_at
                FROM session_context
                WHERE session_id = ?
                """,
                (session_id,),
            ).fetchone()

    def upsert_session_context(
        self,
        session_id: str,
        *,
        executor: str | None,
        working_directory: str | None,
        codex_model: str | None,
        codex_reasoning_effort: str | None,
        claude_model: str | None,
    ) -> sqlite3.Row:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO session_context (
                    session_id,
                    executor,
                    working_directory,
                    codex_model,
                    codex_reasoning_effort,
                    claude_model,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(session_id) DO UPDATE SET
                    executor=excluded.executor,
                    working_directory=excluded.working_directory,
                    codex_model=excluded.codex_model,
                    codex_reasoning_effort=excluded.codex_reasoning_effort,
                    claude_model=excluded.claude_model,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (
                    session_id,
                    executor,
                    working_directory,
                    codex_model,
                    codex_reasoning_effort,
                    claude_model,
                ),
            )
            row = conn.execute(
                """
                SELECT
                    session_id,
                    executor,
                    working_directory,
                    codex_model,
                    codex_reasoning_effort,
                    claude_model,
                    updated_at
                FROM session_context
                WHERE session_id = ?
                """,
                (session_id,),
            ).fetchone()
        assert row is not None
        return row

    def update_session_latest_run(
        self,
        session_id: str,
        *,
        run_id: str,
        status: str,
        summary: str,
        pending_human_unblock: HumanUnblockRequest | None = None,
    ) -> None:
        pending_human_unblock_json = (
            pending_human_unblock.model_dump_json() if pending_human_unblock is not None else None
        )
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO session_context (
                    session_id,
                    latest_run_id,
                    latest_run_status,
                    latest_run_summary,
                    latest_run_pending_human_unblock_json,
                    latest_run_updated_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                ON CONFLICT(session_id) DO UPDATE SET
                    latest_run_id=excluded.latest_run_id,
                    latest_run_status=excluded.latest_run_status,
                    latest_run_summary=excluded.latest_run_summary,
                    latest_run_pending_human_unblock_json=excluded.latest_run_pending_human_unblock_json,
                    latest_run_updated_at=CURRENT_TIMESTAMP,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (
                    session_id,
                    run_id,
                    status,
                    summary,
                    pending_human_unblock_json,
                ),
            )

    def get_agent_session_id(self, executor: str, session_id: str, client_thread_id: str) -> str | None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT agent_session_id
                FROM agent_session_map
                WHERE executor = ? AND session_id = ? AND client_thread_id = ?
                """,
                (executor, session_id, client_thread_id),
            ).fetchone()
        if row is None:
            return None
        value = str(row["agent_session_id"]).strip()
        return value or None

    def set_agent_session_id(
        self,
        executor: str,
        session_id: str,
        client_thread_id: str,
        agent_session_id: str,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO agent_session_map (
                    executor, session_id, client_thread_id, agent_session_id, updated_at
                )
                VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(executor, session_id, client_thread_id) DO UPDATE SET
                    agent_session_id=excluded.agent_session_id,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (executor, session_id, client_thread_id, agent_session_id),
            )

    def _upsert_run_conn(self, conn: sqlite3.Connection, run: RunRecord) -> None:
        plan_json = run.plan.model_dump_json() if run.plan is not None else None
        pending_human_unblock_json = (
            run.pending_human_unblock.model_dump_json() if run.pending_human_unblock is not None else None
        )
        conn.execute(
            """
            INSERT INTO runs (
                run_id, session_id, executor, utterance_text, working_directory, status, pending_human_unblock_json, plan_json, summary, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(run_id) DO UPDATE SET
                session_id=excluded.session_id,
                executor=excluded.executor,
                utterance_text=excluded.utterance_text,
                working_directory=excluded.working_directory,
                status=excluded.status,
                pending_human_unblock_json=excluded.pending_human_unblock_json,
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
                pending_human_unblock_json,
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

    def _hydrate_run(
        self,
        run_row: sqlite3.Row,
        event_rows: list[sqlite3.Row],
    ) -> RunRecord:
        plan: ActionPlan | None = None
        pending_human_unblock: HumanUnblockRequest | None = None
        plan_json = run_row["plan_json"]
        if plan_json:
            try:
                plan = ActionPlan.model_validate_json(plan_json)
            except Exception:
                plan = None
        pending_human_unblock_json = run_row["pending_human_unblock_json"]
        if pending_human_unblock_json:
            try:
                pending_human_unblock = HumanUnblockRequest.model_validate_json(pending_human_unblock_json)
            except Exception:
                pending_human_unblock = None

        events = [
            ExecutionEvent(
                seq=row["seq"],
                event_id=row["event_id"],
                type=row["type"],
                action_index=row["action_index"],
                message=row["message"],
                created_at=row["created_at"],
            )
            for row in event_rows
        ]

        return RunRecord(
            run_id=run_row["run_id"],
            session_id=run_row["session_id"],
            executor=run_row["executor"] or "local",
            utterance_text=run_row["utterance_text"],
            working_directory=run_row["working_directory"],
            status=run_row["status"],
            pending_human_unblock=pending_human_unblock,
            plan=plan,
            events=events,
            summary=run_row["summary"],
            created_at=run_row["created_at"],
            updated_at=run_row["updated_at"],
        )
