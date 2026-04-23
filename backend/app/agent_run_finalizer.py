from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from app.models.schemas import AgentExecutorName, ExecutionEvent
from app.profile_store import ProfileStore
from app.run_state import RunState


@dataclass
class AgentRunOutcome:
    exit_code: int
    cancelled: bool = False
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
            summary = "Run cancelled by user"
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
            self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message=summary))
            self.run_state.set_run_status(run_id, "failed", summary)
            self.profile_store.sync_memory_from_workdir(workdir_memory_path)
            return

        success = outcome.exit_code == 0
        summary = "Run completed successfully" if success else "Run failed"
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="run.completed" if success else "run.failed", message=summary),
        )
        self.run_state.set_run_status(run_id, "completed" if success else "failed", summary)
        self.profile_store.sync_memory_from_workdir(workdir_memory_path)
