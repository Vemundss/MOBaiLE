from __future__ import annotations

import json
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Iterator, Literal

from app.chat_envelope import (
    chat_envelope_transport_json,
    coerce_assistant_text_to_envelope,
    concise_chat_summary,
    enhance_chat_envelope,
    infer_chat_message_kind,
    parse_chat_envelope_payload,
)
from app.models.schemas import (
    ActionPlan,
    AgendaItem,
    ChatArtifact,
    ChatCommandRun,
    ChatEnvelope,
    ChatFileChange,
    ChatNextAction,
    ChatSection,
    ChatTestRun,
    ChatWarning,
    ExecutionEvent,
    HumanUnblockRequest,
    RunDiagnostics,
    RunEventsPage,
    RunExecutorName,
    RunRecord,
    RunSummary,
)
from app.storage import RunStore


class RunState:
    TERMINAL_STATUSES = {"completed", "failed", "rejected", "blocked", "cancelled"}

    def __init__(self, run_store: RunStore, *, max_event_message_chars: int) -> None:
        self.run_store = run_store
        self.max_event_message_chars = max_event_message_chars
        self._runs_lock = threading.Lock()
        self._runs: dict[str, RunRecord] = {}
        self._cancelled: set[str] = set()

    def get_run(self, run_id: str) -> RunRecord | None:
        with self._runs_lock:
            cached = self._runs.get(run_id)
        if cached is not None:
            return cached
        loaded = self.run_store.load_run(run_id)
        if loaded is None:
            return None
        with self._runs_lock:
            existing = self._runs.get(run_id)
            if existing is not None:
                return existing
            self._runs[run_id] = loaded
            return loaded

    def reconcile_interrupted_runs(self) -> None:
        for run in self.run_store.load_all().values():
            if run.status in self.TERMINAL_STATUSES:
                continue
            with self._runs_lock:
                self._runs[run.run_id] = run
            message = "Backend restarted before this run finished."
            self.append_activity_event(
                run.run_id,
                stage="failed",
                title="Interrupted",
                display_message=message,
                level="error",
                event_type="activity.completed",
            )
            self.append_event(run.run_id, ExecutionEvent(type="run.failed", message=message))
            self.set_run_status(run.run_id, "failed", message)

    def store_run(self, run: RunRecord) -> None:
        initial_events = list(run.events)
        run.events = []
        with self._runs_lock:
            self._runs[run.run_id] = run
        self.run_store.upsert_run(run)
        self.run_store.update_session_latest_run(
            run.session_id,
            run_id=run.run_id,
            status=run.status,
            summary=run.summary,
            pending_human_unblock=run.pending_human_unblock,
        )
        for event in initial_events:
            self.append_event(run.run_id, event)

    def update_run_start_metadata(
        self,
        run_id: str,
        *,
        executor: RunExecutorName,
        utterance_text: str,
        working_directory: str | None,
        summary: str,
        plan: ActionPlan | None = None,
    ) -> None:
        with self._runs_lock:
            run = self._runs.get(run_id)
            if run is None:
                return
            run.executor = executor
            run.utterance_text = utterance_text
            run.working_directory = working_directory
            run.summary = summary
            run.plan = plan
            self.run_store.upsert_run(run)
            self.run_store.update_session_latest_run(
                run.session_id,
                run_id=run.run_id,
                status=run.status,
                summary=run.summary,
                pending_human_unblock=run.pending_human_unblock,
            )

    def append_event(self, run_id: str, event: ExecutionEvent) -> None:
        if not event.event_id:
            event.event_id = str(uuid.uuid4())
        if not event.created_at:
            event.created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        if len(event.message) > self.max_event_message_chars:
            event.message = self._truncate_event_message(event)
        with self._runs_lock:
            run = self._runs.get(run_id)
            if run is None:
                return
            if event.seq is None:
                if run.events:
                    last_seq = run.events[-1].seq
                    event.seq = (last_seq + 1) if last_seq is not None else len(run.events)
                else:
                    event.seq = 0
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
        message_kind: Literal["progress", "final", "notice"] = "final",
        file_changes: list[ChatFileChange] | None = None,
        commands_run: list[ChatCommandRun] | None = None,
        tests_run: list[ChatTestRun] | None = None,
        warnings: list[ChatWarning] | None = None,
        next_actions: list[ChatNextAction] | None = None,
    ) -> None:
        envelope = ChatEnvelope(
            message_id=str(uuid.uuid4()),
            created_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            message_kind=message_kind,
            summary=summary,
            sections=sections or [],
            agenda_items=agenda_items or [],
            artifacts=artifacts or [],
            file_changes=file_changes or [],
            commands_run=commands_run or [],
            tests_run=tests_run or [],
            warnings=warnings or [],
            next_actions=next_actions or [],
        )
        envelope = enhance_chat_envelope(envelope, infer_message_kind=False)
        self.append_event(
            run_id,
            ExecutionEvent(
                type="chat.message",
                message=chat_envelope_transport_json(envelope, self.max_event_message_chars),
            ),
        )

    def append_assistant_payload(self, run_id: str, raw_text: str) -> ChatEnvelope:
        payload = parse_chat_envelope_payload(raw_text)
        if payload is not None:
            has_explicit_message_kind = "message_kind" in payload
            envelope = ChatEnvelope.model_validate(payload)
            envelope = enhance_chat_envelope(envelope, infer_message_kind=not has_explicit_message_kind)
            if not has_explicit_message_kind:
                envelope = envelope.model_copy(update={"message_kind": infer_chat_message_kind(envelope)})
            self.append_event(
                run_id,
                ExecutionEvent(
                    type="chat.message",
                    message=chat_envelope_transport_json(envelope, self.max_event_message_chars),
                ),
            )
            return envelope
        envelope = coerce_assistant_text_to_envelope(raw_text)
        self.append_event(
            run_id,
            ExecutionEvent(
                type="chat.message",
                message=chat_envelope_transport_json(envelope, self.max_event_message_chars),
            ),
        )
        return envelope

    def latest_chat_summary(self, run_id: str) -> str | None:
        run = self.get_run(run_id)
        if run is None:
            return None
        for event in reversed(run.events):
            if event.type != "chat.message":
                continue
            payload = parse_chat_envelope_payload(event.message)
            if payload is None:
                continue
            envelope = ChatEnvelope.model_validate(payload)
            summary = concise_chat_summary(envelope)
            if summary is not None:
                return summary
        return None

    def append_log_message(self, run_id: str, message: str, *, action_index: int | None = 0) -> None:
        text = message.strip()
        if not text:
            return
        self.append_event(
            run_id,
            ExecutionEvent(type="log.message", action_index=action_index, message=text),
        )

    def append_activity_event(
        self,
        run_id: str,
        *,
        stage: str,
        title: str,
        display_message: str,
        level: Literal["info", "warning", "error"] = "info",
        event_type: Literal["activity.started", "activity.updated", "activity.completed"] = "activity.updated",
    ) -> None:
        self.append_event(
            run_id,
            ExecutionEvent(
                type=event_type,
                message=display_message,
                stage=stage,
                title=title,
                display_message=display_message,
                level=level,
            ),
        )

    def _truncate_event_message(self, event: ExecutionEvent) -> str:
        if event.type == "chat.message":
            payload = parse_chat_envelope_payload(event.message)
            if payload is not None:
                envelope = ChatEnvelope.model_validate(payload)
                rendered = chat_envelope_transport_json(envelope, self.max_event_message_chars)
                if len(rendered) <= self.max_event_message_chars:
                    return rendered
        return event.message[: self.max_event_message_chars] + "\n...[truncated]"

    def set_run_status(
        self,
        run_id: str,
        status: str,
        summary: str,
        *,
        pending_human_unblock: HumanUnblockRequest | None = None,
    ) -> None:
        with self._runs_lock:
            run = self._runs.get(run_id)
            if run is None:
                return
            effective_pending_human_unblock = pending_human_unblock
            if status == "blocked" and effective_pending_human_unblock is None:
                effective_pending_human_unblock = run.pending_human_unblock
            run.status = status
            run.summary = summary
            run.pending_human_unblock = effective_pending_human_unblock
            if status in self.TERMINAL_STATUSES:
                self._cancelled.discard(run_id)
            self.run_store.update_run_status(
                run_id,
                status,
                summary,
                pending_human_unblock=effective_pending_human_unblock,
            )
            self.run_store.update_session_latest_run(
                run.session_id,
                run_id=run.run_id,
                status=status,
                summary=summary,
                pending_human_unblock=effective_pending_human_unblock,
            )

    def is_cancelled(self, run_id: str) -> bool:
        with self._runs_lock:
            return run_id in self._cancelled

    def request_cancel(self, run_id: str) -> RunRecord:
        run = self.get_run(run_id)
        if run is None:
            raise KeyError("missing")
        with self._runs_lock:
            run = self._runs.get(run_id)
            if run is None:
                raise KeyError("missing")
            if run.status in self.TERMINAL_STATUSES:
                raise ValueError(run.status)
            self._cancelled.add(run_id)
            return run

    def list_session_runs(self, session_id: str, *, limit: int = 20) -> list[RunSummary]:
        return self.run_store.list_run_summaries_for_session(session_id, limit=limit)

    def diagnostics_for(self, run_id: str) -> RunDiagnostics | None:
        run = self.get_run(run_id)
        if run is None:
            return None
        counts: dict[str, int] = {}
        activity_stage_counts: dict[str, int] = {}
        latest_activity: str | None = None
        last_error: str | None = None
        has_stderr = False
        for event in run.events:
            counts[event.type] = counts.get(event.type, 0) + 1
            if event.stage:
                activity_stage_counts[event.stage] = activity_stage_counts.get(event.stage, 0) + 1
                latest_activity = event.display_message or event.message
            if (event.level or "").lower() == "error":
                last_error = event.display_message or event.message
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
            activity_stage_counts=activity_stage_counts,
            latest_activity=latest_activity,
            has_stderr=has_stderr,
            last_error=last_error,
            created_at=run.created_at,
            updated_at=run.updated_at,
        )

    def event_page(
        self,
        run_id: str,
        *,
        limit: int,
        before_seq: int | None = None,
        after_seq: int | None = None,
    ) -> RunEventsPage | None:
        if before_seq is not None and after_seq is not None:
            raise ValueError("before_seq and after_seq cannot both be set")
        with self._runs_lock:
            run = self._runs.get(run_id)
            if run is not None:
                return self._build_event_page(
                    run_id,
                    run.events,
                    limit=limit,
                    before_seq=before_seq,
                    after_seq=after_seq,
                )
        return self.run_store.event_page(run_id, limit=limit, before_seq=before_seq, after_seq=after_seq)

    def _build_event_page(
        self,
        run_id: str,
        all_events: list[ExecutionEvent],
        *,
        limit: int,
        before_seq: int | None,
        after_seq: int | None,
    ) -> RunEventsPage:
        if after_seq is not None:
            candidates = [event for event in all_events if self._event_seq(event) > after_seq]
            events = candidates[:limit]
        elif before_seq is not None:
            candidates = [event for event in all_events if self._event_seq(event) < before_seq]
            events = candidates[-limit:]
        else:
            events = all_events[-limit:]
        first_seq = self._first_event_seq(events)
        last_seq = self._last_event_seq(events)
        min_seq = self._first_event_seq(all_events)
        max_seq = self._last_event_seq(all_events)
        return RunEventsPage(
            run_id=run_id,
            events=events,
            limit=limit,
            total_count=len(all_events),
            has_more_before=first_seq is not None and min_seq is not None and first_seq > min_seq,
            has_more_after=last_seq is not None and max_seq is not None and last_seq < max_seq,
            next_before_seq=first_seq,
            next_after_seq=last_seq,
        )

    def event_stream(self, run_id: str, *, after_seq: int = -1) -> Iterator[str]:
        if self.get_run(run_id) is None:
            return
        cursor_seq = after_seq
        heartbeat_at = time.monotonic()
        while True:
            with self._runs_lock:
                run = self._runs.get(run_id)
                if run is None:
                    break
                pending_events = [event for event in run.events if self._event_seq(event) > cursor_seq]
                status = run.status

            for event in pending_events:
                cursor_seq = self._event_seq(event)
                payload = json.dumps(event.model_dump())
                yield f"id: {cursor_seq}\nevent: {event.type}\ndata: {payload}\n\n"

            done = status in self.TERMINAL_STATUSES
            if done and not pending_events:
                break

            now = time.monotonic()
            if now - heartbeat_at > 10:
                heartbeat_at = now
                yield ": keep-alive\n\n"
            time.sleep(0.25)

    @staticmethod
    def _event_seq(event: ExecutionEvent) -> int:
        return event.seq if event.seq is not None else -1

    @staticmethod
    def _first_event_seq(events: list[ExecutionEvent]) -> int | None:
        if not events:
            return None
        return RunState._event_seq(events[0])

    @staticmethod
    def _last_event_seq(events: list[ExecutionEvent]) -> int | None:
        if not events:
            return None
        return RunState._event_seq(events[-1])
