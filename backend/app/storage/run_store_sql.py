from __future__ import annotations

LEGACY_CODEX_THREAD_MAP_COMPAT_REMOVE_AFTER = "2026-07-01"

RUN_COLUMNS = """
run_id,
session_id,
executor,
utterance_text,
working_directory,
status,
pending_human_unblock_json,
plan_json,
summary,
created_at,
updated_at
"""

RUN_EVENT_COLUMNS = """
run_id,
seq,
event_id,
type,
action_index,
message,
created_at
"""

SESSION_CONTEXT_COLUMNS = """
session_id,
executor,
working_directory,
runtime_settings_json,
codex_model,
codex_reasoning_effort,
claude_model,
latest_run_id,
latest_run_status,
latest_run_summary,
latest_run_pending_human_unblock_json,
latest_run_updated_at,
updated_at
"""

SESSION_CONTEXT_MUTABLE_COLUMNS = """
session_id,
executor,
working_directory,
runtime_settings_json,
codex_model,
codex_reasoning_effort,
claude_model
"""

SESSION_CONTEXT_MUTABLE_COLUMNS_WITH_UPDATED_AT = SESSION_CONTEXT_MUTABLE_COLUMNS + ",\nupdated_at"
