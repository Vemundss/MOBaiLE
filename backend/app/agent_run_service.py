from __future__ import annotations

import subprocess
import threading
from pathlib import Path
from typing import Callable

from app.agent_process_monitor import AgentProcessMonitor
from app.agent_run_finalizer import AgentRunFinalizer, AgentRunOutcome
from app.agent_stream_handler import AgentStreamHandler
from app.executors.claude_executor import ClaudeExecutor
from app.executors.codex_executor import CodexExecutor
from app.models.schemas import (
    AgentExecutorName,
    ChatSection,
    ExecutionEvent,
    ResponseProfile,
)
from app.profile_store import ProfileStore
from app.run_state import RunState
from app.runtime_environment import RuntimeEnvironment


class AgentRunService:
    def __init__(
        self,
        *,
        environment: RuntimeEnvironment,
        run_state: RunState,
        profile_store: ProfileStore,
    ) -> None:
        self.environment = environment
        self.run_state = run_state
        self.profile_store = profile_store
        self._active_procs_lock = threading.Lock()
        self._active_procs: dict[str, subprocess.Popen[str]] = {}
        self._stream_handler = AgentStreamHandler(run_state=run_state)
        self._finalizer = AgentRunFinalizer(
            run_state=run_state,
            profile_store=profile_store,
            timeout_resolver=self._agent_timeout_sec,
        )
        self._process_monitor = AgentProcessMonitor(
            run_state=run_state,
            stream_handler=self._stream_handler,
            timeout_resolver=self._agent_timeout_sec,
            leak_marker_provider=self.environment.runtime_context_leak_markers,
        )

    def terminate_active_process(self, run_id: str) -> None:
        with self._active_procs_lock:
            proc = self._active_procs.get(run_id)
            if proc is not None and proc.poll() is None:
                AgentProcessMonitor.stop_process(proc)

    def run(
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
        agent_executor = self._make_agent_executor(executor, workdir)
        profile_agents, profile_memory = self.profile_store.load_context(session_id_hint=session_id)
        workdir_memory_path = self.profile_store.stage_files_in_workdir(
            workdir,
            session_id_hint=session_id,
            include_agents=include_profile_agents,
            include_memory=include_profile_memory,
        )
        agent_prompt = self.environment.build_runtime_agent_prompt(
            prompt,
            executor=executor,
            response_profile=response_profile,
            profile_agents=profile_agents,
            profile_memory=profile_memory,
            include_profile_agents=include_profile_agents,
            include_profile_memory=include_profile_memory,
            memory_file_hint=".mobaile/MEMORY.md",
        )
        normalized_client_thread_id = (client_thread_id or "").strip() or None
        resume_session_id: str | None = None
        if normalized_client_thread_id:
            resume_session_id = self.run_state.run_store.get_agent_session_id(
                executor,
                session_id,
                normalized_client_thread_id,
            )

        self.run_state.append_activity_event(
            run_id,
            stage="planning",
            title="Planning",
            display_message="Reviewing your request and planning the next steps.",
            event_type="activity.started",
        )
        self.run_state.append_event(
            run_id,
            ExecutionEvent(
                type="action.started",
                action_index=0,
                message=f"starting {executor} exec (cwd={workdir})",
            ),
        )
        if guardrail_message:
            self.run_state.append_chat_message(
                run_id,
                summary=guardrail_message,
                sections=[ChatSection(title="Safety", body=guardrail_message)],
            )
        final_action_index = 0
        try:
            proc = self._start_process(
                agent_executor=agent_executor,
                executor=executor,
                run_id=run_id,
                agent_prompt=agent_prompt,
                resume_session_id=resume_session_id,
                codex_model_override=codex_model_override,
                codex_reasoning_effort_override=codex_reasoning_effort_override,
                claude_model_override=claude_model_override,
            )
        except FileNotFoundError:
            self._finalizer.record_missing_binary(
                run_id,
                executor=executor,
                workdir_memory_path=workdir_memory_path,
            )
            return

        self.run_state.append_activity_event(
            run_id,
            stage="executing",
            title="Executing",
            display_message="Running commands and applying changes.",
        )
        outcome = self._monitor_process(
            proc,
            run_id=run_id,
            prompt=prompt,
            session_id=session_id,
            agent_executor=agent_executor,
            executor=executor,
            client_thread_id=normalized_client_thread_id,
            resume_session_id=resume_session_id,
        )
        if self._should_retry_without_resume(
            outcome=outcome,
            executor=executor,
            session_id=session_id,
            client_thread_id=normalized_client_thread_id,
        ):
            final_action_index = 1
            self.run_state.append_event(
                run_id,
                ExecutionEvent(
                    type="action.stderr",
                    action_index=0,
                    message=f"Saved {executor} session could not be resumed. Retrying with a fresh session.",
                ),
            )
            self.run_state.append_event(
                run_id,
                ExecutionEvent(
                    type="action.completed",
                    action_index=0,
                    message=f"{executor} exec resume failed (exit={outcome.exit_code})",
                ),
            )
            self.run_state.append_activity_event(
                run_id,
                stage="executing",
                title="Executing",
                display_message=f"Saved {executor} session could not be resumed. Starting a fresh session.",
                level="warning",
            )
            self.run_state.append_log_message(
                run_id,
                f"Saved {executor} session could not be resumed; retrying without session resume.",
                action_index=0,
            )
            self.run_state.append_event(
                run_id,
                ExecutionEvent(
                    type="action.started",
                    action_index=1,
                    message=f"retrying {executor} exec without saved session",
                ),
            )
            try:
                proc = self._start_process(
                    agent_executor=agent_executor,
                    executor=executor,
                    run_id=run_id,
                    agent_prompt=agent_prompt,
                    resume_session_id=None,
                    codex_model_override=codex_model_override,
                    codex_reasoning_effort_override=codex_reasoning_effort_override,
                    claude_model_override=claude_model_override,
                )
            except FileNotFoundError:
                self._finalizer.record_missing_binary(
                    run_id,
                    executor=executor,
                    workdir_memory_path=workdir_memory_path,
                )
                return
            outcome = self._monitor_process(
                proc,
                run_id=run_id,
                prompt=prompt,
                session_id=session_id,
                agent_executor=agent_executor,
                executor=executor,
                client_thread_id=normalized_client_thread_id,
                resume_session_id=None,
            )
        self._finalize_run(
            run_id,
            executor=executor,
            outcome=outcome,
            workdir_memory_path=workdir_memory_path,
            action_index=final_action_index,
        )

    def _should_retry_without_resume(
        self,
        *,
        outcome: AgentRunOutcome,
        executor: AgentExecutorName,
        session_id: str,
        client_thread_id: str | None,
    ) -> bool:
        if executor != "codex":
            return False
        if not client_thread_id:
            return False
        if outcome.cancelled or outcome.timed_out or outcome.blocked or outcome.exit_code == 0:
            return False
        if outcome.resume_failure_reason != "stale_session":
            return False

        self.run_state.run_store.delete_agent_session_id(executor, session_id, client_thread_id)
        return True

    def _start_process(
        self,
        *,
        agent_executor: CodexExecutor | ClaudeExecutor,
        executor: AgentExecutorName,
        run_id: str,
        agent_prompt: str,
        resume_session_id: str | None,
        codex_model_override: str | None,
        codex_reasoning_effort_override: str | None,
        claude_model_override: str | None,
    ) -> subprocess.Popen[str]:
        if executor == "codex":
            return agent_executor.start(
                agent_prompt,
                resume_session_id=resume_session_id,
                model_override=codex_model_override,
                reasoning_effort_override=codex_reasoning_effort_override,
                env_overrides=self._agent_process_env(run_id),
            )
        return agent_executor.start(
            agent_prompt,
            resume_session_id=resume_session_id,
            model_override=claude_model_override,
            env_overrides=self._agent_process_env(run_id),
        )

    def _monitor_process(
        self,
        proc: subprocess.Popen[str],
        *,
        run_id: str,
        prompt: str,
        session_id: str,
        agent_executor: CodexExecutor | ClaudeExecutor,
        executor: AgentExecutorName,
        client_thread_id: str | None,
        resume_session_id: str | None,
    ) -> AgentRunOutcome:
        resume_failure_classifier = self._resume_failure_classifier(
            agent_executor=agent_executor,
            resume_session_id=resume_session_id,
        )
        with self._active_procs_lock:
            self._active_procs[run_id] = proc
        try:
            return self._process_monitor.monitor(
                proc,
                run_id=run_id,
                prompt=prompt,
                session_id=session_id,
                executor=executor,
                client_thread_id=client_thread_id,
                resume_session_id=resume_session_id,
                resume_failure_classifier=resume_failure_classifier,
            )
        finally:
            with self._active_procs_lock:
                self._active_procs.pop(run_id, None)

    def _finalize_run(
        self,
        run_id: str,
        *,
        executor: AgentExecutorName,
        outcome: AgentRunOutcome,
        workdir_memory_path: Path,
        action_index: int = 0,
    ) -> None:
        if not outcome.blocked and not outcome.cancelled:
            self.run_state.append_activity_event(
                run_id,
                stage="summarizing",
                title="Summarizing",
                display_message="Preparing the final result.",
                event_type="activity.completed",
            )
        self._finalizer.finalize_run(
            run_id,
            executor=executor,
            outcome=outcome,
            workdir_memory_path=workdir_memory_path,
            action_index=action_index,
        )

    def _make_agent_executor(self, executor: AgentExecutorName, workdir: Path) -> CodexExecutor | ClaudeExecutor:
        if executor == "codex":
            return CodexExecutor(
                workdir,
                binary=self.environment.codex_binary,
                codex_home=self.environment.codex_home,
                enable_web_search=self.environment.codex_enable_web_search,
            )
        if executor == "claude":
            return ClaudeExecutor(workdir)
        raise ValueError(f"unsupported agent executor '{executor}'")

    def _agent_timeout_sec(self, executor: AgentExecutorName) -> int:
        if executor == "claude":
            return self.environment.claude_timeout_sec
        return self.environment.codex_timeout_sec

    def _agent_process_env(self, run_id: str) -> dict[str, str]:
        return {
            "MOBAILE_ACTIVE_RUN_ID": run_id,
            "MOBAILE_DEFER_SERVICE_RESTART": "true",
            "MOBAILE_RUNS_DB_PATH": str(self.run_state.run_store.db_path),
        }

    @staticmethod
    def _resume_failure_classifier(
        *,
        agent_executor: CodexExecutor | ClaudeExecutor,
        resume_session_id: str | None,
    ) -> Callable[[str], str | None] | None:
        if not resume_session_id:
            return None
        return agent_executor.classify_resume_failure
