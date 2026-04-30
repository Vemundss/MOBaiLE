from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from app.agent_run_finalizer import AgentRunFinalizer, AgentRunOutcome
from app.models.schemas import RunRecord
from app.run_state import RunState
from app.storage import RunStore


@dataclass
class _FakeProfileStore:
    synced_paths: list[Path] = field(default_factory=list)

    def sync_memory_from_workdir(self, workdir_memory_path: Path | None) -> None:
        if workdir_memory_path is None:
            return
        self.synced_paths.append(workdir_memory_path)


def _run_state(tmp_path: Path, *, status: str = "running", summary: str = "running") -> RunState:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-1",
            session_id="session-1",
            executor="codex",
            utterance_text="hello",
            status=status,
            summary=summary,
            events=[],
        )
    )
    return run_state


def test_agent_run_finalizer_records_missing_binary(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 60,
    )
    workdir_memory_path = tmp_path / "MEMORY.md"

    finalizer.record_missing_binary("run-1", executor="codex", workdir_memory_path=workdir_memory_path)

    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "failed"
    assert run.summary == "Run failed"
    assert [event.type for event in run.events] == ["chat.message", "action.stderr", "action.completed", "run.failed"]
    recovery = json.loads(run.events[0].message)
    assert recovery["warnings"][0]["level"] == "error"
    assert recovery["next_actions"][0]["title"] == "Fix executor availability"
    assert profile_store.synced_paths == [workdir_memory_path]


def test_agent_run_finalizer_marks_blocked_runs_and_preserves_summary(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path, status="blocked", summary="Complete the CAPTCHA")
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 60,
    )
    workdir_memory_path = tmp_path / "MEMORY.md"

    finalizer.finalize_run(
        "run-1",
        executor="codex",
        outcome=AgentRunOutcome(exit_code=143, blocked=True),
        workdir_memory_path=workdir_memory_path,
    )

    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "blocked"
    assert run.summary == "Complete the CAPTCHA"
    assert [event.type for event in run.events] == ["action.completed"]
    assert "awaiting user input" in run.events[0].message
    assert profile_store.synced_paths == [workdir_memory_path]


def test_agent_run_finalizer_marks_timed_out_runs(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 7,
    )
    workdir_memory_path = tmp_path / "MEMORY.md"

    finalizer.finalize_run(
        "run-1",
        executor="codex",
        outcome=AgentRunOutcome(exit_code=143, timed_out=True),
        workdir_memory_path=workdir_memory_path,
    )

    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "failed"
    assert run.summary == "Run timed out after 7s"
    assert [event.type for event in run.events] == ["action.completed", "chat.message", "run.failed"]
    recovery = json.loads(run.events[1].message)
    assert recovery["warnings"][0]["message"] == "Run timed out after 7s"
    assert any(item["kind"] == "open_logs" for item in recovery["next_actions"])
    assert profile_store.synced_paths == [workdir_memory_path]


def test_agent_run_finalizer_marks_successful_runs_completed(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 60,
    )
    workdir_memory_path = tmp_path / "MEMORY.md"

    finalizer.finalize_run(
        "run-1",
        executor="claude",
        outcome=AgentRunOutcome(exit_code=0),
        workdir_memory_path=workdir_memory_path,
    )

    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "completed"
    assert run.summary == "Run completed successfully"
    assert [event.type for event in run.events] == ["action.completed", "run.completed"]
    assert "claude exec finished (exit=0)" in run.events[0].message
    assert profile_store.synced_paths == [workdir_memory_path]


def test_agent_run_finalizer_uses_latest_assistant_summary_for_completed_runs(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 60,
    )
    workdir_memory_path = tmp_path / "MEMORY.md"
    run_state.append_assistant_payload(
        "run-1",
        "## Result\nImplemented the fix and verified the targeted tests.",
    )

    finalizer.finalize_run(
        "run-1",
        executor="codex",
        outcome=AgentRunOutcome(exit_code=0),
        workdir_memory_path=workdir_memory_path,
    )

    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "completed"
    assert run.summary == "Implemented the fix and verified the targeted tests."
    assert [event.type for event in run.events] == ["chat.message", "action.completed", "run.completed"]
    assert profile_store.synced_paths == [workdir_memory_path]


def test_agent_run_finalizer_ignores_progress_messages_for_completed_summary(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 60,
    )
    workdir_memory_path = tmp_path / "MEMORY.md"
    run_state.append_assistant_payload("run-1", "Running the test suite now...")

    finalizer.finalize_run(
        "run-1",
        executor="codex",
        outcome=AgentRunOutcome(exit_code=0),
        workdir_memory_path=workdir_memory_path,
    )

    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "completed"
    assert run.summary == "Run completed successfully"


def test_agent_run_finalizer_adds_recovery_when_failed_run_has_no_final_result(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 60,
    )
    workdir_memory_path = tmp_path / "MEMORY.md"

    finalizer.finalize_run(
        "run-1",
        executor="codex",
        outcome=AgentRunOutcome(exit_code=2),
        workdir_memory_path=workdir_memory_path,
    )

    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "failed"
    assert run.summary == "The agent exited before sending a final result."
    assert [event.type for event in run.events] == ["action.completed", "chat.message", "run.failed"]
    recovery = json.loads(run.events[1].message)
    assert recovery["warnings"][0]["level"] == "error"
    assert any(item["kind"] == "retry" for item in recovery["next_actions"])


def test_agent_run_finalizer_skips_memory_sync_when_profile_memory_is_disabled(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    finalizer = AgentRunFinalizer(
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
        timeout_resolver=lambda executor: 60,
    )

    finalizer.finalize_run(
        "run-1",
        executor="codex",
        outcome=AgentRunOutcome(exit_code=0),
        workdir_memory_path=None,
    )

    assert profile_store.synced_paths == []
