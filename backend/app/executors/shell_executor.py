from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Callable

from app.models.schemas import ActionResult


class ShellExecutor:
    def __init__(
        self,
        sandbox_root: Path,
        *,
        shell_binary: str,
        is_cancelled: Callable[[], bool] | None = None,
    ) -> None:
        self.sandbox_root = sandbox_root.resolve()
        self.shell_binary = shell_binary
        self.is_cancelled = is_cancelled or (lambda: False)
        self.sandbox_root.mkdir(parents=True, exist_ok=True)

    def execute(self, command: str, *, timeout_sec: int) -> ActionResult:
        normalized_command = command.strip()
        if not normalized_command:
            return ActionResult(success=False, details="empty command")
        try:
            proc = subprocess.Popen(
                [self.shell_binary, "-lc", normalized_command],
                cwd=str(self.sandbox_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
        except OSError as exc:
            return ActionResult(success=False, details=f"command failed to start: {exc}")

        deadline = time.monotonic() + timeout_sec if timeout_sec > 0 else None
        while True:
            try:
                stdout, stderr = proc.communicate(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                if self.is_cancelled():
                    stdout, stderr = self._stop_process(proc)
                    return ActionResult(success=False, stdout=stdout, stderr=stderr, details="command cancelled")
                if deadline is not None and time.monotonic() >= deadline:
                    stdout, stderr = self._stop_process(proc)
                    return ActionResult(
                        success=False,
                        stdout=stdout,
                        stderr=stderr,
                        details=f"command timed out after {timeout_sec}s",
                    )

        return ActionResult(
            success=proc.returncode == 0,
            exit_code=proc.returncode,
            stdout=stdout,
            stderr=stderr,
            details=f"ran '{normalized_command}'",
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
