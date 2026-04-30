from __future__ import annotations

import json
from pathlib import Path

from app.agent_stream_handler import AgentStreamHandler
from app.codex_text import CodexAssistantExtractor
from app.models.schemas import RunRecord
from app.run_state import RunState
from app.storage import RunStore


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


def test_agent_stream_handler_links_codex_sessions(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)
    extractor = CodexAssistantExtractor("hello", [])

    blocked, linked_session_id = handler.consume_message(
        json.dumps({"type": "thread.started", "thread_id": "thread-1"}),
        run_id="run-1",
        session_id="session-1",
        executor="codex",
        client_thread_id="chat-1",
        linked_session_id=None,
        chat_extractor=extractor,
    )

    assert blocked is False
    assert linked_session_id == "thread-1"
    assert run_state.run_store.get_agent_session_id("codex", "session-1", "chat-1") == "thread-1"
    run = run_state.get_run("run-1")
    assert run is not None
    assert any(event.message == "codex session linked (thread-1)" for event in run.events)


def test_agent_stream_handler_blocks_on_human_unblock_payload(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)
    payload = json.dumps(
        {
            "type": "assistant_response",
            "version": "1.0",
            "summary": "Human unblock required",
            "sections": [{"title": "Human Unblock", "body": "Complete the CAPTCHA"}],
            "agenda_items": [],
            "artifacts": [],
        }
    )

    blocked = handler.append_assistant_payload("run-1", payload)

    assert blocked is True
    run = run_state.get_run("run-1")
    assert run is not None
    assert run.status == "blocked"
    assert run.pending_human_unblock is not None
    assert run.pending_human_unblock.instructions == "Complete the CAPTCHA"
    assert any(event.type == "run.blocked" for event in run.events)


def test_agent_stream_handler_streams_claude_messages_and_links_sessions(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)

    blocked, linked_session_id = handler.consume_message(
        json.dumps(
            {
                "type": "assistant",
                "session_id": "claude-1",
                "message": {"content": [{"type": "text", "text": "started from claude"}]},
            }
        ),
        run_id="run-1",
        session_id="session-1",
        executor="claude",
        client_thread_id="chat-1",
        linked_session_id=None,
        chat_extractor=None,
    )

    assert blocked is False
    assert linked_session_id == "claude-1"
    assert run_state.run_store.get_agent_session_id("claude", "session-1", "chat-1") == "claude-1"
    run = run_state.get_run("run-1")
    assert run is not None
    chat_messages = [event.message for event in run.events if event.type == "chat.message"]
    assert any("started from claude" in message for message in chat_messages)


def test_agent_stream_handler_flushes_codex_extractor_output(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)
    extractor = CodexAssistantExtractor("prompt", [])

    assert handler.consume_message(
        "codex",
        run_id="run-1",
        session_id="session-1",
        executor="codex",
        client_thread_id=None,
        linked_session_id=None,
        chat_extractor=extractor,
    ) == (False, None)
    assert handler.consume_message(
        "Implemented the fix.",
        run_id="run-1",
        session_id="session-1",
        executor="codex",
        client_thread_id=None,
        linked_session_id=None,
        chat_extractor=extractor,
    ) == (False, None)

    blocked = handler.flush_codex_messages("run-1", chat_extractor=extractor)

    assert blocked is False
    run = run_state.get_run("run-1")
    assert run is not None
    chat_messages = [event.message for event in run.events if event.type == "chat.message"]
    assert any("Implemented the fix." in message for message in chat_messages)


def test_agent_stream_handler_preserves_codex_structured_diagnostics(tmp_path: Path) -> None:
    run_state = _run_state(tmp_path)
    handler = AgentStreamHandler(run_state=run_state)
    extractor = CodexAssistantExtractor("prompt", [])

    blocked, linked_session_id = handler.consume_message(
        json.dumps(
            {
                "type": "item.completed",
                "item": {
                    "type": "command_execution",
                    "command": "pytest backend/tests/test_chat_envelope.py",
                },
            }
        ),
        run_id="run-1",
        session_id="session-1",
        executor="codex",
        client_thread_id=None,
        linked_session_id=None,
        chat_extractor=extractor,
    )

    assert blocked is False
    assert linked_session_id is None
    run = run_state.get_run("run-1")
    assert run is not None
    log_messages = [event.message for event in run.events if event.type == "log.message"]
    assert any("command_execution" in message and "pytest" in message for message in log_messages)
