from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Literal

CodexResumeFailureReason = Literal["stale_session"]


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
        self.default_model = os.getenv("VOICE_AGENT_CODEX_MODEL", "").strip()
        self.default_reasoning_effort = os.getenv("VOICE_AGENT_CODEX_REASONING_EFFORT", "").strip().lower()
        security_mode = os.getenv("VOICE_AGENT_SECURITY_MODE", "safe").strip().lower()
        default_unrestricted = "true" if security_mode == "full-access" else "false"
        unrestricted = os.getenv("VOICE_AGENT_CODEX_UNRESTRICTED", default_unrestricted).strip().lower()
        self.unrestricted = unrestricted not in {"0", "false", "no", "off"}
        if enable_web_search is None:
            search_raw = os.getenv("VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH", "true").strip().lower()
            self.enable_web_search = search_raw not in {"0", "false", "no", "off"}
        else:
            self.enable_web_search = enable_web_search

    def start(
        self,
        prompt: str,
        *,
        resume_session_id: str | None = None,
        model_override: str | None = None,
        reasoning_effort_override: str | None = None,
    ) -> subprocess.Popen[str]:
        cmd = self._build_command(
            prompt,
            resume_session_id=resume_session_id,
            model_override=model_override,
            reasoning_effort_override=reasoning_effort_override,
        )
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

    def _build_command(
        self,
        prompt: str,
        *,
        resume_session_id: str | None = None,
        model_override: str | None = None,
        reasoning_effort_override: str | None = None,
    ) -> list[str]:
        # `--search` is a top-level Codex flag in current CLI builds, so it must
        # appear before the `exec` subcommand rather than after it.
        cmd = [self.binary]
        if self.enable_web_search:
            cmd.append("--search")
        cmd.append("exec")
        if resume_session_id:
            cmd.extend(["resume", resume_session_id])
        cmd.extend(["--json", "--skip-git-repo-check"])
        if self.unrestricted:
            cmd.append("--dangerously-bypass-approvals-and-sandbox")
        model = (model_override or self.default_model).strip()
        if model:
            cmd.extend(["--model", model])
        reasoning_effort = (reasoning_effort_override or self.default_reasoning_effort).strip().lower()
        if reasoning_effort:
            cmd.extend(["-c", f'model_reasoning_effort="{reasoning_effort}"'])
        cmd.append(prompt)
        return cmd

    @staticmethod
    def classify_resume_failure(message: str) -> CodexResumeFailureReason | None:
        normalized = message.strip().lower()
        if "thread/resume" in normalized and "no rollout found" in normalized:
            return "stale_session"
        return None
