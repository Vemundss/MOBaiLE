from __future__ import annotations

import os
import subprocess
from pathlib import Path


class CodexExecutor:
    def __init__(
        self,
        workdir: Path,
        binary: str | None = None,
        *,
        codex_home: Path | None = None,
        enable_web_search: bool | None = None,
    ) -> None:
        self.workdir = workdir.resolve()
        self.binary = binary or os.getenv("VOICE_AGENT_CODEX_BINARY", "codex")
        codex_home_raw = os.getenv("VOICE_AGENT_CODEX_HOME", "").strip()
        self.codex_home = codex_home or (Path(codex_home_raw).expanduser().resolve() if codex_home_raw else None)
        self.model = os.getenv("VOICE_AGENT_CODEX_MODEL", "").strip()
        security_mode = os.getenv("VOICE_AGENT_SECURITY_MODE", "safe").strip().lower()
        default_unrestricted = "true" if security_mode == "full-access" else "false"
        unrestricted = os.getenv("VOICE_AGENT_CODEX_UNRESTRICTED", default_unrestricted).strip().lower()
        self.unrestricted = unrestricted not in {"0", "false", "no", "off"}
        if enable_web_search is None:
            search_raw = os.getenv("VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH", "true").strip().lower()
            self.enable_web_search = search_raw not in {"0", "false", "no", "off"}
        else:
            self.enable_web_search = enable_web_search

    def start(self, prompt: str, *, resume_session_id: str | None = None) -> subprocess.Popen[str]:
        # Non-interactive invocation for Codex CLI.
        cmd = [self.binary, "exec"]
        if resume_session_id:
            cmd.extend(["resume", resume_session_id])
        cmd.extend(["--json", "--skip-git-repo-check"])
        if self.unrestricted:
            cmd.append("--dangerously-bypass-approvals-and-sandbox")
        if self.enable_web_search:
            cmd.append("--search")
        if self.model:
            cmd.extend(["--model", self.model])
        cmd.append(prompt)
        env = os.environ.copy()
        if self.codex_home is not None:
            env["CODEX_HOME"] = str(self.codex_home)
        return subprocess.Popen(
            cmd,
            cwd=str(self.workdir),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
