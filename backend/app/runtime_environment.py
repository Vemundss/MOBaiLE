from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path

from app.agent_runtime import build_agent_prompt
from app.agent_runtime import context_leak_markers
from app.agent_runtime import evaluate_agent_guardrails
from app.models.schemas import AgentExecutorName
from app.models.schemas import CodexReasoningEffort
from app.models.schemas import ResponseProfile
from app.models.schemas import RunExecutorName
from app.models.schemas import RuntimeConfigResponse
from app.models.schemas import RuntimeExecutorDescriptor
from app.phone_access_mode import PhoneAccessMode
from app.runtime_executor_catalog import build_runtime_config_response
from app.runtime_executor_catalog import build_runtime_executor_descriptors
from app.runtime_environment_loader import available_agent_executors
from app.runtime_environment_loader import CLAUDE_MODEL_OPTIONS
from app.runtime_environment_loader import CODEX_MODEL_OPTIONS
from app.runtime_environment_loader import CODEX_REASONING_EFFORT_OPTIONS
from app.runtime_environment_loader import configured_default_executor
from app.runtime_environment_loader import load_agent_runtime_environment_settings
from app.runtime_environment_loader import load_profile_environment_settings
from app.runtime_environment_loader import load_service_environment_settings
from app.runtime_environment_loader import load_workspace_environment_settings
from app.runtime_environment_loader import resolve_default_executor
from app.runtime_environment_loader import stable_key

AGENT_HOME_HINTS: dict[AgentExecutorName, str] = {
    "codex": "~/.codex/*",
    "claude": "~/.claude/*",
}


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


@dataclass(frozen=True)
class RuntimeEnvironment:
    backend_root: Path
    host: str
    port: int
    public_server_url: str
    phone_access_mode: PhoneAccessMode
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
    codex_model_options: tuple[str, ...]
    codex_reasoning_effort_override: str
    codex_reasoning_effort_options: tuple[CodexReasoningEffort, ...]
    claude_model_override: str
    claude_model_options: tuple[str, ...]
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
        workspace = load_workspace_environment_settings(backend_root)
        agent_runtime = load_agent_runtime_environment_settings(backend_root)
        profile = load_profile_environment_settings(backend_root)
        service = load_service_environment_settings(backend_root)

        return cls(
            backend_root=backend_root,
            host=workspace.host,
            port=workspace.port,
            public_server_url=workspace.public_server_url,
            phone_access_mode=workspace.phone_access_mode,
            default_workdir=workspace.default_workdir,
            security_mode=workspace.security_mode,
            full_access_mode=workspace.full_access_mode,
            workdir_root=workspace.workdir_root,
            allow_absolute_file_reads=workspace.allow_absolute_file_reads,
            file_roots=workspace.file_roots,
            path_access_roots=workspace.path_access_roots,
            codex_binary=agent_runtime.codex_binary,
            claude_binary=agent_runtime.claude_binary,
            codex_home=agent_runtime.codex_home,
            codex_enable_web_search=agent_runtime.codex_enable_web_search,
            codex_model_override=agent_runtime.codex_model_override,
            codex_model_options=agent_runtime.codex_model_options,
            codex_reasoning_effort_override=agent_runtime.codex_reasoning_effort_override,
            codex_reasoning_effort_options=agent_runtime.codex_reasoning_effort_options,
            claude_model_override=agent_runtime.claude_model_override,
            claude_model_options=agent_runtime.claude_model_options,
            codex_timeout_sec=agent_runtime.codex_timeout_sec,
            claude_timeout_sec=agent_runtime.claude_timeout_sec,
            playwright_output_dir=agent_runtime.playwright_output_dir,
            playwright_user_data_dir=agent_runtime.playwright_user_data_dir,
            use_agent_context=agent_runtime.use_agent_context,
            runtime_context_file=agent_runtime.runtime_context_file,
            runtime_context=agent_runtime.runtime_context,
            guardrails_mode=agent_runtime.guardrails_mode,
            dangerous_confirm_token=agent_runtime.dangerous_confirm_token,
            configured_default_executor=agent_runtime.configured_default_executor,
            default_executor=agent_runtime.default_executor,
            profile_state_root=profile.profile_state_root,
            legacy_session_state_root=profile.legacy_session_state_root,
            profile_id=profile.profile_id,
            profile_agents_max_chars=profile.profile_agents_max_chars,
            profile_memory_max_chars=profile.profile_memory_max_chars,
            max_audio_mb=service.max_audio_mb,
            max_audio_bytes=service.max_audio_bytes,
            max_upload_mb=service.max_upload_mb,
            max_upload_bytes=service.max_upload_bytes,
            max_directory_entries=service.max_directory_entries,
            max_event_message_chars=service.max_event_message_chars,
            capabilities_report_path=service.capabilities_report_path,
            api_token=service.api_token,
            db_path=service.db_path,
            pairing_file=service.pairing_file,
            pair_code_ttl_min=service.pair_code_ttl_min,
            pair_attempt_limit_per_min=service.pair_attempt_limit_per_min,
            uploads_root=workspace.uploads_root,
        )

    @staticmethod
    def _configured_default_executor() -> RunExecutorName:
        return configured_default_executor()

    @staticmethod
    def _available_agent_executors(codex_binary: str, claude_binary: str) -> list[AgentExecutorName]:
        return available_agent_executors(codex_binary, claude_binary)

    @staticmethod
    def _resolve_default_executor(
        configured_default_executor: RunExecutorName,
        available_agents: list[AgentExecutorName],
    ) -> RunExecutorName:
        return resolve_default_executor(configured_default_executor, available_agents)

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
        return (self.uploads_root / stable_key(session_id)).resolve()

    def is_path_allowed(self, path: Path) -> bool:
        if self.full_access_mode and self.allow_absolute_file_reads and not self.file_roots:
            return True
        return any(self._is_relative_to(path, root) for root in self.path_access_roots)

    def runtime_executor_descriptors(self) -> list[RuntimeExecutorDescriptor]:
        return build_runtime_executor_descriptors(
            self,
            available_agents=set(self.available_agent_executors()),
        )

    def runtime_config_response(
        self,
        *,
        transcribe_provider: str,
        transcribe_ready: bool,
        server_url: str | None = None,
        server_urls: list[str] | None = None,
    ) -> RuntimeConfigResponse:
        available_executors = self.available_agent_executors()
        return build_runtime_config_response(
            self,
            available_executors=available_executors,
            transcribe_provider=transcribe_provider,
            transcribe_ready=transcribe_ready,
            server_url=server_url,
            server_urls=server_urls,
        )

    @staticmethod
    def _is_relative_to(path: Path, root: Path) -> bool:
        try:
            path.relative_to(root)
            return True
        except ValueError:
            return False
