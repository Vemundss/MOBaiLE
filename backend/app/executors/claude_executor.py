from __future__ import annotations

import os
import subprocess
from pathlib import Path


class ClaudeExecutor:
    def __init__(self, workdir: Path, binary: str | None = None) -> None:
        self.workdir = workdir.resolve()
        self.binary = binary or os.getenv("VOICE_AGENT_CLAUDE_BINARY", "claude")
        self.default_model = (
            os.getenv("VOICE_AGENT_CLAUDE_MODEL", "").strip()
            or os.getenv("ANTHROPIC_MODEL", "").strip()
        )
        security_mode = os.getenv("VOICE_AGENT_SECURITY_MODE", "safe").strip().lower()
        default_skip_permissions = "true" if security_mode == "full-access" else "false"
        skip_permissions = os.getenv(
            "VOICE_AGENT_CLAUDE_SKIP_PERMISSIONS",
            default_skip_permissions,
        ).strip().lower()
        self.skip_permissions = skip_permissions not in {"0", "false", "no", "off"}
        self.permission_mode = os.getenv(
            "VOICE_AGENT_CLAUDE_PERMISSION_MODE",
            "" if self.skip_permissions else "acceptEdits",
        ).strip()

    def start(
        self,
        prompt: str,
        *,
        resume_session_id: str | None = None,
        model_override: str | None = None,
    ) -> subprocess.Popen[str]:
        # Claude Code's headless print mode can stream structured JSON events.
        cmd = [self.binary, "-p", prompt, "--output-format", "stream-json", "--verbose"]
        if resume_session_id:
            cmd.extend(["--resume", resume_session_id])
        if self.skip_permissions:
            cmd.append("--dangerously-skip-permissions")
        elif self.permission_mode:
            cmd.extend(["--permission-mode", self.permission_mode])

        env = os.environ.copy()
        model = (model_override or self.default_model).strip()
        if model:
            env["ANTHROPIC_MODEL"] = model

        return subprocess.Popen(
            cmd,
            cwd=str(self.workdir),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
