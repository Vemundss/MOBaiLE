from __future__ import annotations

import threading
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from fastapi import HTTPException

from app.agent_runtime import is_calendar_request
from app.chat_attachments import display_utterance_text, render_utterance_for_executor
from app.models.schemas import (
    ActionPlan,
    AgentExecutorName,
    ExecutionEvent,
    ResponseProfile,
    RunExecutorName,
    RunRecord,
    SessionContextResponse,
    UtteranceRequest,
    UtteranceResponse,
)
from app.orchestrator.planner import plan_from_utterance
from app.policy.validator import validate_plan
from app.run_state import RunState
from app.runtime_environment import RuntimeEnvironment
from app.runtime_settings_catalog import (
    PROFILE_AGENTS_SETTING_ID,
    PROFILE_MEMORY_SETTING_ID,
)


class ExecutionRunner(Protocol):
    def run_calendar_adapter(self, run_id: str, prompt: str) -> None: ...

    def run_agent(
        self,
        run_id: str,
        prompt: str,
        workdir: Path,
        session_id: str,
        executor: AgentExecutorName,
        client_thread_id: str | None = None,
        response_profile: ResponseProfile = "guided",
        codex_model_override: str | None = None,
        codex_reasoning_effort_override: str | None = None,
        claude_model_override: str | None = None,
        include_profile_agents: bool = True,
        include_profile_memory: bool = True,
        guardrail_message: str | None = None,
    ) -> None: ...

    def run_local_plan(self, run_id: str, plan: ActionPlan, workdir: Path) -> None: ...


def _default_background_launcher(target: Callable[..., None], args: tuple[object, ...]) -> None:
    threading.Thread(target=target, args=args, daemon=True).start()


@dataclass(frozen=True)
class PreparedUtterance:
    run_id: str
    session_context: SessionContextResponse
    executor: RunExecutorName
    workdir: Path
    display_text: str
    effective_text: str


@dataclass(frozen=True)
class PrecreatedRun:
    run_id: str
    session_id: str


