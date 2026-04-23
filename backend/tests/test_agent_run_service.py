from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from app.agent_run_finalizer import AgentRunOutcome
from app.agent_run_service import AgentRunService
from app.models.schemas import RunRecord
from app.run_state import RunState
from app.storage import RunStore


@dataclass
class _FakeEnvironment:
    codex_binary: str = "codex"
    codex_home: Path | None = None
    codex_enable_web_search: bool = False
    claude_timeout_sec: int = 60
    codex_timeout_sec: int = 60

    def runtime_context_leak_markers(self) -> list[str]:
        return []

    def build_runtime_agent_prompt(
        self,
        prompt: str,
        *,
        executor: str,
        response_profile: str,
        profile_agents: str,
        profile_memory: str,
        include_profile_agents: bool,
        include_profile_memory: bool,
        memory_file_hint: str,
    ) -> str:
        return prompt


@dataclass
class _FakeProfileStore:
    staged_paths: list[Path] = field(default_factory=list)
    synced_paths: list[Path] = field(default_factory=list)

    def load_context(self, *, session_id_hint: str) -> tuple[str, str]:
        return "", ""

    def stage_files_in_workdir(
        self,
        workdir: Path,
        *,
        session_id_hint: str,
        include_agents: bool,
        include_memory: bool,
    ) -> Path:
        path = workdir / ".mobaile" / "MEMORY.md"
        self.staged_paths.append(path)
        return path

    def sync_memory_from_workdir(self, workdir_memory_path: Path | None) -> None:
        if workdir_memory_path is None:
            return
        self.synced_paths.append(workdir_memory_path)


def _run_state(tmp_path: Path) -> RunState:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-1",
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


def test_agent_run_service_retries_stale_codex_resume_with_fresh_session(monkeypatch, tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    profile_store = _FakeProfileStore()
    service = AgentRunService(
        environment=_FakeEnvironment(),  # type: ignore[arg-type]
        run_state=run_state,
        profile_store=profile_store,  # type: ignore[arg-type]
    )
    client_thread_id = "thread-1"
    run_state.run_store.set_agent_session_id("codex", "session-1", client_thread_id, "stale-thread")

    start_calls: list[str | None] = []
    monitor_calls: list[str | None] = []

    monkeypatch.setattr(service, "_make_agent_executor", lambda executor, workdir: object())

    def fake_start_process(
        *,
        agent_executor,
        executor,
        agent_prompt,
        resume_session_id,
        codex_model_override,
        codex_reasoning_effort_override,
        claude_model_override,
    ):
        start_calls.append(resume_session_id)
        return object()

    def fake_monitor_process(
        proc,
        *,
        run_id,
        prompt,
        session_id,
        agent_executor,
        executor,
        client_thread_id,
        resume_session_id,
    ):
        monitor_calls.append(resume_session_id)
        if resume_session_id == "stale-thread":
            return AgentRunOutcome(exit_code=1, resume_failure_reason="stale_session")

        assert client_thread_id is not None
        assert run_state.run_store.get_agent_session_id(executor, session_id, client_thread_id) is None
        run_state.run_store.set_agent_session_id(executor, session_id, client_thread_id, "fresh-thread")
        run_state.append_chat_message(run_id, summary="Fresh session succeeded.")
        return AgentRunOutcome(exit_code=0)

    monkeypatch.setattr(service, "_start_process", fake_start_process)
    monkeypatch.setattr(service, "_monitor_process", fake_monitor_process)

    service.run(
        "run-1",
        "Test",
        workdir=tmp_path,
        session_id="session-1",
        executor="codex",
        client_thread_id=client_thread_id,
    )

    run = run_state.get_run("run-1")

    assert run is not None
    assert start_calls == ["stale-thread", None]
    assert monitor_calls == ["stale-thread", None]
    assert run.status == "completed"
    assert run.summary == "Run completed successfully"
    assert run_state.run_store.get_agent_session_id("codex", "session-1", client_thread_id) == "fresh-thread"
    assert any(event.type == "action.completed" and "resume failed" in event.message for event in run.events)
    assert any(event.type == "action.started" and event.action_index == 1 for event in run.events)
    assert profile_store.synced_paths == [tmp_path / ".mobaile" / "MEMORY.md"]
