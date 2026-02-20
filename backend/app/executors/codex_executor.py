from __future__ import annotations

import os
import subprocess
from pathlib import Path


class CodexExecutor:
    def __init__(self, workdir: Path, binary: str | None = None) -> None:
        self.workdir = workdir.resolve()
        self.binary = binary or os.getenv("VOICE_AGENT_CODEX_BINARY", "codex")
        self.model = os.getenv("VOICE_AGENT_CODEX_MODEL", "").strip()
        unrestricted = os.getenv("VOICE_AGENT_CODEX_UNRESTRICTED", "true").strip().lower()
        self.unrestricted = unrestricted not in {"0", "false", "no", "off"}

    def start(self, prompt: str) -> subprocess.Popen[str]:
        # Non-interactive invocation for Codex CLI.
        cmd = [self.binary, "exec", "--skip-git-repo-check"]
        if self.unrestricted:
            cmd.append("--dangerously-bypass-approvals-and-sandbox")
        if self.model:
            cmd.extend(["--model", self.model])
        cmd.append(prompt)
        return subprocess.Popen(
            cmd,
            cwd=str(self.workdir),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
