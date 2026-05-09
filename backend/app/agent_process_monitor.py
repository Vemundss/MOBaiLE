from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from queue import Empty, Queue
from typing import Callable

from app.agent_run_finalizer import AgentRunOutcome
from app.agent_stream_handler import AgentStreamHandler
from app.codex_text import CodexAssistantExtractor
from app.models.schemas import AgentExecutorName
from app.run_state import RunState


class AgentProcessMonitor:
    def __init__(
        self,
        *,
        run_state: RunState,
        stream_handler: AgentStreamHandler,
        timeout_resolver: Callable[[AgentExecutorName], int],
        leak_marker_provider: Callable[[], list[str]],
    ) -> None:
        self.run_state = run_state
        self.stream_handler = stream_handler
        self.timeout_resolver = timeout_resolver
        self.leak_marker_provider = leak_marker_provider

    def monitor(
        self,
        proc: subprocess.Popen[str],
        *,
        run_id: str,
        prompt: str,
        session_id: str,
        executor: AgentExecutorName,
        client_thread_id: str | None,
        resume_session_id: str | None,
        resume_failure_classifier: Callable[[str], str | None] | None = None,
    ) -> AgentRunOutcome:
        assert proc.stdout is not None
        line_queue: Queue[str | None] = Queue()

        def drain_stdout() -> None:
            assert proc.stdout is not None
            for line in proc.stdout:
                line_queue.put(line.rstrip("\r\n"))
            line_queue.put(None)

        reader = threading.Thread(target=drain_stdout, daemon=True)
        reader.start()

        linked_session_id = resume_session_id
        cancelled = False
        cancel_reason: str | None = None
        timed_out = False
        blocked = False
        resume_failure_reason: str | None = None
        timeout_sec = self.timeout_resolver(executor)
        deadline = time.monotonic() + timeout_sec if timeout_sec > 0 else None
        chat_extractor = self._chat_extractor(prompt=prompt, executor=executor)

        while True:
            try:
                line = line_queue.get(timeout=0.2)
            except Empty:
                line = None

            if line is not None:
                if resume_failure_reason is None and resume_failure_classifier is not None:
                    resume_failure_reason = resume_failure_classifier(line)
                blocked, linked_session_id = self.stream_handler.consume_message(
                    line,
                    run_id=run_id,
                    session_id=session_id,
                    executor=executor,
                    client_thread_id=client_thread_id,
                    linked_session_id=linked_session_id,
                    chat_extractor=chat_extractor,
                )
                if blocked:
                    break
            else:
                if proc.poll() is not None:
                    break

            if self.run_state.is_cancelled(run_id):
                cancelled = True
                cancel_reason = self.run_state.cancel_reason(run_id)
                break
            run = self.run_state.get_run(run_id)
            if run is not None and run.status == "blocked":
                blocked = True
                break
            if deadline is not None and time.monotonic() > deadline:
                timed_out = True
                break

        if self.stream_handler.flush_codex_messages(run_id, chat_extractor=chat_extractor):
            blocked = True

        if cancelled or timed_out or blocked:
            self.stop_process(proc)
        exit_code = proc.wait()
        if not cancelled and self.run_state.is_cancelled(run_id):
            cancelled = True
            cancel_reason = self.run_state.cancel_reason(run_id)
        return AgentRunOutcome(
            exit_code=exit_code,
            cancelled=cancelled,
            cancel_reason=cancel_reason,
            timed_out=timed_out,
            blocked=blocked,
            resume_failure_reason=resume_failure_reason,
        )

    def _chat_extractor(self, *, prompt: str, executor: AgentExecutorName) -> CodexAssistantExtractor | None:
        if executor != "codex":
            return None
        return CodexAssistantExtractor(prompt, self.leak_marker_provider())

    @staticmethod
    def stop_process(proc: subprocess.Popen[str]) -> None:
        if proc.poll() is None:
            AgentProcessMonitor._terminate_process_group(proc)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                AgentProcessMonitor._kill_process_group(proc)
                proc.wait()

    @staticmethod
    def _terminate_process_group(proc: subprocess.Popen[str]) -> None:
        if AgentProcessMonitor._signal_process_group(proc, signal.SIGTERM):
            return
        proc.terminate()

    @staticmethod
    def _kill_process_group(proc: subprocess.Popen[str]) -> None:
        if AgentProcessMonitor._signal_process_group(proc, signal.SIGKILL):
            return
        proc.kill()

    @staticmethod
    def _signal_process_group(proc: subprocess.Popen[str], sig: int) -> bool:
        pid = getattr(proc, "pid", None)
        if not pid or not hasattr(os, "killpg"):
            return False
        try:
            os.killpg(pid, sig)
            return True
        except ProcessLookupError:
            return True
        except OSError:
            return False