class UtteranceService:
    def __init__(
        self,
        *,
        environment: RuntimeEnvironment,
        run_state: RunState,
        execution_service: ExecutionRunner,
        session_context_loader: Callable[[str], SessionContextResponse],
        background_launcher: Callable[[Callable[..., None], tuple[object, ...]], None] = _default_background_launcher,
        run_id_factory: Callable[[], str] = lambda: str(uuid.uuid4()),
        plan_builder: Callable[[str], ActionPlan] = plan_from_utterance,
        plan_validator: Callable[[ActionPlan], tuple[bool, str]] = validate_plan,
        calendar_request_detector: Callable[[str], bool] = is_calendar_request,
    ) -> None:
        self.environment = environment
        self.run_state = run_state
        self.execution_service = execution_service
        self.session_context_loader = session_context_loader
        self.background_launcher = background_launcher
        self.run_id_factory = run_id_factory
        self.plan_builder = plan_builder
        self.plan_validator = plan_validator
        self.calendar_request_detector = calendar_request_detector

    def submit(self, request: UtteranceRequest) -> UtteranceResponse:
        prepared = self._prepare(request)
        return self._submit_prepared(prepared, request, precreated=False)

    def submit_precreated(self, request: UtteranceRequest, *, run_id: str) -> UtteranceResponse:
        prepared = self._prepare(request, run_id=run_id)
        return self._submit_prepared(prepared, request, precreated=True)

    def create_transcribing_run(self, request: UtteranceRequest, *, run_id: str) -> PrecreatedRun:
        if self.run_state.get_run(run_id) is not None:
            raise HTTPException(status_code=409, detail="run_id already exists")
        prepared = self._prepare(request, run_id=run_id)
        self.run_state.store_run(
            RunRecord(
                run_id=prepared.run_id,
                session_id=prepared.session_context.session_id,
                executor=prepared.executor,
                utterance_text=prepared.display_text,
                working_directory=str(prepared.workdir),
                status="running",
                events=[],
                summary="Transcribing audio",
            )
        )
        self.run_state.append_activity_event(
            prepared.run_id,
            stage="transcribing",
            title="Transcribing",
            display_message="Transcribing the audio message.",
            event_type="activity.started",
        )
        return PrecreatedRun(run_id=prepared.run_id, session_id=prepared.session_context.session_id)

    def _submit_prepared(
        self,
        prepared: PreparedUtterance,
        request: UtteranceRequest,
        *,
        precreated: bool,
    ) -> UtteranceResponse:
        if self.environment.is_agent_executor(prepared.executor):
            return self._submit_agent_request(prepared, request, precreated=precreated)
        return self._submit_local_request(prepared, precreated=precreated)

    def _prepare(self, request: UtteranceRequest, *, run_id: str | None = None) -> PreparedUtterance:
        session_context = self.session_context_loader(request.session_id)
        try:
            if request.executor is not None:
                executor = self.environment.resolve_request_executor(request.executor, explicit=True)
            else:
                executor = self.environment.resolve_request_executor(session_context.executor)
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        requested_working_directory = request.working_directory
        if requested_working_directory is None:
            requested_working_directory = session_context.working_directory
        try:
            workdir = self.environment.resolve_workdir(requested_working_directory)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return PreparedUtterance(
            run_id=run_id or self.run_id_factory(),
            session_context=session_context,
            executor=executor,
            workdir=workdir,
            display_text=display_utterance_text(request.utterance_text, request.attachments),
            effective_text=render_utterance_for_executor(request.utterance_text, request.attachments),
        )

    def _submit_agent_request(
        self,
        prepared: PreparedUtterance,
        request: UtteranceRequest,
        *,
        precreated: bool,
    ) -> UtteranceResponse:
        agent_executor = prepared.executor
        assert self.environment.is_agent_executor(agent_executor)
        include_profile_agents = self._profile_context_enabled(
            prepared.session_context,
            executor=agent_executor,
            setting_id=PROFILE_AGENTS_SETTING_ID,
        )
        include_profile_memory = self._profile_context_enabled(
            prepared.session_context,
            executor=agent_executor,
            setting_id=PROFILE_MEMORY_SETTING_ID,
        )

        if self.calendar_request_detector(prepared.effective_text):
            self._record_running_run(prepared, precreated=precreated)
            if not self._launch_background_run(
                prepared.run_id,
                self.execution_service.run_calendar_adapter,
                (prepared.run_id, prepared.effective_text),
                failure_summary="Calendar run failed to start",
            ):
                return self._rejected_response(prepared.run_id, "Calendar run failed to start")
            return self._accepted_response(prepared.run_id)

        guardrail_status, guardrail_message = self.environment.evaluate_runtime_guardrails(prepared.effective_text)
        if guardrail_status == "reject":
            self._record_rejected_run(
                prepared,
                summary=guardrail_message,
                message=guardrail_message,
                plan=None,
                precreated=precreated,
            )
            return self._rejected_response(prepared.run_id, guardrail_message)

        self._record_running_run(prepared, precreated=precreated)
        if not self._launch_background_run(
            prepared.run_id,
            self.execution_service.run_agent,
            (
                prepared.run_id,
                prepared.effective_text,
                prepared.workdir,
                request.session_id,
                agent_executor,
                request.thread_id,
                request.response_profile,
                self._codex_model_override(agent_executor, prepared.session_context),
                prepared.session_context.codex_reasoning_effort,
                prepared.session_context.claude_model,
                include_profile_agents,
                include_profile_memory,
                guardrail_message if guardrail_status == "warn" else None,
            ),
            failure_summary="Agent run failed to start",
        ):
            return self._rejected_response(prepared.run_id, "Agent run failed to start")
        return self._accepted_response(prepared.run_id)

    @staticmethod
    def _profile_context_enabled(
        context: SessionContextResponse,
        *,
        executor: AgentExecutorName,
        setting_id: str,
    ) -> bool:
        normalized_setting_id = setting_id.strip().lower()
        for item in context.runtime_settings:
            if item.executor != executor:
                continue
            if item.id.strip().lower() != normalized_setting_id:
                continue
            return (item.value or "").strip().lower() != "disabled"
        return True

    def _codex_model_override(
        self,
        executor: AgentExecutorName,
        context: SessionContextResponse,
    ) -> str | None:
        if executor != "codex":
            return None
        return context.codex_model or self.environment.codex_model_override or None

    def _submit_local_request(self, prepared: PreparedUtterance, *, precreated: bool) -> UtteranceResponse:
        plan = self.plan_builder(prepared.effective_text)
        allowed, message = self.plan_validator(plan)
        if not allowed:
            self._record_rejected_run(
                prepared,
                summary=f"Rejected by policy: {message}",
                message=message,
                plan=plan,
                precreated=precreated,
            )
            return self._rejected_response(prepared.run_id, message)

        self._record_running_run(prepared, plan=plan, precreated=precreated)
        if not self._launch_background_run(
            prepared.run_id,
            self.execution_service.run_local_plan,
            (prepared.run_id, plan, prepared.workdir),
            failure_summary="Local run failed to start",
        ):
            return self._rejected_response(prepared.run_id, "Local run failed to start")
        return self._accepted_response(prepared.run_id)

    def _launch_background_run(
        self,
        run_id: str,
        target: Callable[..., None],
        args: tuple[object, ...],
        *,
        failure_summary: str,
    ) -> bool:
        try:
            self.background_launcher(target, args)
        except Exception as exc:
            detail = f"{type(exc).__name__}: {exc}".strip()
            self.run_state.append_activity_event(
                run_id,
                stage="failed",
                title="Failed",
                display_message=failure_summary,
                level="error",
                event_type="activity.completed",
            )
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="action.stderr", action_index=0, message=f"{failure_summary}: {detail}"),
            )
            self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message=failure_summary))
            self.run_state.set_run_status(run_id, "failed", failure_summary)
            return False
        return True

    @staticmethod
    def _accepted_response(run_id: str) -> UtteranceResponse:
        return UtteranceResponse(run_id=run_id, status="accepted", message="Run started")

    @staticmethod
    def _rejected_response(run_id: str, message: str) -> UtteranceResponse:
        return UtteranceResponse(run_id=run_id, status="rejected", message=message)

    @staticmethod
    def _running_run_record(prepared: PreparedUtterance, *, plan: ActionPlan | None = None) -> RunRecord:
        return RunRecord(
            run_id=prepared.run_id,
            session_id=prepared.session_context.session_id,
            executor=prepared.executor,
            utterance_text=prepared.display_text,
            working_directory=str(prepared.workdir),
            status="running",
            plan=plan,
            events=[],
            summary="Run started",
        )

    def _record_running_run(
        self,
        prepared: PreparedUtterance,
        *,
        plan: ActionPlan | None = None,
        precreated: bool,
    ) -> None:
        if not precreated:
            self.run_state.store_run(self._running_run_record(prepared, plan=plan))
            return
        self.run_state.append_activity_event(
            prepared.run_id,
            stage="transcribing",
            title="Transcribed",
            display_message="Audio transcription complete.",
            event_type="activity.completed",
        )
        self.run_state.update_run_start_metadata(
            prepared.run_id,
            executor=prepared.executor,
            utterance_text=prepared.display_text,
            working_directory=str(prepared.workdir),
            plan=plan,
            summary="Run started",
        )

    def _record_rejected_run(
        self,
        prepared: PreparedUtterance,
        *,
        summary: str,
        message: str,
        plan: ActionPlan | None,
        precreated: bool,
    ) -> None:
        if not precreated:
            self.run_state.store_run(
                self._rejected_run_record(
                    prepared,
                    summary=summary,
                    message=message,
                    plan=plan,
                )
            )
            return
        self.run_state.update_run_start_metadata(
            prepared.run_id,
            executor=prepared.executor,
            utterance_text=prepared.display_text,
            working_directory=str(prepared.workdir),
            plan=plan,
            summary=summary,
        )
        self.run_state.append_event(prepared.run_id, ExecutionEvent(type="run.failed", message=message))
        self.run_state.set_run_status(prepared.run_id, "rejected", summary)

    @staticmethod
    def _rejected_run_record(
        prepared: PreparedUtterance,
        *,
        summary: str,
        message: str,
        plan: ActionPlan | None,
    ) -> RunRecord:
        return RunRecord(
            run_id=prepared.run_id,
            session_id=prepared.session_context.session_id,
            executor=prepared.executor,
            utterance_text=prepared.display_text,
            working_directory=str(prepared.workdir),
            status="rejected",
            plan=plan,
            events=[ExecutionEvent(type="run.failed", message=message)],
            summary=summary,
        )
