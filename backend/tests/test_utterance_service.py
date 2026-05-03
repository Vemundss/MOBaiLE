from __future__ import annotations

import os
from pathlib import Path

import pytest
from fastapi import HTTPException

from app.models.schemas import (
    Action,
    ActionPlan,
    RunRecord,
    SessionContextResponse,
    SessionRuntimeSettingValue,
    UtteranceRequest,
)
from app.run_state import RunState
from app.runtime_environment import RuntimeEnvironment
from app.storage import RunStore
from app.utterance_service import UtteranceService

from .api_test_support import write_executable


class FakeExecutionService:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[object, ...]]] = []
        self.terminated_run_ids: list[str] = []

    def terminate_active_process(self, run_id: str) -> None:
        self.terminated_run_ids.append(run_id)

    def run_calendar_adapter(self, run_id: str, prompt: str) -> None:
        self.calls.append(("calendar", (run_id, prompt)))

    def run_agent(
        self,
        run_id: str,
        prompt: str,
        workdir: Path,
        session_id: str,
        executor: str,
        client_thread_id: str | None = None,
        response_profile: str = "guided",
        codex_model_override: str | None = None,
        codex_reasoning_effort_override: str | None = None,
        claude_model_override: str | None = None,
        include_profile_agents: bool = True,
        include_profile_memory: bool = True,
        guardrail_message: str | None = None,
    ) -> None:
        self.calls.append(
            (
                "agent",
                (
                    run_id,
                    prompt,
                    workdir,
                    session_id,
                    executor,
                    client_thread_id,
                    response_profile,
                    codex_model_override,
                    codex_reasoning_effort_override,
                    claude_model_override,
                    include_profile_agents,
                    include_profile_memory,
                    guardrail_message,
                ),
            )
        )

    def run_local_plan(self, run_id: str, plan: ActionPlan, workdir: Path) -> None:
        self.calls.append(("local", (run_id, plan, workdir)))


def _environment(monkeypatch, tmp_path: Path, **extra_env: str) -> RuntimeEnvironment:
    for name in (
        "VOICE_AGENT_DEFAULT_WORKDIR",
        "VOICE_AGENT_DEFAULT_EXECUTOR",
        "VOICE_AGENT_CODEX_GUARDRAILS",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("VOICE_AGENT_API_TOKEN", "test-token")
    monkeypatch.setenv("VOICE_AGENT_DEFAULT_WORKDIR", str(tmp_path / "workspace"))
    for key, value in extra_env.items():
        monkeypatch.setenv(key, value)
    return RuntimeEnvironment.from_env(tmp_path)


def _agent_binary_env(tmp_path: Path, name: str) -> dict[str, str]:
    write_executable(tmp_path / name, "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    return {
        "PATH": f"{tmp_path}:{env_path}",
        f"VOICE_AGENT_{name.upper()}_BINARY": name,
    }


def _run_state(tmp_path: Path) -> RunState:
    return RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)


def _session_context(
    *,
    session_id: str,
    executor: str = "local",
    working_directory: str | None = None,
    resolved_working_directory: str,
    runtime_settings: list[SessionRuntimeSettingValue] | None = None,
    codex_model: str | None = None,
    codex_reasoning_effort: str | None = None,
    claude_model: str | None = None,
    latest_run_id: str | None = None,
    latest_run_status: str | None = None,
) -> SessionContextResponse:
    return SessionContextResponse(
        session_id=session_id,
        executor=executor,  # type: ignore[arg-type]
        working_directory=working_directory,
        runtime_settings=runtime_settings or [],
        codex_model=codex_model,
        codex_reasoning_effort=codex_reasoning_effort,  # type: ignore[arg-type]
        claude_model=claude_model,
        resolved_working_directory=resolved_working_directory,
        latest_run_id=latest_run_id,
        latest_run_status=latest_run_status,  # type: ignore[arg-type]
    )


def test_utterance_service_routes_calendar_requests_to_calendar_runner(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path, **_agent_binary_env(tmp_path, "codex"))
    run_state = _run_state(tmp_path)
    execution = FakeExecutionService()
    launched: list[tuple[str, tuple[object, ...]]] = []
    workspace = env.default_workdir

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="codex",
            resolved_working_directory=str(workspace),
        ),
        background_launcher=lambda target, args: launched.append((target.__name__, args)),
        run_id_factory=lambda: "run-calendar",
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-calendar",
            executor="codex",
            utterance_text="Check my calendar today",
        )
    )

    assert result.status == "accepted"
    run = run_state.get_run("run-calendar")
    assert run is not None
    assert run.status == "running"
    assert run.executor == "codex"
    assert launched == [("run_calendar_adapter", ("run-calendar", "Check my calendar today"))]


