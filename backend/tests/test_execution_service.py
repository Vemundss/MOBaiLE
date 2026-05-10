from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from app.execution_service import ExecutionService
from app.executors.shell_executor import ShellExecutor
from app.models.schemas import ActionResult, RunRecord
from app.run_state import RunState
from app.storage import RunStore


@dataclass
class _FakeEnvironment:
    codex_timeout_sec: int = 60
    claude_timeout_sec: int = 60
    shell_timeout_sec: int = 60
    shell_binary: str = "/bin/sh"
    security_mode: str = "full-access"

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


def test_shell_executor_runs_command_through_user_shell(tmp_path: Path) -> None:
    executor = ShellExecutor(tmp_path, shell_binary="/bin/sh")

    result = executor.execute("printf 'hello' > greeting.txt && cat greeting.txt", timeout_sec=5)

    assert result.success is True
    assert result.exit_code == 0
    assert result.stdout == "hello"
    assert (tmp_path / "greeting.txt").read_text(encoding="utf-8") == "hello"


def test_shell_executor_drains_large_stdout(tmp_path: Path) -> None:
    executor = ShellExecutor(tmp_path, shell_binary="/bin/sh")

    result = executor.execute("python3 -c 'import sys; sys.stdout.write(\"x\" * 200000)'", timeout_sec=5)

    assert result.success is True
    assert len(result.stdout) == 200000


def test_execution_service_records_direct_shell_result_payload(tmp_path: Path) -> None:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-shell-result",
            session_id="session-1",
            executor="shell",
            utterance_text="printf hello",
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

    service.run_shell_command("run-shell-result", "printf 'hello'; printf 'warn' >&2", tmp_path)

    run = run_state.get_run("run-shell-result")
    assert run is not None
    chat_events = [event for event in run.events if event.type == "chat.message"]
    assert chat_events
    payload = json.loads(chat_events[-1].message)
    assert payload["commands_run"] == []
    assert payload["shell_results"] == [
        {
            "command": "printf 'hello'; printf 'warn' >&2",
            "status": "passed",
            "exit_code": 0,
            "stdout": "hello",
            "stderr": "warn",
            "summary": "ran 'printf 'hello'; printf 'warn' >&2'",
        }
    ]


def test_shell_output_paths_do_not_become_file_change_cards(tmp_path: Path) -> None:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-shell-path-output",
            session_id="session-1",
            executor="shell",
            utterance_text="rg test",
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

    command = (
        "printf '%s\\n' "
        "'AGENTS.md:- Backend Python changes: run `uv run pytest tests/test_api.py`' "
        "'AGENTS.md:- Known hotspots: `storage/run_store.py`, `tests/test_api.py`.'"
    )
    service.run_shell_command("run-shell-path-output", command, tmp_path)

    run = run_state.get_run("run-shell-path-output")
    assert run is not None
    chat_events = [event for event in run.events if event.type == "chat.message"]
    assert chat_events
    payload = json.loads(chat_events[-1].message)
    assert payload["shell_results"]
    assert payload["file_changes"] == []
    assert payload["commands_run"] == []
    assert payload["tests_run"] == []


def test_shell_result_summary_names_ripgrep_no_matches() -> None:
    result = ActionResult(success=False, exit_code=1, stdout="", stderr="", details="ran 'rg missing'")

    assert ExecutionService._shell_result_summary("rg missing", result) == "No matches."


def test_shell_result_summary_explains_command_not_found_in_shell_mode() -> None:
    result = ActionResult(
        success=False,
        exit_code=127,
        stdout="",
        stderr="zsh:1: command not found: There\n",
        details="ran 'There is something wrong with the Shell mode'",
    )

    assert ExecutionService._shell_result_summary(
        "There is something wrong with the Shell mode",
        result,
    ) == (
        "Command not found: There. "
        "Shell mode runs host commands; switch to an agent executor for natural-language tasks."
    )


def test_shell_result_summary_names_changed_working_directory(tmp_path: Path) -> None:
    target_dir = tmp_path / "ios"
    target_dir.mkdir()
    result = ActionResult(success=True, exit_code=0, stdout="", stderr="", details="ran 'cd ios'")

    assert ExecutionService._shell_result_summary("cd ios", result, workdir=tmp_path) == (
        f"Working directory changed to {target_dir}."
    )


def test_shell_result_summary_names_leading_cd_prefix_working_directory(tmp_path: Path) -> None:
    target_dir = tmp_path / "ios"
    target_dir.mkdir()
    result = ActionResult(
        success=True,
        exit_code=0,
        stdout=str(target_dir),
        stderr="",
        details="ran 'cd ios && pwd'",
    )

    assert ExecutionService._shell_result_summary("cd ios&&pwd", result, workdir=tmp_path) == (
        f"Working directory changed to {target_dir}."
    )


def test_shell_executor_stops_running_command_when_cancelled(tmp_path: Path) -> None:
    cancel_at = time.monotonic() + 0.3
    executor = ShellExecutor(tmp_path, shell_binary="/bin/sh", is_cancelled=lambda: time.monotonic() >= cancel_at)
    started = time.monotonic()

    result = executor.execute("python3 -c 'import time; time.sleep(30)'", timeout_sec=0)

    assert time.monotonic() - started < 5
    assert result.success is False
    assert result.details == "command cancelled"


def test_execution_service_marks_shell_run_cancelled_during_command(tmp_path: Path) -> None:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-shell-cancel",
            session_id="session-1",
            executor="shell",
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
    cancel_at = time.monotonic() + 0.3
    original_is_cancelled = run_state.is_cancelled

    def auto_cancel(run_id: str) -> bool:
        if run_id == "run-shell-cancel" and time.monotonic() >= cancel_at:
            run_state.request_cancel(run_id)
        return original_is_cancelled(run_id)

    run_state.is_cancelled = auto_cancel  # type: ignore[method-assign]

    service.run_shell_command("run-shell-cancel", "python3 -c 'import time; time.sleep(30)'", tmp_path)

    run = run_state.get_run("run-shell-cancel")
    assert run is not None
    assert run.status == "cancelled"
    assert any(event.type == "run.cancelled" for event in run.events)


def test_execution_service_rejects_dangerous_shell_command_in_safe_mode(tmp_path: Path) -> None:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id="run-shell-dangerous",
            session_id="session-1",
            executor="shell",
            utterance_text="rm -rf build",
            working_directory=str(tmp_path),
            status="running",
            summary="Run started",
            events=[],
        )
    )
    service = ExecutionService(
        environment=_FakeEnvironment(security_mode="safe"),  # type: ignore[arg-type]
        run_state=run_state,
        profile_store=_FakeProfileStore(),  # type: ignore[arg-type]
        fetch_calendar_events=lambda: [],
    )

    service.run_shell_command(
        "run-shell-dangerous",
        "rm -rf build",
        tmp_path,
        guardrail_message="Potentially destructive request detected.",
    )

    run = run_state.get_run("run-shell-dangerous")
    assert run is not None
    assert run.status == "rejected"
    assert run.summary == "Shell command rejected by safe mode"
    assert any(event.type == "run.failed" for event in run.events)
