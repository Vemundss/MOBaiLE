from __future__ import annotations

from app.chat_envelope import human_unblock_request_from_envelope
from app.claude_text import (
    claude_assistant_text,
    claude_session_id,
    parse_claude_stream_event,
)
from app.codex_text import CodexAssistantExtractor, parse_codex_json_event
from app.models.schemas import AgentExecutorName, ExecutionEvent
from app.run_state import RunState


class AgentStreamHandler:
    def __init__(self, *, run_state: RunState) -> None:
        self.run_state = run_state

    def consume_message(
        self,
        message: str,
        *,
        run_id: str,
        session_id: str,
        executor: AgentExecutorName,
        client_thread_id: str | None,
        linked_session_id: str | None,
        chat_extractor: CodexAssistantExtractor | None,
    ) -> tuple[bool, str | None]:
        trimmed = message.rstrip()
        if not trimmed:
            return False, linked_session_id

        if executor == "codex":
            parsed = parse_codex_json_event(trimmed)
            if parsed is not None:
                linked_session_id, blocked = self._handle_codex_event(
                    run_id,
                    executor,
                    session_id,
                    client_thread_id,
                    linked_session_id,
                    parsed,
                )
                return blocked, linked_session_id

            self.run_state.append_log_message(run_id, trimmed, action_index=0)
            assert chat_extractor is not None
            for structured in chat_extractor.consume(trimmed):
                if self.append_assistant_payload(run_id, structured):
                    return True, linked_session_id
            return False, linked_session_id

        parsed = parse_claude_stream_event(trimmed)
        if parsed is not None:
            linked_session_id, blocked = self._handle_claude_event(
                run_id,
                executor,
                session_id,
                client_thread_id,
                linked_session_id,
                parsed,
            )
            return blocked, linked_session_id

        self.run_state.append_log_message(run_id, trimmed, action_index=0)
        return False, linked_session_id

    def flush_codex_messages(
        self,
        run_id: str,
        *,
        chat_extractor: CodexAssistantExtractor | None,
    ) -> bool:
        if chat_extractor is None:
            return False
        blocked = False
        for structured in chat_extractor.flush():
            if self.append_assistant_payload(run_id, structured):
                blocked = True
        return blocked

    def append_assistant_payload(self, run_id: str, raw_text: str) -> bool:
        envelope = self.run_state.append_assistant_payload(run_id, raw_text)
        unblock = human_unblock_request_from_envelope(envelope)
        if unblock is None:
            return False
        run = self.run_state.get_run(run_id)
        if run is not None and run.status == "blocked":
            return True
        details = unblock.instructions.strip() or "Human unblock required"
        summary = details.splitlines()[0].strip() or "Human unblock required"
        self.run_state.append_activity_event(
            run_id,
            stage="blocked",
            title="Needs Input",
            display_message=details,
            level="warning",
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="run.blocked", message=details),
        )
        self.run_state.set_run_status(run_id, "blocked", summary, pending_human_unblock=unblock)
        return True

    def _handle_codex_event(
        self,
        run_id: str,
        executor: AgentExecutorName,
        session_id: str,
        client_thread_id: str | None,
        linked_session_id: str | None,
        payload: dict[str, object],
    ) -> tuple[str | None, bool]:
        event_type = str(payload.get("type", "")).strip()
        if event_type == "thread.started":
            agent_session_id = str(payload.get("thread_id", "")).strip()
            if agent_session_id and client_thread_id:
                self.run_state.run_store.set_agent_session_id(
                    executor=executor,
                    session_id=session_id,
                    client_thread_id=client_thread_id,
                    agent_session_id=agent_session_id,
                )
                self.run_state.append_log_message(
                    run_id,
                    f"{executor} session linked ({agent_session_id})",
                    action_index=0,
                )
                return agent_session_id, False
        elif event_type == "item.completed":
            item = payload.get("item")
            if isinstance(item, dict):
                item_type = str(item.get("type", "")).strip()
                item_text = str(item.get("text", "")).strip()
                if item_type == "agent_message" and item_text:
                    return linked_session_id, self.append_assistant_payload(run_id, item_text)
        return linked_session_id, False

    def _handle_claude_event(
        self,
        run_id: str,
        executor: AgentExecutorName,
        session_id: str,
        client_thread_id: str | None,
        linked_session_id: str | None,
        payload: dict[str, object],
    ) -> tuple[str | None, bool]:
        agent_session_id = claude_session_id(payload)
        if agent_session_id and client_thread_id and agent_session_id != linked_session_id:
            self.run_state.run_store.set_agent_session_id(
                executor=executor,
                session_id=session_id,
                client_thread_id=client_thread_id,
                agent_session_id=agent_session_id,
            )
            linked_session_id = agent_session_id
            self.run_state.append_log_message(
                run_id,
                f"{executor} session linked ({agent_session_id})",
                action_index=0,
            )
        assistant_text = claude_assistant_text(payload)
        if assistant_text:
            return linked_session_id, self.append_assistant_payload(run_id, assistant_text)
        return linked_session_id, False
