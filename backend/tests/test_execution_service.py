from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from app.execution_service import ExecutionService
from app.models.schemas import RunRecord
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
