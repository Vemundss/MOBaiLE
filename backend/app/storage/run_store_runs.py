from __future__ import annotations

import json
import sqlite3
from typing import Callable

from app.models.schemas import (
    ActionPlan,
    ExecutionEvent,
    HumanUnblockRequest,
    RunRecord,
)

from .run_store_schema import LegacyRunPayloadRow
from .run_store_sql import RUN_COLUMNS, RUN_EVENT_COLUMNS

ConnectionFactory = Callable[[], sqlite3.Connection]


class RunRecordStore:
    def __init__(self, connect: ConnectionFactory) -> None:
        self._connect = connect

    def migrate_legacy_rows(self, legacy_rows: list[LegacyRunPayloadRow]) -> None:
        if not legacy_rows:
            return
        with self._connect() as conn:
            for _, payload_json in legacy_rows:
                try:
                    payload = json.loads(payload_json)
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
                SELECT
                    """
                + RUN_COLUMNS
                + """
                FROM runs
                WHERE run_id = ?
                """,
                (run_id,),
            ).fetchone()
            if run_row is None:
                return None
            event_rows = self._load_event_rows_for_run_ids(conn, [run_id]).get(run_id, [])
        return self._hydrate_run(run_row, event_rows)

    def load_all(self) -> dict[str, RunRecord]:
        runs: dict[str, RunRecord] = {}
        with self._connect() as conn:
            run_rows = conn.execute(
                """
                SELECT
                    """
                + RUN_COLUMNS
                + """
                FROM runs
                """
            ).fetchall()
            event_rows_by_run = self._load_event_rows_for_run_ids(
                conn,
                [str(row["run_id"]) for row in run_rows],
            )

        for row in run_rows:
            run_id = str(row["run_id"])
            runs[run_id] = self._hydrate_run(row, event_rows_by_run.get(run_id, []))
        return runs

    def list_runs_for_session(self, session_id: str, limit: int = 20) -> list[RunRecord]:
        with self._connect() as conn:
            run_rows = conn.execute(
                """
                SELECT
                    """
                + RUN_COLUMNS
                + """
                FROM runs
                WHERE session_id = ?
                ORDER BY datetime(updated_at) DESC
                LIMIT ?
                """,
                (session_id, limit),
            ).fetchall()
            run_ids = [str(row["run_id"]) for row in run_rows]
            event_rows_by_run = self._load_event_rows_for_run_ids(conn, run_ids)

        results: list[RunRecord] = []
        for row in run_rows:
            run_id = str(row["run_id"])
            results.append(self._hydrate_run(row, event_rows_by_run.get(run_id, [])))
        return results

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
            INSERT INTO run_events (run_id, seq, event_id, type, action_index, message, event_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE(?, CURRENT_TIMESTAMP))
            """,
            (
                run_id,
                seq,
                event.event_id,
                event.type,
                event.action_index,
                event.message,
                event.model_dump_json(),
                event.created_at,
            ),
        )

    def _load_event_rows_for_run_ids(
        self,
        conn: sqlite3.Connection,
        run_ids: list[str],
    ) -> dict[str, list[sqlite3.Row]]:
        if not run_ids:
            return {}
        placeholders = ",".join(["?"] * len(run_ids))
        event_rows = conn.execute(
            f"""
            SELECT
                {RUN_EVENT_COLUMNS}
            FROM run_events
            WHERE run_id IN ({placeholders})
            ORDER BY run_id, seq
            """,
            run_ids,
        ).fetchall()
        return self._group_event_rows_by_run_id(event_rows)

    @staticmethod
    def _group_event_rows_by_run_id(
        event_rows: list[sqlite3.Row],
    ) -> dict[str, list[sqlite3.Row]]:
        grouped: dict[str, list[sqlite3.Row]] = {}
        for row in event_rows:
            grouped.setdefault(str(row["run_id"]), []).append(row)
        return grouped

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

        events = [self._hydrate_event(row) for row in event_rows]

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

    @staticmethod
    def _hydrate_event(row: sqlite3.Row) -> ExecutionEvent:
        event_json = row["event_json"] if "event_json" in row.keys() else None
        if event_json:
            try:
                event = ExecutionEvent.model_validate_json(event_json)
                if event.seq is None:
                    event.seq = row["seq"]
                if not event.event_id:
                    event.event_id = row["event_id"]
                if not event.created_at:
                    event.created_at = row["created_at"]
                return event
            except Exception:
                pass
        return ExecutionEvent(
            seq=row["seq"],
            event_id=row["event_id"],
            type=row["type"],
            action_index=row["action_index"],
            message=row["message"],
            created_at=row["created_at"],
        )
