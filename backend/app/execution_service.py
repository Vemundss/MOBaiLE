from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Callable

from app.agent_run_service import AgentRunService
from app.executors.local_executor import LocalExecutor
from app.models.schemas import (
    ActionPlan,
    AgendaItem,
    AgentExecutorName,
    ChatSection,
    ExecutionEvent,
    ResponseProfile,
)
from app.profile_store import ProfileStore
from app.run_state import RunState
from app.runtime_environment import RuntimeEnvironment


class ExecutionService:
    def __init__(
        self,
        *,
        environment: RuntimeEnvironment,
        run_state: RunState,
        profile_store: ProfileStore,
        fetch_calendar_events: Callable[[], list[AgendaItem]],
    ) -> None:
        self.environment = environment
        self.run_state = run_state
        self.profile_store = profile_store
        self.fetch_calendar_events = fetch_calendar_events
        self.agent_run_service = AgentRunService(
            environment=environment,
            run_state=run_state,
            profile_store=profile_store,
        )

    def terminate_active_process(self, run_id: str) -> None:
        self.agent_run_service.terminate_active_process(run_id)

    def run_calendar_adapter(self, run_id: str, prompt: str) -> None:
        self.run_state.append_activity_event(
            run_id,
            stage="planning",
            title="Planning",
            display_message="Reviewing your calendar request and planning the response.",
            event_type="activity.started",
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.started", action_index=0, message="starting calendar adapter"),
        )
        self.run_state.append_activity_event(
            run_id,
            stage="executing",
            title="Executing",
            display_message="Checking your calendar and collecting events.",
        )
        self.run_state.append_chat_message(
            run_id,
            summary="Checking your calendar for today.",
            sections=[ChatSection(title="What I Did", body="Queried your local macOS Calendar for today's events.")],
        )
        try:
            events = self.fetch_calendar_events()
        except Exception as exc:
            self.run_state.append_activity_event(
                run_id,
                stage="executing",
                title="Failed",
                display_message="Calendar query failed.",
                level="error",
            )
            self.run_state.append_log_message(run_id, f"Calendar adapter failed: {exc}")
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="action.completed", action_index=0, message="calendar adapter failed"),
            )
            self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message="Run failed"))
            self.run_state.set_run_status(run_id, "failed", "Calendar query failed")
            return

        self.run_state.append_activity_event(
            run_id,
            stage="summarizing",
            title="Summarizing",
            display_message="Preparing the calendar result.",
            event_type="activity.completed",
        )
        today = datetime.now().strftime("%A, %B %d, %Y")
        if events:
            self.run_state.append_chat_message(
                run_id,
                summary=f"{len(events)} event(s) found for {today}.",
                sections=[ChatSection(title="Result", body=f"Showing your agenda for {today}.")],
                agenda_items=events,
            )
        else:
            self.run_state.append_chat_message(
                run_id,
                summary=f"No events found for {today}.",
                sections=[ChatSection(title="Result", body="Your calendar appears free today.")],
            )

        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.completed", action_index=0, message="calendar adapter completed"),
        )
        self.run_state.append_event(run_id, ExecutionEvent(type="run.completed", message="Run completed successfully"))
        self.run_state.set_run_status(run_id, "completed", "Run completed successfully")

    def run_local_plan(self, run_id: str, plan: ActionPlan, workdir: Path) -> None:
        executor = LocalExecutor(workdir)
        self.run_state.append_activity_event(
            run_id,
            stage="planning",
            title="Planning",
            display_message="Reviewing the local plan and preparing to execute it.",
            event_type="activity.started",
        )
        success = self._execute_plan(run_id, plan, executor)
        run = self.run_state.get_run(run_id)
        if run is not None and run.status == "cancelled":
            return
        summary = "Run completed successfully" if success else "Run failed"
        self.run_state.append_activity_event(
            run_id,
            stage="summarizing",
            title="Summarizing",
            display_message="Preparing the final result.",
            event_type="activity.completed",
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="run.completed" if success else "run.failed", message=summary),
        )
        self.run_state.set_run_status(run_id, "completed" if success else "failed", summary)

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
    ) -> None:
        self.agent_run_service.run(
            run_id,
            prompt,
            workdir=workdir,
            session_id=session_id,
            executor=executor,
            client_thread_id=client_thread_id,
            response_profile=response_profile,
            codex_model_override=codex_model_override,
            codex_reasoning_effort_override=codex_reasoning_effort_override,
            claude_model_override=claude_model_override,
            include_profile_agents=include_profile_agents,
            include_profile_memory=include_profile_memory,
            guardrail_message=guardrail_message,
        )

    def _execute_plan(self, run_id: str, plan: ActionPlan, executor: LocalExecutor) -> bool:
        self.run_state.append_activity_event(
            run_id,
            stage="executing",
            title="Executing",
            display_message="Running the requested local commands.",
        )
        for idx, action in enumerate(plan.actions):
            if self.run_state.is_cancelled(run_id):
                self.run_state.append_event(
                    run_id,
                    ExecutionEvent(type="run.cancelled", message="Run cancelled by user"),
                )
                self.run_state.set_run_status(run_id, "cancelled", "Run cancelled by user")
                return False
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="action.started", action_index=idx, message=f"starting {action.type}"),
            )
            result = executor.execute(action)
            if result.stdout:
                self.run_state.append_event(
                    run_id,
                    ExecutionEvent(type="action.stdout", action_index=idx, message=result.stdout.strip()),
                )
            if result.stderr:
                self.run_state.append_event(
                    run_id,
                    ExecutionEvent(type="action.stderr", action_index=idx, message=result.stderr.strip()),
                )
            done_message = result.details
            if result.exit_code is not None:
                done_message = f"{done_message} (exit={result.exit_code})"
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="action.completed", action_index=idx, message=done_message),
            )
            if not result.success:
                return False
        return True
