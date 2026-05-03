from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from app.models.schemas import (
    AgentExecutorName,
    ChatNextAction,
    ChatSection,
    ChatWarning,
    ExecutionEvent,
)
from app.profile_store import ProfileStore
from app.run_state import RunState


@dataclass
class AgentRunOutcome:
    exit_code: int
    cancelled: bool = False
    cancel_reason: str | None = None
    timed_out: bool = False
    blocked: bool = False
    resume_failure_reason: str | None = None


class AgentRunFinalizer:
    def __init__(
        self,
        *,
        run_state: RunState,
        profile_store: ProfileStore,
        timeout_resolver: Callable[[AgentExecutorName], int],
    ) -> None:
        self.run_state = run_state
        self.profile_store = profile_store
        self.timeout_resolver = timeout_resolver

    def record_missing_binary(
        self,
        run_id: str,
        *,
        executor: AgentExecutorName,
        workdir_memory_path: Path | None,
    ) -> None:
        summary = f"{executor} is not installed or is not available to the MOBaiLE backend."
        self.run_state.append_chat_message(
            run_id,
            summary=summary,
            sections=[
                ChatSection(
                    title="Recovery",
                    body=(
                        f"MOBaiLE could not start `{executor}` on the paired host. "
                        "Install the executor, fix the backend PATH, or switch to another executor before retrying."
                    ),
                )
            ],
            warnings=[ChatWarning(message=summary, level="error")],
            next_actions=[
                ChatNextAction(
                    title="Fix executor availability",
                    detail=f"Install `{executor}` or update the backend service environment so it can find the binary.",
                    kind="custom",
                ),
                ChatNextAction(
                    title="Open Run Logs",
                    detail="The logs include the failed executor startup event.",
                    kind="open_logs",
                ),
            ],
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.stderr", action_index=0, message=f"{executor} binary not found"),
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.completed", action_index=0, message=f"{executor} exec failed"),
        )
        self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message="Run failed"))
        self.run_state.set_run_status(run_id, "failed", "Run failed")
        self.profile_store.sync_memory_from_workdir(workdir_memory_path)

    def finalize_run(
        self,
        run_id: str,
        *,
        executor: AgentExecutorName,
        outcome: AgentRunOutcome,
        workdir_memory_path: Path | None,
        action_index: int = 0,
    ) -> None:
        if not outcome.blocked:
            self.run_state.append_event(
                run_id,
                ExecutionEvent(
                    type="action.completed",
                    action_index=action_index,
                    message=f"{executor} exec finished (exit={outcome.exit_code})",
                ),
            )

        if outcome.cancelled:
            summary = self._cancelled_summary(outcome.cancel_reason)
            self.run_state.append_event(run_id, ExecutionEvent(type="run.cancelled", message=summary))
            self.run_state.set_run_status(run_id, "cancelled", summary)
            self.profile_store.sync_memory_from_workdir(workdir_memory_path)
            return
        if outcome.blocked:
            current = self.run_state.get_run(run_id)
            summary = current.summary if current is not None else "Human unblock required"
            self.run_state.append_event(
                run_id,
                ExecutionEvent(
                    type="action.completed",
                    action_index=action_index,
                    message=f"{executor} exec blocked awaiting user input",
                ),
            )
            self.run_state.set_run_status(run_id, "blocked", summary)
            self.profile_store.sync_memory_from_workdir(workdir_memory_path)
            return
        if outcome.timed_out:
            summary = f"Run timed out after {self.timeout_resolver(executor)}s"
            self.run_state.append_chat_message(
                run_id,
                summary=summary,
                sections=[
                    ChatSection(
                        title="Recovery",
                        body=(
                            "The agent was still running when MOBaiLE stopped waiting. "
                            "Review the logs, then retry with a narrower request or adjust the executor timeout."
                        ),
                    )
                ],
                warnings=[ChatWarning(message=summary, level="error")],
                next_actions=[
                    ChatNextAction(
                        title="Open Run Logs",
                        detail="Check the last command or agent message before the timeout.",
                        kind="open_logs",
                    ),
                    ChatNextAction(
                        title="Retry with a narrower prompt",
                        detail="Ask for a smaller slice of the work or increase the backend timeout before retrying.",
                        kind="retry",
                    ),
                ],
            )
            self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message=summary))
            self.run_state.set_run_status(run_id, "failed", summary)
            self.profile_store.sync_memory_from_workdir(workdir_memory_path)
            return

        success = outcome.exit_code == 0
        default_summary = "Run completed successfully" if success else "Run failed"
        latest_summary = self.run_state.latest_chat_summary(run_id)
        if not success and latest_summary is None:
            self.run_state.append_chat_message(
                run_id,
                summary="The agent exited before sending a final result.",
                sections=[
                    ChatSection(
                        title="Recovery",
                        body=(
                            f"`{executor}` exited with code {outcome.exit_code}. "
                            "Open Run Logs to inspect the last command or error, then retry once the cause is clear."
                        ),
                    )
                ],
                warnings=[
                    ChatWarning(
                        message=f"{executor} exited with code {outcome.exit_code}.",
                        level="error",
                    )
                ],
                next_actions=[
                    ChatNextAction(
                        title="Open Run Logs",
                        detail="The diagnostic stream includes stdout, stderr, and executor lifecycle events.",
                        kind="open_logs",
                    ),
                    ChatNextAction(
                        title="Retry after fixing the error",
                        detail="Use the log details to narrow the prompt or fix the failing command before retrying.",
                        kind="retry",
                    ),
                ],
            )
            latest_summary = self.run_state.latest_chat_summary(run_id)
        summary = latest_summary or default_summary
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="run.completed" if success else "run.failed", message=default_summary),
        )
        self.run_state.set_run_status(run_id, "completed" if success else "failed", summary)
        self.profile_store.sync_memory_from_workdir(workdir_memory_path)

    @staticmethod
    def _cancelled_summary(reason: str | None) -> str:
        if reason == "superseded":
            return "Run stopped because a newer prompt started"
        return "Run cancelled by user"
