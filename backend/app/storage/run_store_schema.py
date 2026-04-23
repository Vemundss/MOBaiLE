from __future__ import annotations

import sqlite3
from typing import Callable

from .run_store_session_context import prune_stale_agent_sessions

ConnectionFactory = Callable[[], sqlite3.Connection]
LegacyRunPayloadRow = tuple[str, str]


def initialize_run_store_schema(connect: ConnectionFactory) -> list[LegacyRunPayloadRow]:
    legacy_rows: list[LegacyRunPayloadRow] = []
    with connect() as conn:
        existing_runs = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='runs'"
        ).fetchone()
        if existing_runs is not None:
            columns = conn.execute("PRAGMA table_info(runs)").fetchall()
            column_names = {row["name"] for row in columns}
            if "payload_json" in column_names:
                legacy_rows = [
                    (str(row["run_id"]), str(row["payload_json"]))
                    for row in conn.execute("SELECT run_id, payload_json FROM runs").fetchall()
                    if row["payload_json"]
                ]
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
            conn.execute("ALTER TABLE runs ADD COLUMN executor TEXT NOT NULL DEFAULT 'local'")
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
                runtime_settings_json TEXT,
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
        if "runtime_settings_json" not in column_names:
            conn.execute("ALTER TABLE session_context ADD COLUMN runtime_settings_json TEXT")
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
        prune_stale_agent_sessions(conn)
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
            prune_stale_agent_sessions(conn)

    return legacy_rows
