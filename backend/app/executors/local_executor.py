from __future__ import annotations

import os
import shlex
import signal
import subprocess
import time
from pathlib import Path
from typing import Callable

from app.models.schemas import Action, ActionResult
from app.policy.validator import ALLOWED_BINARIES


class LocalExecutor:
    def __init__(self, sandbox_root: Path, *, is_cancelled: Callable[[], bool] | None = None) -> None:
        self.sandbox_root = sandbox_root.resolve()
        self.is_cancelled = is_cancelled or (lambda: False)
        self.sandbox_root.mkdir(parents=True, exist_ok=True)

    def execute(self, action: Action) -> ActionResult:
        if action.type == "write_file":
            assert action.path is not None
            assert action.content is not None
            return self._write_file(action.path, action.content)
        if action.type == "run_command":
            assert action.command is not None
            return self._run_command(action.command, action.timeout_sec)
        return ActionResult(success=False, details=f"unsupported action type: {action.type}")

    def _write_file(self, relative_path: str, content: str) -> ActionResult:
        target = (self.sandbox_root / relative_path).resolve()
        if not self._is_inside_sandbox(target):
            return ActionResult(success=False, details="write path escaped sandbox")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return ActionResult(success=True, details=f"wrote {target.relative_to(self.sandbox_root)}")

    def _run_command(self, command: str, timeout_sec: int) -> ActionResult:
        try:
            tokens = shlex.split(command)
        except ValueError as exc:
            return ActionResult(success=False, details=f"invalid command: {exc}")
        if not tokens:
            return ActionResult(success=False, details="empty command")
        binary = tokens[0]
        if binary not in ALLOWED_BINARIES:
            return ActionResult(success=False, details=f"binary '{binary}' is not allowed")
        try:
            proc = subprocess.Popen(
                tokens,
                cwd=str(self.sandbox_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
        except OSError as exc:
            return ActionResult(success=False, details=f"command failed to start: {exc}")

        deadline = time.monotonic() + timeout_sec if timeout_sec > 0 else None
        while proc.poll() is None:
            if self.is_cancelled():
                stdout, stderr = self._stop_process(proc)
                return ActionResult(success=False, stdout=stdout, stderr=stderr, details="command cancelled")
            if deadline is not None and time.monotonic() >= deadline:
                stdout, stderr = self._stop_process(proc)
                return ActionResult(success=False, stdout=stdout, stderr=stderr, details=f"command timed out after {timeout_sec}s")
            time.sleep(0.1)

        stdout, stderr = proc.communicate()
        return ActionResult(
            success=proc.returncode == 0,
            exit_code=proc.returncode,
            stdout=stdout,
            stderr=stderr,
            details=f"ran '{command}'",
        )

    @staticmethod
    def _stop_process(proc: subprocess.Popen[str]) -> tuple[str, str]:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            proc.terminate()
        try:
            return proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                proc.kill()
            return proc.communicate()

    def _is_inside_sandbox(self, path: Path) -> bool:
        try:
            path.relative_to(self.sandbox_root)
            return True
        except ValueError:
            return False
