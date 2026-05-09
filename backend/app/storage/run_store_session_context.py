from __future__ import annotations

import sqlite3
from typing import Callable

from app.models.schemas import HumanUnblockRequest

from .run_store_sql import (
    SESSION_CONTEXT_COLUMNS,
    SESSION_CONTEXT_MUTABLE_COLUMNS_WITH_UPDATED_AT,
)

ConnectionFactory = Callable[[], sqlite3.Connection]
AGENT_SESSION_RETENTION_DAYS = 90


def prune_stale_agent_sessions(conn: sqlite3.Connection, *, executor: str | None = None) -> None:
    if executor is not None and executor != "codex":
        return
    conn.execute(
        """
        DELETE FROM agent_session_map
        WHERE executor = 'codex'
          AND datetime(updated_at) < datetime('now', ?)
        """,
        (f"-{AGENT_SESSION_RETENTION_DAYS} days",),
    )


class SessionContextStore:
    def __init__(self, connect: ConnectionFactory) -> None:
        self._connect = connect

    def get_session_context(self, session_id: str) -> sqlite3.Row | None:
        with self._connect() as conn:
            return conn.execute(
                """
                SELECT
                    """
                + SESSION_CONTEXT_COLUMNS
                + """
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
        runtime_settings_json: str | None,
        codex_model: str | None,
        codex_reasoning_effort: str | None,
        claude_model: str | None,
    ) -> sqlite3.Row:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO session_context (
                    """
                + SESSION_CONTEXT_MUTABLE_COLUMNS_WITH_UPDATED_AT
                + """
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(session_id) DO UPDATE SET
                    executor=excluded.executor,
                    working_directory=excluded.working_directory,
                    runtime_settings_json=excluded.runtime_settings_json,
                    codex_model=excluded.codex_model,
                    codex_reasoning_effort=excluded.codex_reasoning_effort,
                    claude_model=excluded.claude_model,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (
                    session_id,
                    executor,
                    working_directory,
                    runtime_settings_json,
                    codex_model,
                    codex_reasoning_effort,
                    claude_model,
                ),
            )
            row = conn.execute(
                """
                SELECT
                    """
                + SESSION_CONTEXT_MUTABLE_COLUMNS_WITH_UPDATED_AT
                + """
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
            prune_stale_agent_sessions(conn, executor=executor)
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
            prune_stale_agent_sessions(conn, executor=executor)
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

    def delete_agent_session_id(self, executor: str, session_id: str, client_thread_id: str) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                DELETE FROM agent_session_map
                WHERE executor = ? AND session_id = ? AND client_thread_id = ?
                """,
                (executor, session_id, client_thread_id),
            )
