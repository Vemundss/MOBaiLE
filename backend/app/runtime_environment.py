from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import shutil

from app.agent_runtime import build_agent_prompt
from app.agent_runtime import context_leak_markers
from app.agent_runtime import evaluate_agent_guardrails
from app.agent_runtime import load_runtime_context
from app.models.schemas import AgentExecutorName
from app.models.schemas import ResponseProfile
from app.models.schemas import RunExecutorName
from app.models.schemas import RuntimeConfigResponse
from app.models.schemas import RuntimeExecutorDescriptor

AGENT_TITLES: dict[RunExecutorName, str] = {
    "local": "Local fallback",
    "codex": "Codex",
    "claude": "Claude Code",
}

AGENT_HOME_HINTS: dict[AgentExecutorName, str] = {
    "codex": "~/.codex/*",
    "claude": "~/.claude/*",
}


def _resolve_path_value(raw_value: str, *, base_dir: Path) -> Path:
    path = Path(raw_value).expanduser()
    if path.is_absolute():
        return path.resolve()
    return (base_dir / path).resolve()


def load_env_defaults(env_path: Path) -> None:
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        if not key:
            continue
        os.environ.setdefault(key, value.strip().strip("'\""))


def _binary_available(binary: str) -> bool:
    trimmed = binary.strip()
    if not trimmed:
        return False
    if "/" in trimmed or trimmed.startswith("."):
        return Path(trimmed).expanduser().exists()
    return shutil.which(trimmed) is not None


def _stable_key(raw_value: str) -> str:
    cleaned = "".join(char if char.isalnum() or char in "._-" else "_" for char in raw_value.strip())[:120]
    return cleaned or "default"


def _read_non_negative_int_env(name: str, default: int) -> int:
    raw_value = os.getenv(name, str(default)).strip()
    try:
        parsed = int(raw_value)
    except ValueError:
        return default
    return max(0, parsed)


