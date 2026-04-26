from __future__ import annotations

import sqlite3
from pathlib import Path

from app.models.schemas import (
    ExecutionEvent,
    HumanUnblockRequest,
    RunEventsPage,
    RunRecord,
    RunSummary,
)

from .run_store_runs import RunRecordStore
from .run_store_schema import initialize_run_store_schema
from .run_store_session_context import SessionContextStore


class RunStore:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._runs = RunRecordStore(self._connect)
        self._session_context = SessionContextStore(self._connect)
        legacy_rows = initialize_run_store_schema(self._connect)
        self._runs.migrate_legacy_rows(legacy_rows)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def upsert_run(self, run: RunRecord) -> None:
        self._runs.upsert_run(run)

    def append_event(self, run_id: str, event: ExecutionEvent) -> None:
        self._runs.append_event(run_id, event)

    def update_run_status(
        self,
        run_id: str,
        status: str,
        summary: str,
        *,
        pending_human_unblock: HumanUnblockRequest | None = None,
    ) -> None:
        self._runs.update_run_status(
            run_id,
            status,
            summary,
            pending_human_unblock=pending_human_unblock,
        )

    def load_run(self, run_id: str) -> RunRecord | None:
        return self._runs.load_run(run_id)

    def event_page(
        self,
        run_id: str,
        *,
        limit: int,
        before_seq: int | None = None,
        after_seq: int | None = None,
    ) -> RunEventsPage | None:
        return self._runs.event_page(
            run_id,
            limit=limit,
            before_seq=before_seq,
            after_seq=after_seq,
        )

    def load_all(self) -> dict[str, RunRecord]:
        return self._runs.load_all()

    def list_runs_for_session(self, session_id: str, limit: int = 20) -> list[RunRecord]:
        return self._runs.list_runs_for_session(session_id, limit=limit)

    def list_run_summaries_for_session(self, session_id: str, limit: int = 20) -> list[RunSummary]:
        return self._runs.list_run_summaries_for_session(session_id, limit=limit)

    def get_session_context(self, session_id: str) -> sqlite3.Row | None:
        return self._session_context.get_session_context(session_id)

    def upsert_session_context(
        self,
        session_id: str,
        *,
        executor: str | None,
        working_directory: str | None,
        runtime_settings_json: str | None,
        codex_model: str | None,
        codex_reasoning_effort: str | None,
        claude_model: str | None,
    ) -> sqlite3.Row:
        return self._session_context.upsert_session_context(
            session_id,
            executor=executor,
            working_directory=working_directory,
            runtime_settings_json=runtime_settings_json,
            codex_model=codex_model,
            codex_reasoning_effort=codex_reasoning_effort,
            claude_model=claude_model,
        )

    def update_session_latest_run(
        self,
        session_id: str,
        *,
        run_id: str,
        status: str,
        summary: str,
        pending_human_unblock: HumanUnblockRequest | None = None,
    ) -> None:
        self._session_context.update_session_latest_run(
            session_id,
            run_id=run_id,
            status=status,
            summary=summary,
            pending_human_unblock=pending_human_unblock,
        )

    def get_agent_session_id(self, executor: str, session_id: str, client_thread_id: str) -> str | None:
        return self._session_context.get_agent_session_id(executor, session_id, client_thread_id)

    def set_agent_session_id(
        self,
        executor: str,
        session_id: str,
        client_thread_id: str,
        agent_session_id: str,
    ) -> None:
        self._session_context.set_agent_session_id(
            executor,
            session_id,
            client_thread_id,
            agent_session_id,
        )

    def delete_agent_session_id(self, executor: str, session_id: str, client_thread_id: str) -> None:
        self._session_context.delete_agent_session_id(executor, session_id, client_thread_id)