def test_utterance_service_rejects_guardrailed_agent_requests(monkeypatch, tmp_path: Path) -> None:
    env = _environment(
        monkeypatch,
        tmp_path,
        VOICE_AGENT_CODEX_GUARDRAILS="enforce",
        **_agent_binary_env(tmp_path, "codex"),
    )
    run_state = _run_state(tmp_path)
    execution = FakeExecutionService()
    launched: list[tuple[str, tuple[object, ...]]] = []

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="codex",
            resolved_working_directory=str(env.default_workdir),
        ),
        background_launcher=lambda target, args: launched.append((target.__name__, args)),
        run_id_factory=lambda: "run-guardrail",
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-guardrail",
            executor="codex",
            utterance_text="please run rm -rf /tmp/test",
        )
    )

    assert result.status == "rejected"
    run = run_state.get_run("run-guardrail")
    assert run is not None
    assert run.status == "rejected"
    assert run.events[0].type == "run.failed"
    assert launched == []


def test_utterance_service_keeps_previous_run_when_new_request_is_rejected(monkeypatch, tmp_path: Path) -> None:
    env = _environment(
        monkeypatch,
        tmp_path,
        VOICE_AGENT_CODEX_GUARDRAILS="enforce",
        **_agent_binary_env(tmp_path, "codex"),
    )
    run_state = _run_state(tmp_path)
    run_state.store_run(
        RunRecord(
            run_id="run-old",
            session_id="sess-guardrail",
            executor="codex",
            utterance_text="old prompt",
            working_directory=str(env.default_workdir),
            status="running",
            summary="Run started",
        )
    )
    execution = FakeExecutionService()

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="codex",
            resolved_working_directory=str(env.default_workdir),
            latest_run_id="run-old",
            latest_run_status="running",
        ),
        background_launcher=lambda target, args: None,
        run_id_factory=lambda: "run-rejected",
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-guardrail",
            executor="codex",
            utterance_text="please run rm -rf /tmp/test",
        )
    )

    assert result.status == "rejected"
    assert run_state.is_cancelled("run-old") is False
    assert execution.terminated_run_ids == []


def test_utterance_service_uses_session_defaults_for_local_runs(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path)
    run_state = _run_state(tmp_path)
    execution = FakeExecutionService()
    launched: list[tuple[str, tuple[object, ...]]] = []
    project_dir = env.default_workdir / "project"

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="local",
            working_directory=str(project_dir),
            resolved_working_directory=str(project_dir),
        ),
        background_launcher=lambda target, args: launched.append((target.__name__, args)),
        run_id_factory=lambda: "run-local",
        plan_builder=lambda prompt: ActionPlan(
            goal=prompt,
            actions=[Action(type="run_command", command="python3 hello.py")],
        ),
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-local",
            utterance_text="create a hello python script and run it",
        )
    )

    assert result.status == "accepted"
    run = run_state.get_run("run-local")
    assert run is not None
    assert run.executor == "local"
    assert run.working_directory == str(project_dir)
    assert launched[0][0] == "run_local_plan"
    assert launched[0][1][2] == project_dir


def test_utterance_service_marks_run_failed_when_background_launch_fails(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path)
    run_state = _run_state(tmp_path)
    execution = FakeExecutionService()

    def fail_to_launch(*_args: object) -> None:
        raise RuntimeError("cannot start worker thread")

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="local",
            resolved_working_directory=str(env.default_workdir),
        ),
        background_launcher=fail_to_launch,
        run_id_factory=lambda: "run-launch-failed",
        plan_builder=lambda prompt: ActionPlan(
            goal=prompt,
            actions=[Action(type="run_command", command="python3 hello.py")],
        ),
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-launch-failed",
            utterance_text="create a hello python script and run it",
        )
    )

    assert result.status == "rejected"
    assert result.run_id == "run-launch-failed"
    run = run_state.get_run("run-launch-failed")
    assert run is not None
    assert run.status == "failed"
    assert run.summary == "Local run failed to start"
    assert [event.type for event in run.events] == ["activity.completed", "action.stderr", "run.failed"]
    assert "cannot start worker thread" in run.events[1].message


