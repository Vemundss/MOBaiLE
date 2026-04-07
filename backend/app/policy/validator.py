from __future__ import annotations

import shlex

from app.models.schemas import ActionPlan

ALLOWED_BINARIES = {"python3", "python", "ls", "cat"}
FORBIDDEN_TOKENS = {"rm", "sudo", "chmod", "chown", "mkfs", "dd"}


def validate_plan(plan: ActionPlan) -> tuple[bool, str]:
    for action in plan.actions:
        if action.type == "write_file":
            path = action.path or ""
            if path.startswith("/") or ".." in path.split("/"):
                return False, "write_file path must be relative and stay inside sandbox"
        elif action.type == "run_command":
            assert action.command is not None
            try:
                tokens = shlex.split(action.command)
            except ValueError:
                return False, "run_command is not valid shell syntax"
            if not tokens:
                return False, "run_command cannot be empty"
            if any(tok in FORBIDDEN_TOKENS for tok in tokens):
                return False, "run_command includes forbidden token"
            binary = tokens[0]
            if binary not in ALLOWED_BINARIES:
                return False, f"binary '{binary}' is not allowed"
    return True, "ok"
