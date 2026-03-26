from __future__ import annotations

from datetime import datetime
from pathlib import Path
from queue import Empty
from queue import Queue
import subprocess
import threading
import time
from typing import Callable

from app.claude_text import claude_assistant_text
from app.claude_text import claude_session_id
from app.claude_text import parse_claude_stream_event
from app.chat_envelope import find_human_unblock_section
from app.codex_text import CodexAssistantExtractor
from app.codex_text import parse_codex_json_event
from app.executors.claude_executor import ClaudeExecutor
from app.executors.codex_executor import CodexExecutor
from app.executors.local_executor import LocalExecutor
from app.models.schemas import ActionPlan
from app.models.schemas import AgentExecutorName
from app.models.schemas import AgendaItem
from app.models.schemas import ChatSection
from app.models.schemas import ExecutionEvent
from app.models.schemas import ResponseProfile
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
        self._active_procs_lock = threading.Lock()
        self._active_procs: dict[str, subprocess.Popen[str]] = {}

    def terminate_active_process(self, run_id: str) -> None:
        with self._active_procs_lock:
            proc = self._active_procs.get(run_id)
            if proc is not None and proc.poll() is None:
                proc.terminate()

    def run_calendar_adapter(self, run_id: str, prompt: str) -> None:
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="action.started", action_index=0, message="starting calendar adapter"),
        )
        self.run_state.append_chat_message(
            run_id,
            summary="Checking your calendar for today.",
            sections=[ChatSection(title="What I Did", body="Queried your local macOS Calendar for today's events.")],
        )
        try:
            events = self.fetch_calendar_events()
        except Exception as exc:
            self.run_state.append_log_message(run_id, f"Calendar adapter failed: {exc}")
            self.run_state.append_event(
                run_id,
                ExecutionEvent(type="action.completed", action_index=0, message="calendar adapter failed"),
            )
            self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message="Run failed"))
            self.run_state.set_run_status(run_id, "failed", "Calendar query failed")
            return

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
        success = self._execute_plan(run_id, plan, executor)
        run = self.run_state.get_run(run_id)
        if run is not None and run.status == "cancelled":
            return
        summary = "Run completed successfully" if success else "Run failed"
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
        guardrail_message: str | None = None,
    ) -> None:
        agent_executor = self._make_agent_executor(executor, workdir)
        profile_agents, profile_memory = self.profile_store.load_context(session_id_hint=session_id)
        workdir_memory_path = self.profile_store.stage_files_in_workdir(
            workdir,
            session_id_hint=session_id,
        )
        agent_prompt = self.environment.build_runtime_agent_prompt(
            prompt,
            executor=executor,
            response_profile=response_profile,
            profile_agents=profile_agents,
            profile_memory=profile_memory,
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
        try:
            proc = agent_executor.start(agent_prompt, resume_session_id=resume_session_id)
        except FileNotFoundError:
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
            return

        with self._active_procs_lock:
            self._active_procs[run_id] = proc

        assert proc.stdout is not None
        line_queue: Queue[str | None] = Queue()

        def drain_stdout() -> None:
            assert proc.stdout is not None
            for line in proc.stdout:
                line_queue.put(line.rstrip("\r\n"))
            line_queue.put(None)

        reader = threading.Thread(target=drain_stdout, daemon=True)
        reader.start()

        leak_markers = self.environment.runtime_context_leak_markers()
        chat_extractor = CodexAssistantExtractor(prompt, leak_markers) if executor == "codex" else None
        timed_out = False
        cancelled = False
        blocked = False
        timeout_sec = self._agent_timeout_sec(executor)
        deadline = time.monotonic() + timeout_sec if timeout_sec > 0 else None
        linked_session_id = resume_session_id

        while True:
            try:
                line = line_queue.get(timeout=0.2)
            except Empty:
                line = None

            if line is not None:
                message = line.rstrip()
                if message:
                    if executor == "codex":
                        parsed = parse_codex_json_event(message)
                        if parsed is not None:
                            linked_session_id, blocked = self._handle_codex_event(
                                run_id,
                                executor,
                                session_id,
                                normalized_client_thread_id,
                                linked_session_id,
                                parsed,
                            )
                            if blocked:
                                break
                            continue

                        self.run_state.append_log_message(run_id, message, action_index=0)
                        assert chat_extractor is not None
                        for structured in chat_extractor.consume(message):
                            if self._append_assistant_payload(run_id, structured):
                                blocked = True
                                break
                        if blocked:
                            break
                    else:
                        parsed = parse_claude_stream_event(message)
                        if parsed is not None:
                            linked_session_id, blocked = self._handle_claude_event(
                                run_id,
                                executor,
                                session_id,
                                normalized_client_thread_id,
                                linked_session_id,
                                parsed,
                            )
                            if blocked:
                                break
                            continue

                        self.run_state.append_log_message(run_id, message, action_index=0)
            else:
                if proc.poll() is not None:
                    break

            if self.run_state.is_cancelled(run_id):
                cancelled = True
                break
            run = self.run_state.get_run(run_id)
            if run is not None and run.status == "blocked":
                blocked = True
                break
            if deadline is not None and time.monotonic() > deadline:
                timed_out = True
                break

        if chat_extractor is not None:
            for structured in chat_extractor.flush():
                if self._append_assistant_payload(run_id, structured):
                    blocked = True

        if cancelled or timed_out or blocked:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        exit_code = proc.wait()
        if not cancelled and self.run_state.is_cancelled(run_id):
            cancelled = True
        with self._active_procs_lock:
            self._active_procs.pop(run_id, None)

        if not blocked:
            self.run_state.append_event(
                run_id,
                ExecutionEvent(
                    type="action.completed",
                    action_index=0,
                    message=f"{executor} exec finished (exit={exit_code})",
                ),
            )

        if cancelled:
            summary = "Run cancelled by user"
            self.run_state.append_event(run_id, ExecutionEvent(type="run.cancelled", message=summary))
            self.run_state.set_run_status(run_id, "cancelled", summary)
            self.profile_store.sync_memory_from_workdir(workdir_memory_path)
            return
        if blocked:
            current = self.run_state.get_run(run_id)
            summary = current.summary if current is not None else "Human unblock required"
            self.run_state.append_event(
                run_id,
                ExecutionEvent(
                    type="action.completed",
                    action_index=0,
                    message=f"{executor} exec blocked awaiting user input",
                ),
            )
            self.run_state.set_run_status(run_id, "blocked", summary)
            self.profile_store.sync_memory_from_workdir(workdir_memory_path)
            return
        if timed_out:
            summary = f"Run timed out after {timeout_sec}s"
            self.run_state.append_event(run_id, ExecutionEvent(type="run.failed", message=summary))
            self.run_state.set_run_status(run_id, "failed", summary)
            self.profile_store.sync_memory_from_workdir(workdir_memory_path)
            return

        success = exit_code == 0
        summary = "Run completed successfully" if success else "Run failed"
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="run.completed" if success else "run.failed", message=summary),
        )
        self.run_state.set_run_status(run_id, "completed" if success else "failed", summary)
        self.profile_store.sync_memory_from_workdir(workdir_memory_path)

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

    def _execute_plan(self, run_id: str, plan: ActionPlan, executor: LocalExecutor) -> bool:
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
                    return linked_session_id, self._append_assistant_payload(run_id, item_text)
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
            return linked_session_id, self._append_assistant_payload(run_id, assistant_text)
        return linked_session_id, False

    def _append_assistant_payload(self, run_id: str, raw_text: str) -> bool:
        envelope = self.run_state.append_assistant_payload(run_id, raw_text)
        unblock = find_human_unblock_section(envelope)
        if unblock is None:
            return False
        run = self.run_state.get_run(run_id)
        if run is not None and run.status == "blocked":
            return True
        details = unblock.body.strip() or "Human unblock required"
        summary = details.splitlines()[0].strip() or "Human unblock required"
        self.run_state.append_event(
            run_id,
            ExecutionEvent(type="run.blocked", message=details),
        )
        self.run_state.set_run_status(run_id, "blocked", summary)
        return True
