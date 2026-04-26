from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path

from app.execution_service import ExecutionService
from app.executors.local_executor import LocalExecutor
from app.models.schemas import Action, ActionPlan, RunRecord
from app.run_state import RunState
from app.storage import RunStore


@dataclass
class _FakeEnvironment:
    codex_timeout_sec: int = 60
    claude_timeout_sec: int = 60

    def runtime_context_leak_markers(self) -> list[str]:
        return []


@dataclass
class _FakeProfileStore:
    synced_paths: list[Path] = field(default_factory=list)

    def sync_memory_from_workdir(self, workdir_memory_path: Path | None) -> None:
        if workdir_memory_path is not None:
            self.synced_paths.append(workdir_memory_path)


def _run_state(tmp_path: Path) -> RunState:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-worker-crash",
            session_id="session-1",
            executor="codex",
            utterance_text="Test",
            working_directory=str(tmp_path),
            status="running",
            summary="Run started",
            events=[],
        )
    )
    return run_state


def test_agent_worker_exception_marks_run_failed(monkeypatch, tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    service = ExecutionService(
        environment=_FakeEnvironment(),  # type: ignore[arg-type]
        run_state=run_state,
        profile_store=_FakeProfileStore(),  # type: ignore[arg-type]
        fetch_calendar_events=lambda: [],
    )

    def crash(*_args: object, **_kwargs: object) -> None:
        raise TypeError("bad worker wiring")

    monkeypatch.setattr(service.agent_run_service, "run", crash)

    service.run_agent(
        "run-worker-crash",
        "Test",
        workdir=tmp_path,
        session_id="session-1",
        executor="codex",
    )

    run = run_state.get_run("run-worker-crash")

    assert run is not None
    assert run.status == "failed"
    assert run.summary == "Agent worker crashed"
    assert any(event.type == "action.stderr" and "bad worker wiring" in event.message for event in run.events)
    assert any(event.type == "run.failed" for event in run.events)


def test_local_executor_stops_running_command_when_cancelled(tmp_path: Path) -> None:
    cancel_at = time.monotonic() + 0.3
    executor = LocalExecutor(tmp_path, is_cancelled=lambda: time.monotonic() >= cancel_at)
    started = time.monotonic()

    result = executor.execute(
        Action(type="run_command", command="python3 -c 'import time; time.sleep(30)'")
    )

    assert time.monotonic() - started < 5
    assert result.success is False
    assert result.details == "command cancelled"


def test_execution_service_marks_local_run_cancelled_during_command(tmp_path: Path) -> None:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-local-cancel",
            session_id="session-1",
            executor="local",
            utterance_text="Test",
            working_directory=str(tmp_path),
            status="running",
            summary="Run started",
            events=[],
        )
    )
    service = ExecutionService(
        environment=_FakeEnvironment(),  # type: ignore[arg-type]
        run_state=run_state,
        profile_store=_FakeProfileStore(),  # type: ignore[arg-type]
        fetch_calendar_events=lambda: [],
    )
    plan = ActionPlan(
        goal="sleep",
        actions=[Action(type="run_command", command="python3 -c 'import time; time.sleep(30)'")],
    )

    cancel_at = time.monotonic() + 0.3
    original_is_cancelled = run_state.is_cancelled

    def auto_cancel(run_id: str) -> bool:
        if run_id == "run-local-cancel" and time.monotonic() >= cancel_at:
            run_state.request_cancel(run_id)
        return original_is_cancelled(run_id)

    run_state.is_cancelled = auto_cancel  # type: ignore[method-assign]

    service.run_local_plan("run-local-cancel", plan, tmp_path)

    run = run_state.get_run("run-local-cancel")
    assert run is not None
    assert run.status == "cancelled"
    assert any(event.type == "run.cancelled" for event in run.events)
