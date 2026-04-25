from __future__ import annotations

from app.models.schemas import ExecutionEvent, RunDiagnostics, RunRecord
from app.run_state import RunState
from app.storage import RunStore


def test_run_state_lazy_loads_persisted_run(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    run = RunRecord(
        run_id="run-1",
        session_id="session-1",
        executor="local",
        utterance_text="hello",
        status="completed",
        summary="done",
        events=[ExecutionEvent(type="run.completed", message="done")],
    )
    run_store.upsert_run(run)
    for event in run.events:
        run_store.append_event(run.run_id, event)

    state = RunState(run_store, max_event_message_chars=16000)

    loaded = state.get_run("run-1")

    assert loaded is not None
    assert loaded.run_id == "run-1"
    assert loaded.summary == "done"
    assert [event.type for event in loaded.events] == ["run.completed"]
    assert [event.seq for event in loaded.events] == [0]


def test_run_state_assigns_monotonic_event_sequences(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    state = RunState(run_store, max_event_message_chars=16000)
    state.store_run(
        RunRecord(
            run_id="run-seq",
            session_id="session-1",
            executor="local",
            utterance_text="hello",
            status="running",
            summary="running",
            events=[],
        )
    )

    state.append_event("run-seq", ExecutionEvent(type="action.started", message="start"))
    state.append_event("run-seq", ExecutionEvent(type="run.completed", message="done"))

    loaded = state.get_run("run-seq")

    assert loaded is not None
    assert [event.seq for event in loaded.events] == [0, 1]


def test_run_state_returns_paginated_event_windows(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    state = RunState(run_store, max_event_message_chars=16000)
    state.store_run(
        RunRecord(
            run_id="run-page",
            session_id="session-1",
            executor="local",
            utterance_text="hello",
            status="running",
            summary="running",
            events=[],
        )
    )
    for index in range(6):
        state.append_event("run-page", ExecutionEvent(type="log.message", message=f"event {index}"))

    first = state.event_page("run-page", limit=2)

    assert first is not None
    assert first.total_count == 6
    assert first.has_more_before is True
    assert first.has_more_after is False
    assert first.next_before_seq == 4
    assert first.next_after_seq == 5
    assert [event.message for event in first.events] == ["event 4", "event 5"]

    second = state.event_page("run-page", limit=2, before_seq=first.next_before_seq)

    assert second is not None
    assert second.has_more_before is True
    assert second.has_more_after is True
    assert second.next_before_seq == 2
    assert second.next_after_seq == 3
    assert [event.message for event in second.events] == ["event 2", "event 3"]

    final = state.event_page("run-page", limit=2, before_seq=second.next_before_seq)

    assert final is not None
    assert final.has_more_before is False
    assert final.has_more_after is True
    assert final.next_before_seq == 0
    assert final.next_after_seq == 1
    assert [event.message for event in final.events] == ["event 0", "event 1"]

    forward = state.event_page("run-page", limit=2, after_seq=1)

    assert forward is not None
    assert forward.has_more_before is True
    assert forward.has_more_after is True
    assert [event.message for event in forward.events] == ["event 2", "event 3"]

    reloaded = RunState(run_store, max_event_message_chars=16000)
    persisted = reloaded.event_page("run-page", limit=3, before_seq=4)

    assert persisted is not None
    assert persisted.total_count == 6
    assert [event.message for event in persisted.events] == ["event 1", "event 2", "event 3"]


def test_store_run_persists_initial_events(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    state = RunState(run_store, max_event_message_chars=16000)

    state.store_run(
        RunRecord(
            run_id="run-rejected",
            session_id="session-1",
            executor="codex",
            utterance_text="dangerous",
            status="rejected",
            summary="blocked",
            events=[ExecutionEvent(type="run.failed", message="blocked by policy")],
        )
    )

    reloaded = RunState(run_store, max_event_message_chars=16000)
    loaded = reloaded.get_run("run-rejected")

    assert loaded is not None
    assert [event.type for event in loaded.events] == ["run.failed"]
    assert [event.seq for event in loaded.events] == [0]


def test_run_state_appends_activity_events_with_typed_metadata(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    state = RunState(run_store, max_event_message_chars=16000)
    state.store_run(
        RunRecord(
            run_id="run-activity",
            session_id="session-1",
            executor="local",
            utterance_text="hello",
            status="running",
            summary="running",
            events=[],
        )
    )

    state.append_activity_event(
        "run-activity",
        stage="planning",
        title="Planning",
        display_message="Reviewing the request and planning the next steps.",
    )

    reloaded = RunState(run_store, max_event_message_chars=16000)
    loaded = reloaded.get_run("run-activity")

    assert loaded is not None
    event = loaded.events[-1]
    assert event.type == "activity.updated"
    assert event.stage == "planning"
    assert event.title == "Planning"
    assert event.display_message == "Reviewing the request and planning the next steps."
    assert event.level == "info"
    assert event.message == "Reviewing the request and planning the next steps."


def test_run_state_reconciles_interrupted_running_runs(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    run_store.upsert_run(
        RunRecord(
            run_id="run-interrupted",
            session_id="session-1",
            executor="codex",
            utterance_text="hello",
            status="running",
            summary="running",
            events=[],
        )
    )

    state = RunState(run_store, max_event_message_chars=16000)
    state.reconcile_interrupted_runs()

    loaded = state.get_run("run-interrupted")

    assert loaded is not None
    assert loaded.status == "failed"
    assert loaded.summary == "Backend restarted before this run finished."
    assert [event.type for event in loaded.events[-2:]] == ["activity.completed", "run.failed"]
    assert loaded.events[-2].stage == "failed"
    assert loaded.events[-2].level == "error"


def test_request_cancel_lazy_loads_persisted_running_run(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    run_store.upsert_run(
        RunRecord(
            run_id="run-persisted-cancel",
            session_id="session-1",
            executor="codex",
            utterance_text="hello",
            status="running",
            summary="running",
            events=[],
        )
    )
    state = RunState(run_store, max_event_message_chars=16000)

    run = state.request_cancel("run-persisted-cancel")

    assert run.run_id == "run-persisted-cancel"
    assert state.is_cancelled("run-persisted-cancel") is True


def test_run_state_diagnostics_include_activity_stage_counts(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    state = RunState(run_store, max_event_message_chars=16000)
    state.store_run(
        RunRecord(
            run_id="run-diagnostics",
            session_id="session-1",
            executor="local",
            utterance_text="hello",
            status="running",
            summary="running",
            events=[],
        )
    )

    state.append_activity_event(
        "run-diagnostics",
        stage="planning",
        title="Planning",
        display_message="Reviewing the request.",
    )
    state.append_event("run-diagnostics", ExecutionEvent(type="action.started", message="start"))
    state.append_activity_event(
        "run-diagnostics",
        stage="executing",
        title="Executing",
        display_message="Running commands.",
    )

    diagnostics = state.diagnostics_for("run-diagnostics")

    assert isinstance(diagnostics, RunDiagnostics)
    assert diagnostics.activity_stage_counts == {"planning": 1, "executing": 1}
    assert diagnostics.latest_activity == "Running commands."
    assert diagnostics.event_count == 3


def test_run_state_diagnostics_capture_error_activity_without_stderr(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")
    state = RunState(run_store, max_event_message_chars=16000)
    state.store_run(
        RunRecord(
            run_id="run-error-diagnostics",
            session_id="session-1",
            executor="local",
            utterance_text="hello",
            status="failed",
            summary="failed",
            events=[],
        )
    )

    state.append_activity_event(
        "run-error-diagnostics",
        stage="executing",
        title="Executing",
        display_message="Calendar query failed.",
        level="error",
    )

    diagnostics = state.diagnostics_for("run-error-diagnostics")

    assert isinstance(diagnostics, RunDiagnostics)
    assert diagnostics.has_stderr is False
    assert diagnostics.last_error == "Calendar query failed."
    assert diagnostics.latest_activity == "Calendar query failed."


def test_run_store_persists_session_context(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")

    row = run_store.upsert_session_context(
        "session-1",
        executor="local",
        working_directory=str(tmp_path / "workspace"),
        runtime_settings_json=None,
        codex_model=None,
        codex_reasoning_effort=None,
        claude_model=None,
    )

    assert row["session_id"] == "session-1"
    assert row["executor"] == "local"
    assert row["working_directory"] == str(tmp_path / "workspace")

    loaded = run_store.get_session_context("session-1")

    assert loaded is not None
    assert loaded["executor"] == "local"
    assert loaded["working_directory"] == str(tmp_path / "workspace")


def test_run_store_prunes_stale_agent_sessions_on_access(tmp_path) -> None:
    run_store = RunStore(tmp_path / "runs.db")

    with run_store._connect() as conn:
        conn.execute(
            """
            INSERT INTO agent_session_map (
                executor, session_id, client_thread_id, agent_session_id, updated_at
            )
            VALUES (?, ?, ?, ?, datetime('now', '-120 days'))
            """,
            ("codex", "session-1", "thread-stale", "stale-thread"),
        )
        conn.execute(
            """
            INSERT INTO agent_session_map (
                executor, session_id, client_thread_id, agent_session_id, updated_at
            )
            VALUES (?, ?, ?, ?, datetime('now'))
            """,
            ("codex", "session-1", "thread-fresh", "fresh-thread"),
        )
        conn.execute(
            """
            INSERT INTO agent_session_map (
                executor, session_id, client_thread_id, agent_session_id, updated_at
            )
            VALUES (?, ?, ?, ?, datetime('now', '-120 days'))
            """,
            ("claude", "session-1", "thread-claude", "claude-thread"),
        )

    assert run_store.get_agent_session_id("codex", "session-1", "thread-stale") is None
    assert run_store.get_agent_session_id("codex", "session-1", "thread-fresh") == "fresh-thread"
    assert run_store.get_agent_session_id("claude", "session-1", "thread-claude") == "claude-thread"

    with run_store._connect() as conn:
        remaining = conn.execute(
            """
            SELECT executor, client_thread_id
            FROM agent_session_map
            ORDER BY executor, client_thread_id
            """
        ).fetchall()

    assert [(row["executor"], row["client_thread_id"]) for row in remaining] == [
        ("claude", "thread-claude"),
        ("codex", "thread-fresh"),
    ]
