from __future__ import annotations

import shlex
import subprocess
from pathlib import Path

from app.models.schemas import Action, ActionResult
from app.policy.validator import ALLOWED_BINARIES


class LocalExecutor:
    def __init__(self, sandbox_root: Path) -> None:
        self.sandbox_root = sandbox_root.resolve()
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
            proc = subprocess.run(
                tokens,
                cwd=str(self.sandbox_root),
                capture_output=True,
                text=True,
                timeout=timeout_sec,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return ActionResult(success=False, details=f"command timed out after {timeout_sec}s")
        return ActionResult(
            success=proc.returncode == 0,
            exit_code=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            details=f"ran '{command}'",
        )

    def _is_inside_sandbox(self, path: Path) -> bool:
        try:
            path.relative_to(self.sandbox_root)
            return True
        except ValueError:
            return False
