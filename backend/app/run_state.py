from __future__ import annotations

from datetime import datetime
from datetime import timezone
import json
import threading
import time
from typing import Iterator
import uuid

from app.chat_envelope import coerce_assistant_text_to_envelope
from app.chat_envelope import parse_chat_envelope_payload
from app.models.schemas import AgendaItem
from app.models.schemas import ChatArtifact
from app.models.schemas import ChatEnvelope
from app.models.schemas import ChatSection
from app.models.schemas import ExecutionEvent
from app.models.schemas import RunDiagnostics
from app.models.schemas import RunRecord
from app.models.schemas import RunSummary
from app.storage import RunStore


class RunState:
    def __init__(self, run_store: RunStore, *, max_event_message_chars: int) -> None:
        self.run_store = run_store
        self.max_event_message_chars = max_event_message_chars
        self._runs_lock = threading.Lock()
        self._runs = self.run_store.load_all()
        self._cancelled: set[str] = set()

    def get_run(self, run_id: str) -> RunRecord | None:
        with self._runs_lock:
            return self._runs.get(run_id)

    def store_run(self, run: RunRecord) -> None:
        with self._runs_lock:
            self._runs[run.run_id] = run
        self.run_store.upsert_run(run)

    def append_event(self, run_id: str, event: ExecutionEvent) -> None:
        if not event.event_id:
            event.event_id = str(uuid.uuid4())
        if not event.created_at:
            event.created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        if len(event.message) > self.max_event_message_chars:
            event.message = event.message[: self.max_event_message_chars] + "\n...[truncated]"
        with self._runs_lock:
            run = self._runs.get(run_id)
            if run is None:
                return
            run.events.append(event)
            self.run_store.append_event(run_id, event)

    def append_chat_message(
        self,
        run_id: str,
        *,
        summary: str,
        sections: list[ChatSection] | None = None,
        agenda_items: list[AgendaItem] | None = None,
        artifacts: list[ChatArtifact] | None = None,
    ) -> None:
        envelope = ChatEnvelope(
            message_id=str(uuid.uuid4()),
            created_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            summary=summary,
            sections=sections or [],
            agenda_items=agenda_items or [],
            artifacts=artifacts or [],
        )
        self.append_event(
            run_id,
            ExecutionEvent(type="chat.message", message=envelope.model_dump_json()),
        )

    def append_assistant_payload(self, run_id: str, raw_text: str) -> ChatEnvelope:
        payload = parse_chat_envelope_payload(raw_text)
        if payload is not None:
            envelope = ChatEnvelope.model_validate(payload)
            self.append_event(
                run_id,
                ExecutionEvent(type="chat.message", message=json.dumps(payload)),
            )
            return envelope
        envelope = coerce_assistant_text_to_envelope(raw_text)
        self.append_event(
            run_id,
            ExecutionEvent(type="chat.message", message=envelope.model_dump_json()),
        )
        return envelope

    def append_log_message(self, run_id: str, message: str, *, action_index: int | None = 0) -> None:
        text = message.strip()
        if not text:
            return
        self.append_event(
            run_id,
            ExecutionEvent(type="log.message", action_index=action_index, message=text),
        )

    def set_run_status(self, run_id: str, status: str, summary: str) -> None:
        with self._runs_lock:
            run = self._runs.get(run_id)
            if run is None:
                return
            run.status = status
            run.summary = summary
            if status in {"completed", "failed", "rejected", "blocked", "cancelled"}:
                self._cancelled.discard(run_id)
            self.run_store.update_run_status(run_id, status, summary)

    def is_cancelled(self, run_id: str) -> bool:
        with self._runs_lock:
            return run_id in self._cancelled

    def request_cancel(self, run_id: str) -> RunRecord:
        with self._runs_lock:
            run = self._runs.get(run_id)
            if not run:
                raise KeyError("missing")
            if run.status in {"completed", "failed", "rejected", "blocked", "cancelled"}:
                raise ValueError(run.status)
            self._cancelled.add(run_id)
            return run

    def list_session_runs(self, session_id: str, *, limit: int = 20) -> list[RunSummary]:
        runs = self.run_store.list_runs_for_session(session_id, limit=limit)
        return [
            RunSummary(
                run_id=run.run_id,
                session_id=run.session_id,
                executor=run.executor,
                utterance_text=run.utterance_text,
                status=run.status,
                summary=run.summary,
                updated_at=run.updated_at,
                working_directory=run.working_directory,
            )
            for run in runs
        ]

    def diagnostics_for(self, run_id: str) -> RunDiagnostics | None:
        run = self.get_run(run_id)
        if run is None:
            return None
        counts: dict[str, int] = {}
        last_error: str | None = None
        has_stderr = False
        for event in run.events:
            counts[event.type] = counts.get(event.type, 0) + 1
            if event.type == "action.stderr":
                has_stderr = True
                last_error = event.message
            if event.type == "run.failed":
                last_error = event.message
        return RunDiagnostics(
            run_id=run.run_id,
            status=run.status,
            summary=run.summary,
            event_count=len(run.events),
            event_type_counts=counts,
            has_stderr=has_stderr,
            last_error=last_error,
            created_at=run.created_at,
            updated_at=run.updated_at,
        )

    def event_stream(self, run_id: str) -> Iterator[str]:
        sent_count = 0
        heartbeat_at = time.monotonic()
        while True:
            with self._runs_lock:
                run = self._runs.get(run_id)
                if run is None:
                    break
                pending_events = run.events[sent_count:]
                status = run.status

            for event in pending_events:
                sent_count += 1
                payload = json.dumps(event.model_dump())
                yield f"event: {event.type}\ndata: {payload}\n\n"

            done = status in {"completed", "failed", "rejected", "blocked", "cancelled"}
            if done and not pending_events:
                break

            now = time.monotonic()
            if now - heartbeat_at > 10:
                heartbeat_at = now
                yield ": keep-alive\n\n"
            time.sleep(0.25)
