from __future__ import annotations

import json
from pathlib import Path
from typing import Callable

from app.agent_process_monitor import AgentProcessMonitor
from app.agent_stream_handler import AgentStreamHandler
from app.models.schemas import RunRecord
from app.run_state import RunState
from app.storage import RunStore


class _FakeStdout:
    def __init__(self, lines: list[str], *, on_exhaust: Callable[[], None] | None = None) -> None:
        self._lines = lines
        self._on_exhaust = on_exhaust

    def __iter__(self):
        try:
            for line in self._lines:
                yield line
        finally:
            if self._on_exhaust is not None:
                self._on_exhaust()


class _FakeProcess:
    def __init__(self, lines: list[str], *, exit_code: int = 0, complete_on_drain: bool = True) -> None:
        self._exit_code = exit_code
        self._completed = False
        self._terminated = False
        self._killed = False
        on_exhaust = self._mark_completed if complete_on_drain else None
        self.stdout = _FakeStdout(lines, on_exhaust=on_exhaust)

    def _mark_completed(self) -> None:
        self._completed = True

    def poll(self) -> int | None:
        if self._completed or self._terminated or self._killed:
            return self._exit_code
        return None

    def terminate(self) -> None:
        self._terminated = True
        self._completed = True

    def kill(self) -> None:
        self._killed = True
        self._completed = True

    def wait(self, timeout: float | None = None) -> int:
        self._completed = True
        return self._exit_code


def _run_state(tmp_path: Path, *, run_id: str = "run-1") -> RunState:
    run_state = RunState(RunStore(tmp_path / "runs.db"), max_event_message_chars=16000)
    run_state.store_run(
        RunRecord(
            run_id=run_id,
            session_id="session-1",
            executor="codex",
            utterance_text="hello",
            status="running",
            summary="running",
            events=[],
        )
    )
    return run_state


def test_agent_process_monitor_streams_codex_messages(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)
    monitor = AgentProcessMonitor(
        run_state=run_state,
        stream_handler=handler,
        timeout_resolver=lambda executor: 60,
        leak_marker_provider=lambda: [],
    )
    proc = _FakeProcess(
        [
            json.dumps({"type": "thread.started", "thread_id": "thread-1"}) + "\n",
            json.dumps(
                {
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": "started memory"},
                }
            )
            + "\n",
        ]
    )

    outcome = monitor.monitor(
        proc,  # type: ignore[arg-type]
        run_id="run-1",
        prompt="hello",
        session_id="session-1",
        executor="codex",
        client_thread_id="chat-1",
        resume_session_id=None,
    )

    assert outcome.exit_code == 0
    assert outcome.cancelled is False
    assert outcome.timed_out is False
    assert outcome.blocked is False
    assert run_state.run_store.get_agent_session_id("codex", "session-1", "chat-1") == "thread-1"
    run = run_state.get_run("run-1")
    assert run is not None
    chat_messages = [event.message for event in run.events if event.type == "chat.message"]
    assert any("started memory" in message for message in chat_messages)


def test_agent_process_monitor_stops_cancelled_runs(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)
    monitor = AgentProcessMonitor(
        run_state=run_state,
        stream_handler=handler,
        timeout_resolver=lambda executor: 60,
        leak_marker_provider=lambda: [],
    )
    proc = _FakeProcess([], complete_on_drain=False)
    run_state.request_cancel("run-1")

    outcome = monitor.monitor(
        proc,  # type: ignore[arg-type]
        run_id="run-1",
        prompt="hello",
        session_id="session-1",
        executor="codex",
        client_thread_id=None,
        resume_session_id=None,
    )

    assert outcome.cancelled is True
    assert proc._terminated is True


def test_agent_process_monitor_classifies_stale_resume_failures(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)
    monitor = AgentProcessMonitor(
        run_state=run_state,
        stream_handler=handler,
        timeout_resolver=lambda executor: 60,
        leak_marker_provider=lambda: [],
    )
    proc = _FakeProcess(
        ["Error: thread/resume: thread/resume failed: no rollout found for thread id stale-thread\n"],
        exit_code=1,
    )

    outcome = monitor.monitor(
        proc,  # type: ignore[arg-type]
        run_id="run-1",
        prompt="hello",
        session_id="session-1",
        executor="codex",
        client_thread_id="chat-1",
        resume_session_id="stale-thread",
        resume_failure_classifier=lambda line: "stale_session" if "no rollout found" in line else None,
    )

    assert outcome.exit_code == 1
    assert outcome.resume_failure_reason == "stale_session"
