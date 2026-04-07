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

    loaded = state.get_run("run-activity")

    assert loaded is not None
    event = loaded.events[-1]
    assert event.type == "activity.updated"
    assert event.stage == "planning"
    assert event.title == "Planning"
    assert event.display_message == "Reviewing the request and planning the next steps."
    assert event.level == "info"
    assert event.message == "Reviewing the request and planning the next steps."


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
