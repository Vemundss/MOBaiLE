from __future__ import annotations

import logging
import shlex
from datetime import datetime
from pathlib import Path
from typing import Callable

from app.agent_run_service import AgentRunService
from app.executors.shell_executor import ShellExecutor
from app.models.schemas import (
    ActionResult,
    AgendaItem,
    AgentExecutorName,
    ChatSection,
    ChatShellResult,
    ChatWarning,
    ExecutionEvent,
    ResponseProfile,
)
from app.profile_store import ProfileStore
from app.run_state import RunState
from app.runtime_environment import RuntimeEnvironment
from app.shell_command_policy import persistent_cd_target

LOGGER = logging.getLogger(__name__)
TERMINAL_RUN_STATUSES = {"completed", "failed", "rejected", "blocked", "cancelled"}


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

    def run_shell_command(
        self,
        run_id: str,
        command: str,
        workdir: Path,
        guardrail_message: str | None = None,
    ) -> None:
        try:
            self._run_shell_command(run_id, command, workdir, guardrail_message=guardrail_message)
        except Exception as exc:
            self._record_worker_exception(run_id, summary="Shell run crashed", exc=exc)

    def _run_shell_command(
        self,
        run_id: str,
        command: str,
        workdir: Path,
        *,
        guardrail_message: str | None,
    ) -> None:
        if guardrail_message and self.environment.security_mode == "safe":
            self.run_state.append_activity_event(
                run_id,
                stage="failed",
                title="Rejected",
                display_message="Shell command rejected by safe mode.",
                level="error",
                event_type="activity.completed",
            )
            self.run_state.append_chat_message(
                run_id,
                summary="Shell command rejected by safe mode.",
                sections=[ChatSection(title="Safety", body=guardrail_message)],
                warnings=[ChatWarning(message=guardrail_message, level="error")],
            )
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="run.failed", message="Shell command rejected by safe mode"),
            )
            self.run_state.set_run_status(run_id, "rejected", "Shell command rejected by safe mode")
            return

        executor = ShellExecutor(
            workdir,
            shell_binary=self.environment.shell_binary,
            is_cancelled=lambda: self.run_state.is_cancelled(run_id),
        )
        self.run_state.append_activity_event(
            run_id,
            stage="planning",
            title="Planning",
            display_message="Preparing to run the shell command.",
            event_type="activity.started",
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.started", action_index=0, message=f"starting shell command: {command}"),
        )
        self.run_state.append_activity_event(
            run_id,
            stage="executing",
            title="Executing",
            display_message="Running the shell command.",
        )
        result = executor.execute(command, timeout_sec=self.environment.shell_timeout_sec)
        if result.stdout:
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="action.stdout", action_index=0, message=result.stdout.strip()),
            )
        if result.stderr:
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="action.stderr", action_index=0, message=result.stderr.strip()),
            )
        run = self.run_state.get_run(run_id)
        if run is not None and run.status == "cancelled":
            return
        if self.run_state.is_cancelled(run_id) or result.details == "command cancelled":
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="run.cancelled", message="Run cancelled by user"),
            )
            self.run_state.set_run_status(run_id, "cancelled", "Run cancelled by user")
            return

        success = result.success
        shell_summary = self._shell_result_summary(command, result, workdir=workdir)
        summary = shell_summary if success and shell_summary.startswith("Working directory changed to ") else (
            "Command completed successfully" if success else shell_summary
        )
        status = "passed" if success else "failed"
        output = self._shell_result_body(result.stdout, result.stderr)
        sections = [ChatSection(title="Command", body=f"`{command}`")]
        if output:
            sections.append(ChatSection(title="Output", body=output))
        elif shell_summary:
            sections.append(ChatSection(title="Output", body=shell_summary))
        warnings = [ChatWarning(message=guardrail_message, level="warning")] if guardrail_message else []
        self.run_state.append_chat_message(
            run_id,
            summary=summary,
            sections=sections,
            shell_results=[
                ChatShellResult(
                    command=command,
                    status=status,
                    exit_code=result.exit_code,
                    stdout=result.stdout,
                    stderr=result.stderr,
                    summary=shell_summary,
                )
            ],
            warnings=warnings,
        )
        done_message = result.details
        if result.exit_code is not None:
            done_message = f"{done_message} (exit={result.exit_code})"
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.completed", action_index=0, message=done_message),
        )
        self.run_state.append_activity_event(
            run_id,
            stage="summarizing",
            title="Summarizing",
            display_message="Preparing the shell command result.",
            event_type="activity.completed",
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="run.completed" if success else "run.failed", message=summary),
        )
        self.run_state.set_run_status(run_id, "completed" if success else "failed", summary)

    @staticmethod
    def _shell_result_body(stdout: str, stderr: str) -> str:
        parts: list[str] = []
        if stdout.strip():
            parts.append(f"stdout:\n```text\n{stdout.strip()}\n```")
        if stderr.strip():
            parts.append(f"stderr:\n```text\n{stderr.strip()}\n```")
        return "\n\n".join(parts)

    @staticmethod
    def _shell_result_summary(command: str, result: ActionResult, workdir: Path | None = None) -> str:
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        if result.success:
            if workdir is not None:
                cd_target = persistent_cd_target(command, workdir)
                if cd_target is not None:
                    return f"Working directory changed to {cd_target}."
            return result.details if stdout or stderr else "No output."
        if result.exit_code is None:
            return result.details or "Command did not start."
        command_not_found = ExecutionService._shell_command_not_found_summary(command, stderr, result.exit_code)
        if command_not_found:
            return command_not_found
        if not stdout and not stderr:
            if ExecutionService._is_ripgrep_no_matches(command, result.exit_code):
                return "No matches."
            return f"No output (exit {result.exit_code})."
        return f"Exited with code {result.exit_code}."

    @staticmethod
    def _shell_command_not_found_summary(command: str, stderr: str, exit_code: int | None) -> str | None:
        if exit_code != 127:
            return None
        missing_command = ExecutionService._missing_shell_command_name(command, stderr)
        if missing_command:
            return (
                f"Command not found: {missing_command}. "
                "Shell mode runs host commands; switch to an agent executor for natural-language tasks."
            )
        return "Command not found. Shell mode runs host commands; switch to an agent executor for natural-language tasks."

    @staticmethod
    def _missing_shell_command_name(command: str, stderr: str) -> str | None:
        for line in stderr.splitlines():
            lower = line.lower()
            marker = "command not found:"
            if marker in lower:
                candidate = line[lower.index(marker) + len(marker):].strip()
                if candidate:
                    return candidate
            suffix = ": command not found"
            if lower.endswith(suffix):
                candidate = line[: -len(suffix)].rsplit(":", maxsplit=1)[-1].strip()
                if candidate:
                    return candidate
        try:
            tokens = shlex.split(command)
        except ValueError:
            tokens = command.split()
        return tokens[0] if tokens else None

    @staticmethod
    def _is_ripgrep_no_matches(command: str, exit_code: int) -> bool:
        if exit_code != 1:
            return False
        try:
            tokens = shlex.split(command)
        except ValueError:
            return False
        if not tokens:
            return False
        return Path(tokens[0]).name in {"rg", "ripgrep"}

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
        try:
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
        except Exception as exc:
            self._record_worker_exception(run_id, summary="Agent worker crashed", exc=exc)

    def _record_worker_exception(self, run_id: str, *, summary: str, exc: Exception) -> None:
        LOGGER.exception("%s for run %s", summary, run_id)
        run = self.run_state.get_run(run_id)
        if run is not None and run.status in TERMINAL_RUN_STATUSES:
            return
        detail = f"{type(exc).__name__}: {exc}".strip()
        self.run_state.append_activity_event(
            run_id,
            stage="failed",
            title="Failed",
            display_message=summary,
            level="error",
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.stderr", action_index=0, message=f"{summary}: {detail}"),
        )
        self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message=summary))
        self.run_state.set_run_status(run_id, "failed", summary)
