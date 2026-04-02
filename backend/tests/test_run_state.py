from __future__ import annotations

from app.models.schemas import ExecutionEvent
from app.models.schemas import RunRecord
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