@dataclass(frozen=True)
class RuntimeEnvironment:
    backend_root: Path
    default_workdir: Path
    security_mode: str
    full_access_mode: bool
    workdir_root: Path | None
    allow_absolute_file_reads: bool
    file_roots: tuple[Path, ...]
    path_access_roots: tuple[Path, ...]
    codex_binary: str
    claude_binary: str
    codex_home: Path
    codex_enable_web_search: bool
    codex_model_override: str
    claude_model_override: str
    codex_timeout_sec: int
    claude_timeout_sec: int
    playwright_output_dir: Path
    playwright_user_data_dir: Path
    use_agent_context: bool
    runtime_context_file: str
    runtime_context: str
    guardrails_mode: str
    dangerous_confirm_token: str
    configured_default_executor: RunExecutorName
    default_executor: RunExecutorName
    profile_state_root: Path
    legacy_session_state_root: Path
    profile_id: str
    profile_agents_max_chars: int
    profile_memory_max_chars: int
    max_audio_mb: float
    max_audio_bytes: int
    max_upload_mb: float
    max_upload_bytes: int
    max_directory_entries: int
    max_event_message_chars: int
    capabilities_report_path: Path
    api_token: str
    db_path: Path
    pairing_file: Path
    pair_code_ttl_min: int
    pair_attempt_limit_per_min: int
    uploads_root: Path

    @classmethod
    def from_env(cls, backend_root: Path) -> "RuntimeEnvironment":
        default_workdir = Path(
            os.getenv("VOICE_AGENT_DEFAULT_WORKDIR", str(Path.home()))
        ).expanduser().resolve()
        default_workdir.mkdir(parents=True, exist_ok=True)

        security_mode = os.getenv("VOICE_AGENT_SECURITY_MODE", "safe").strip().lower()
        if security_mode not in {"safe", "full-access"}:
            security_mode = "safe"
        full_access_mode = security_mode == "full-access"

        workdir_root_raw = os.getenv("VOICE_AGENT_WORKDIR_ROOT", "").strip()
        if workdir_root_raw:
            workdir_root = Path(workdir_root_raw).expanduser().resolve()
        else:
            workdir_root = None if full_access_mode else default_workdir
        if workdir_root is not None:
            workdir_root.mkdir(parents=True, exist_ok=True)

        allow_absolute_file_reads = os.getenv(
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS",
            "true" if full_access_mode else "false",
        ).strip().lower() in {"1", "true", "yes", "on"}

        file_roots_raw = os.getenv("VOICE_AGENT_FILE_ROOTS", "").strip()
        explicit_file_roots = bool(file_roots_raw)
        if explicit_file_roots:
            file_roots = [
                Path(item.strip()).expanduser().resolve()
                for item in file_roots_raw.split(",")
                if item.strip()
            ]
        else:
            file_roots = [] if full_access_mode else [default_workdir]
            if workdir_root is not None and workdir_root not in file_roots:
                file_roots.append(workdir_root)

        for root in file_roots:
            root.mkdir(parents=True, exist_ok=True)

        path_access_roots = list(file_roots)

        codex_binary = os.getenv("VOICE_AGENT_CODEX_BINARY", "codex").strip() or "codex"
        claude_binary = os.getenv("VOICE_AGENT_CLAUDE_BINARY", "claude").strip() or "claude"
        codex_home = _resolve_path_value(
            os.getenv(
                "VOICE_AGENT_CODEX_HOME",
                os.getenv("CODEX_HOME", str(Path.home() / ".codex")),
            ).strip()
            or str(Path.home() / ".codex"),
            base_dir=backend_root,
        )
        codex_enable_web_search = os.getenv("VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH", "true").strip().lower() not in {
            "0",
            "false",
            "no",
            "off",
        }
        codex_timeout_sec = _read_non_negative_int_env("VOICE_AGENT_CODEX_TIMEOUT_SEC", 0)
        codex_model_override = os.getenv("VOICE_AGENT_CODEX_MODEL", "").strip()
        claude_model_override = os.getenv("VOICE_AGENT_CLAUDE_MODEL", "").strip()
        claude_timeout_sec = _read_non_negative_int_env("VOICE_AGENT_CLAUDE_TIMEOUT_SEC", codex_timeout_sec)
        playwright_output_dir = _resolve_path_value(
            os.getenv("VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR", "data/playwright").strip() or "data/playwright",
            base_dir=backend_root,
        )
        playwright_user_data_dir = _resolve_path_value(
            os.getenv("VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR", "data/playwright-profile").strip()
            or "data/playwright-profile",
            base_dir=backend_root,
        )
        playwright_output_dir.mkdir(parents=True, exist_ok=True)
        playwright_user_data_dir.mkdir(parents=True, exist_ok=True)

        use_agent_context = os.getenv("VOICE_AGENT_CODEX_USE_CONTEXT", "true").strip().lower() not in {
            "0",
            "false",
            "no",
            "off",
        }
        runtime_context_file = os.getenv("VOICE_AGENT_CODEX_CONTEXT_FILE", "../.mobaile/AGENT_CONTEXT.md").strip()
        runtime_context = load_runtime_context(runtime_context_file, backend_root)
        guardrails_mode = os.getenv("VOICE_AGENT_CODEX_GUARDRAILS", "warn").strip().lower()
        dangerous_confirm_token = os.getenv(
            "VOICE_AGENT_CODEX_DANGEROUS_CONFIRM_TOKEN", "[allow-dangerous]"
        ).strip()

        configured_default_executor = cls._configured_default_executor()
        available_agents = cls._available_agent_executors(codex_binary, claude_binary)
        default_executor = cls._resolve_default_executor(configured_default_executor, available_agents)

        profile_state_root = Path(
            os.getenv(
                "VOICE_AGENT_PROFILE_STATE_ROOT",
                os.getenv(
                    "VOICE_AGENT_SESSION_STATE_ROOT",
                    str(backend_root / "data" / "profiles"),
                ),
            )
        ).resolve()
        profile_state_root.mkdir(parents=True, exist_ok=True)

        legacy_session_state_root = Path(
            os.getenv(
                "VOICE_AGENT_SESSION_STATE_ROOT",
                str(backend_root / "data" / "sessions"),
            )
        ).resolve()

        uploads_root = ((workdir_root or default_workdir) / ".mobaile_uploads").resolve()
        uploads_root.mkdir(parents=True, exist_ok=True)
        if uploads_root not in path_access_roots:
            path_access_roots.append(uploads_root)
        if uploads_root not in file_roots and (explicit_file_roots or not (full_access_mode and allow_absolute_file_reads)):
            file_roots.append(uploads_root)

        capabilities_report_path = Path(
            os.getenv(
                "VOICE_AGENT_CAPABILITIES_REPORT_PATH",
                str(backend_root / "data" / "capabilities.json"),
            )
        ).resolve()
        db_path = Path(
            os.getenv(
                "VOICE_AGENT_DB_PATH",
                str(backend_root / "data" / "runs.db"),
            )
        )
        pairing_file = Path(
            os.getenv(
                "VOICE_AGENT_PAIRING_FILE",
                str(backend_root / "pairing.json"),
            )
        )

        max_audio_mb = float(os.getenv("VOICE_AGENT_MAX_AUDIO_MB", "20"))
        max_upload_mb = float(os.getenv("VOICE_AGENT_MAX_UPLOAD_MB", "25"))

        return cls(
            backend_root=backend_root,
            default_workdir=default_workdir,
            security_mode=security_mode,
            full_access_mode=full_access_mode,
            workdir_root=workdir_root,
            allow_absolute_file_reads=allow_absolute_file_reads,
            file_roots=tuple(file_roots),
            path_access_roots=tuple(path_access_roots),
            codex_binary=codex_binary,
            claude_binary=claude_binary,
            codex_home=codex_home,
            codex_enable_web_search=codex_enable_web_search,
            codex_model_override=codex_model_override,
            claude_model_override=claude_model_override,
            codex_timeout_sec=codex_timeout_sec,
            claude_timeout_sec=claude_timeout_sec,
            playwright_output_dir=playwright_output_dir,
            playwright_user_data_dir=playwright_user_data_dir,
            use_agent_context=use_agent_context,
            runtime_context_file=runtime_context_file,
            runtime_context=runtime_context,
            guardrails_mode=guardrails_mode,
            dangerous_confirm_token=dangerous_confirm_token,
            configured_default_executor=configured_default_executor,
            default_executor=default_executor,
            profile_state_root=profile_state_root,
            legacy_session_state_root=legacy_session_state_root,
            profile_id=os.getenv("VOICE_AGENT_PROFILE_ID", "default-user").strip() or "default-user",
            profile_agents_max_chars=int(
                os.getenv(
                    "VOICE_AGENT_PROFILE_AGENTS_MAX_CHARS",
                    os.getenv("VOICE_AGENT_SESSION_AGENTS_MAX_CHARS", "3000"),
                )
            ),
            profile_memory_max_chars=int(
                os.getenv(
                    "VOICE_AGENT_PROFILE_MEMORY_MAX_CHARS",
                    os.getenv("VOICE_AGENT_SESSION_MEMORY_MAX_CHARS", "6000"),
                )
            ),
            max_audio_mb=max_audio_mb,
            max_audio_bytes=int(max_audio_mb * 1024 * 1024),
            max_upload_mb=max_upload_mb,
            max_upload_bytes=int(max_upload_mb * 1024 * 1024),
            max_directory_entries=int(os.getenv("VOICE_AGENT_MAX_DIRECTORY_ENTRIES", "200")),
            max_event_message_chars=int(os.getenv("VOICE_AGENT_MAX_EVENT_MESSAGE_CHARS", "16000")),
            capabilities_report_path=capabilities_report_path,
            api_token=os.getenv("VOICE_AGENT_API_TOKEN", ""),
            db_path=db_path,
            pairing_file=pairing_file,
            pair_code_ttl_min=int(os.getenv("VOICE_AGENT_PAIR_CODE_TTL_MIN", "30")),
            pair_attempt_limit_per_min=int(os.getenv("VOICE_AGENT_PAIR_ATTEMPT_LIMIT_PER_MIN", "20")),
            uploads_root=uploads_root,
        )

    @staticmethod
    def _configured_default_executor() -> RunExecutorName:
        configured = os.getenv("VOICE_AGENT_DEFAULT_EXECUTOR", "codex").strip().lower() or "codex"
        if configured not in {"local", "codex", "claude"}:
            configured = "codex"
        return configured  # type: ignore[return-value]

    @staticmethod
    def _available_agent_executors(codex_binary: str, claude_binary: str) -> list[AgentExecutorName]:
        executors: list[AgentExecutorName] = []
        if _binary_available(codex_binary):
            executors.append("codex")
        if _binary_available(claude_binary):
            executors.append("claude")
        return executors

    @staticmethod
    def _resolve_default_executor(
        configured_default_executor: RunExecutorName,
        available_agents: list[AgentExecutorName],
    ) -> RunExecutorName:
        if configured_default_executor == "local":
            return "local"
        if configured_default_executor in available_agents:
            return configured_default_executor
        for candidate in ("codex", "claude"):
            if candidate in available_agents:
                return candidate  # type: ignore[return-value]
        return "local"

    def available_agent_executors(self) -> list[AgentExecutorName]:
        return self._available_agent_executors(self.codex_binary, self.claude_binary)

    def resolve_request_executor(self, requested: RunExecutorName | None) -> RunExecutorName:
        if requested is None:
            return self.default_executor
        return requested

    def is_agent_executor(self, executor: str) -> bool:
        return executor in {"codex", "claude"}

    def transcriber_ready(self, provider: str) -> bool:
        normalized = provider.strip().lower() or "openai"
        if normalized == "mock":
            return True
        if normalized == "openai":
            return bool(os.getenv("OPENAI_API_KEY", "").strip())
        return False

    def runtime_context_leak_markers(self) -> list[str]:
        return context_leak_markers(self.runtime_context)

    def build_runtime_agent_prompt(
        self,
        user_prompt: str,
        *,
        executor: AgentExecutorName,
        response_profile: ResponseProfile = "guided",
        profile_agents: str = "",
        profile_memory: str = "",
        memory_file_hint: str = ".mobaile/MEMORY.md",
    ) -> str:
        return build_agent_prompt(
            user_prompt,
            response_profile=response_profile,
            profile_agents=profile_agents,
            profile_memory=profile_memory,
            memory_file_hint=memory_file_hint,
            use_context=self.use_agent_context,
            runtime_context=self.runtime_context,
            global_agent_home=AGENT_HOME_HINTS[executor],
        )

    def evaluate_runtime_guardrails(self, user_prompt: str) -> tuple[str, str]:
        return evaluate_agent_guardrails(
            user_prompt,
            guardrails_mode=self.guardrails_mode,
            dangerous_confirm_token=self.dangerous_confirm_token,
        )

    def resolve_workdir(self, raw_path: str | None) -> Path:
        if raw_path and raw_path.strip():
            requested = Path(raw_path.strip()).expanduser()
            if not requested.is_absolute():
                requested = (self.default_workdir / requested).resolve()
            else:
                requested = requested.resolve()
            if self.workdir_root is not None and not self._is_relative_to(requested, self.workdir_root):
                raise ValueError(f"working_directory must stay inside {self.workdir_root}")
            requested.mkdir(parents=True, exist_ok=True)
            return requested
        return self.default_workdir

    def upload_session_dir(self, session_id: str) -> Path:
        return (self.uploads_root / _stable_key(session_id)).resolve()

    def is_path_allowed(self, path: Path) -> bool:
        if self.full_access_mode and self.allow_absolute_file_reads and not self.file_roots:
            return True
        return any(self._is_relative_to(path, root) for root in self.path_access_roots)

    def runtime_executor_descriptors(self) -> list[RuntimeExecutorDescriptor]:
        available_agents = set(self.available_agent_executors())
        descriptors = [
            RuntimeExecutorDescriptor(
                id="local",
                title=AGENT_TITLES["local"],
                kind="internal",
                available=True,
                default=self.default_executor == "local",
                internal_only=True,
            ),
            RuntimeExecutorDescriptor(
                id="codex",
                title=AGENT_TITLES["codex"],
                kind="agent",
                available="codex" in available_agents,
                default=self.default_executor == "codex",
                model=self.codex_model_override or None,
            ),
            RuntimeExecutorDescriptor(
                id="claude",
                title=AGENT_TITLES["claude"],
                kind="agent",
                available="claude" in available_agents,
                default=self.default_executor == "claude",
                model=self.claude_model_override or None,
            ),
        ]
        return descriptors

    def runtime_config_response(
        self,
        *,
        transcribe_provider: str,
        transcribe_ready: bool,
    ) -> RuntimeConfigResponse:
        return RuntimeConfigResponse(
            security_mode=self.security_mode,  # type: ignore[arg-type]
            default_executor=self.default_executor,
            available_executors=self.available_agent_executors(),
            executors=self.runtime_executor_descriptors(),
            transcribe_provider=transcribe_provider,
            transcribe_ready=transcribe_ready,
            codex_model=self.codex_model_override or None,
            claude_model=self.claude_model_override or None,
            workdir_root=str(self.workdir_root) if self.workdir_root is not None else None,
            allow_absolute_file_reads=self.allow_absolute_file_reads,
            file_roots=[str(root) for root in self.file_roots],
        )

    @staticmethod
    def _is_relative_to(path: Path, root: Path) -> bool:
        try:
            path.relative_to(root)
            return True
        except ValueError:
            return False