def test_utterance_service_cancels_superseded_running_latest_run(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path, **_agent_binary_env(tmp_path, "codex"))
    run_state = _run_state(tmp_path)
    run_state.store_run(
        RunRecord(
            run_id="run-old",
            session_id="sess-supersede",
            executor="codex",
            utterance_text="old prompt",
            working_directory=str(env.default_workdir),
            status="running",
            summary="Run started",
        )
    )
    execution = FakeExecutionService()
    launched: list[tuple[str, tuple[object, ...]]] = []

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="codex",
            resolved_working_directory=str(env.default_workdir),
            latest_run_id="run-old",
            latest_run_status="running",
        ),
        background_launcher=lambda target, args: launched.append((target.__name__, args)),
        run_id_factory=lambda: "run-new",
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-supersede",
            executor="codex",
            utterance_text="new prompt",
        )
    )

    assert result.status == "accepted"
    assert run_state.is_cancelled("run-old") is True
    assert execution.terminated_run_ids == ["run-old"]
    assert launched[0][0] == "run_agent"


def test_utterance_service_passes_profile_context_toggles_to_agent_runs(monkeypatch, tmp_path: Path) -> None:
    env = _environment(
        monkeypatch,
        tmp_path,
        VOICE_AGENT_DEFAULT_EXECUTOR="codex",
        **_agent_binary_env(tmp_path, "codex"),
    )
    run_state = _run_state(tmp_path)
    execution = FakeExecutionService()
    launched: list[tuple[str, tuple[object, ...]]] = []

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="codex",
            resolved_working_directory=str(env.default_workdir),
            runtime_settings=[
                SessionRuntimeSettingValue(executor="codex", id="profile_agents", value="disabled"),
                SessionRuntimeSettingValue(executor="codex", id="profile_memory", value="enabled"),
            ],
        ),
        background_launcher=lambda target, args: launched.append((target.__name__, args)),
        run_id_factory=lambda: "run-profile-context",
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-profile-context",
            executor="codex",
            utterance_text="inspect the repo status",
        )
    )

    assert result.status == "accepted"
    assert launched[0][0] == "run_agent"
    assert launched[0][1][7] == "gpt-5.4"
    assert launched[0][1][10] is False
    assert launched[0][1][11] is True


def test_utterance_service_rejects_explicit_unavailable_agent(monkeypatch, tmp_path: Path) -> None:
    empty_path = tmp_path / "empty-bin"
    empty_path.mkdir()
    env = _environment(
        monkeypatch,
        tmp_path,
        PATH=str(empty_path),
        VOICE_AGENT_CODEX_BINARY="codex",
    )
    run_state = _run_state(tmp_path)
    execution = FakeExecutionService()
    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="local",
            resolved_working_directory=str(env.default_workdir),
        ),
        background_launcher=lambda target, args: None,
        run_id_factory=lambda: "run-unavailable",
    )

    with pytest.raises(HTTPException) as exc:
        service.submit(
            UtteranceRequest(
                session_id="sess-unavailable",
                executor="codex",
                utterance_text="inspect this repo",
            )
        )

    assert exc.value.status_code == 409
    assert "executor codex is not available" in str(exc.value.detail)
    assert run_state.get_run("run-unavailable") is None


def test_utterance_service_falls_back_from_stale_session_executor(monkeypatch, tmp_path: Path) -> None:
    empty_path = tmp_path / "empty-bin"
    empty_path.mkdir()
    env = _environment(
        monkeypatch,
        tmp_path,
        PATH=str(empty_path),
        VOICE_AGENT_CODEX_BINARY="codex",
    )
    run_state = _run_state(tmp_path)
    execution = FakeExecutionService()
    launched: list[tuple[str, tuple[object, ...]]] = []

    service = UtteranceService(
        environment=env,
        run_state=run_state,
        execution_service=execution,
        session_context_loader=lambda session_id: _session_context(
            session_id=session_id,
            executor="codex",
            resolved_working_directory=str(env.default_workdir),
        ),
        background_launcher=lambda target, args: launched.append((target.__name__, args)),
        run_id_factory=lambda: "run-stale-session-executor",
        plan_builder=lambda prompt: ActionPlan(
            goal=prompt,
            actions=[Action(type="run_command", command="python3 hello.py")],
        ),
    )

    result = service.submit(
        UtteranceRequest(
            session_id="sess-stale-executor",
            utterance_text="create a hello python script and run it",
        )
    )

    assert result.status == "accepted"
    run = run_state.get_run("run-stale-session-executor")
    assert run is not None
    assert run.executor == "local"
    assert launched[0][0] == "run_local_plan"
