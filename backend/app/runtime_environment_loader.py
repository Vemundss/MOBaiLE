from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from app.agent_runtime import load_runtime_context
from app.host_tools import binary_available
from app.models.schemas import AgentExecutorName, CodexReasoningEffort, RunExecutorName
from app.pairing_url_policy import validate_public_server_url
from app.phone_access_mode import PhoneAccessMode, normalize_phone_access_mode

CODEX_MODEL_OPTIONS = ("gpt-5.4", "gpt-5.4-mini", "gpt-5.1")
CODEX_VERSION_GATED_MODEL_OPTIONS: tuple[tuple[str, tuple[int, int, int]], ...] = (
    ("gpt-5.5", (0, 125, 0)),
)
DEFAULT_CODEX_MODEL = CODEX_MODEL_OPTIONS[0]
CLAUDE_MODEL_OPTIONS = ("claude-sonnet-4-5",)
CODEX_REASONING_EFFORT_OPTIONS: tuple[CodexReasoningEffort, ...] = ("minimal", "low", "medium", "high", "xhigh")

_FALSEY_ENV_VALUES = {"0", "false", "no", "off"}
_TRUTHY_ENV_VALUES = {"1", "true", "yes", "on"}
_CODEX_MODEL_AUTO_VALUES = {"", "auto", "backend-default", "default"}
_CODEX_MODELS_CACHE_FILENAME = "models_cache.json"
_CODEX_VERSION_TIMEOUT_SEC = 2.0


@dataclass(frozen=True)
class WorkspaceEnvironmentSettings:
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
    uploads_root: Path


@dataclass(frozen=True)
class AgentRuntimeEnvironmentSettings:
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


@dataclass(frozen=True)
class ProfileEnvironmentSettings:
    profile_state_root: Path
    legacy_session_state_root: Path
    profile_id: str
    profile_agents_max_chars: int
    profile_memory_max_chars: int


@dataclass(frozen=True)
class ServiceEnvironmentSettings:
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


def resolve_path_value(raw_value: str, *, base_dir: Path) -> Path:
    path = Path(raw_value).expanduser()
    if path.is_absolute():
        return path.resolve()
    return (base_dir / path).resolve()


def stable_key(raw_value: str) -> str:
    cleaned = "".join(char if char.isalnum() or char in "._-" else "_" for char in raw_value.strip())[:120]
    return cleaned or "default"


def configured_default_executor() -> RunExecutorName:
    configured = os.getenv("VOICE_AGENT_DEFAULT_EXECUTOR", "codex").strip().lower() or "codex"
    if configured not in {"local", "codex", "claude"}:
        configured = "codex"
    return configured  # type: ignore[return-value]


def available_agent_executors(codex_binary: str, claude_binary: str) -> list[AgentExecutorName]:
    executors: list[AgentExecutorName] = []
    if binary_available(codex_binary):
        executors.append("codex")
    if binary_available(claude_binary):
        executors.append("claude")
    return executors


def resolve_default_executor(
    configured_executor: RunExecutorName,
    available_agents: list[AgentExecutorName],
) -> RunExecutorName:
    if configured_executor == "local":
        return "local"
    if configured_executor in available_agents:
        return configured_executor
    for candidate in ("codex", "claude"):
        if candidate in available_agents:
            return candidate  # type: ignore[return-value]
    return "local"


def load_workspace_environment_settings(backend_root: Path) -> WorkspaceEnvironmentSettings:
    host = os.getenv("VOICE_AGENT_HOST", "127.0.0.1").strip() or "127.0.0.1"
    try:
        port = int(os.getenv("VOICE_AGENT_PORT", "8000").strip() or "8000")
    except ValueError:
        port = 8000
    public_server_url = validate_public_server_url(os.getenv("VOICE_AGENT_PUBLIC_SERVER_URL", "").strip())
    phone_access_mode = _read_phone_access_mode_env()
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

    allow_absolute_file_reads = _read_truthy_env(
        "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS",
        default=full_access_mode,
    )

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
    uploads_root = ((workdir_root or default_workdir) / ".mobaile_uploads").resolve()
    uploads_root.mkdir(parents=True, exist_ok=True)
    if uploads_root not in path_access_roots:
        path_access_roots.append(uploads_root)
    if uploads_root not in file_roots and (explicit_file_roots or not (full_access_mode and allow_absolute_file_reads)):
        file_roots.append(uploads_root)

    return WorkspaceEnvironmentSettings(
        host=host,
        port=port,
        public_server_url=public_server_url,
        phone_access_mode=phone_access_mode,
        default_workdir=default_workdir,
        security_mode=security_mode,
        full_access_mode=full_access_mode,
        workdir_root=workdir_root,
        allow_absolute_file_reads=allow_absolute_file_reads,
        file_roots=tuple(file_roots),
        path_access_roots=tuple(path_access_roots),
        uploads_root=uploads_root,
    )


def load_agent_runtime_environment_settings(backend_root: Path) -> AgentRuntimeEnvironmentSettings:
    codex_binary = os.getenv("VOICE_AGENT_CODEX_BINARY", "codex").strip() or "codex"
    claude_binary = os.getenv("VOICE_AGENT_CLAUDE_BINARY", "claude").strip() or "claude"
    codex_home = resolve_path_value(
        os.getenv(
            "VOICE_AGENT_CODEX_HOME",
            os.getenv("CODEX_HOME", str(Path.home() / ".codex")),
        ).strip()
        or str(Path.home() / ".codex"),
        base_dir=backend_root,
    )
    codex_enable_web_search = _read_enabled_env("VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH", default=True)
    codex_timeout_sec = _read_non_negative_int_env("VOICE_AGENT_CODEX_TIMEOUT_SEC", 900)
    codex_cli_version = _codex_cli_version(codex_binary)
    discovered_codex_model_options = discover_codex_model_options(
        codex_binary=codex_binary,
        codex_home=codex_home,
        installed_version=codex_cli_version,
    )
    version_gated_codex_model_options = _version_gated_codex_model_options(codex_cli_version)
    codex_model_options = tuple(
        _runtime_option_values(
            os.getenv("VOICE_AGENT_CODEX_MODEL_OPTIONS"),
            (*discovered_codex_model_options, *CODEX_MODEL_OPTIONS, *version_gated_codex_model_options),
        )
    )
    codex_model_override = _resolve_codex_model_override(
        os.getenv("VOICE_AGENT_CODEX_MODEL", "auto"),
        codex_model_options,
    )
    codex_reasoning_effort_override = os.getenv("VOICE_AGENT_CODEX_REASONING_EFFORT", "").strip().lower()
    if codex_reasoning_effort_override not in CODEX_REASONING_EFFORT_OPTIONS:
        codex_reasoning_effort_override = ""
    codex_reasoning_effort_options = tuple(
        _runtime_option_values(
            os.getenv("VOICE_AGENT_CODEX_REASONING_EFFORT_OPTIONS"),
            CODEX_REASONING_EFFORT_OPTIONS,
            normalize=lambda value: value.strip().lower(),
            allowed=lambda value: value in CODEX_REASONING_EFFORT_OPTIONS,
        )
    )
    claude_model_override = os.getenv("VOICE_AGENT_CLAUDE_MODEL", "").strip()
    claude_model_options = tuple(
        _runtime_option_values(
            os.getenv("VOICE_AGENT_CLAUDE_MODEL_OPTIONS"),
            CLAUDE_MODEL_OPTIONS,
        )
    )
    claude_timeout_sec = _read_non_negative_int_env("VOICE_AGENT_CLAUDE_TIMEOUT_SEC", codex_timeout_sec)
    playwright_output_dir = resolve_path_value(
        os.getenv("VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR", "data/playwright").strip() or "data/playwright",
        base_dir=backend_root,
    )
    playwright_user_data_dir = resolve_path_value(
        os.getenv("VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR", "data/playwright-profile").strip()
        or "data/playwright-profile",
        base_dir=backend_root,
    )
    playwright_output_dir.mkdir(parents=True, exist_ok=True)
    playwright_user_data_dir.mkdir(parents=True, exist_ok=True)

    use_agent_context = _read_enabled_env(
        "VOICE_AGENT_USE_RUNTIME_CONTEXT",
        default=_read_enabled_env("VOICE_AGENT_CODEX_USE_CONTEXT", default=True),
    )
    runtime_context_file = (
        os.getenv("VOICE_AGENT_RUNTIME_CONTEXT_FILE", "").strip()
        or os.getenv("VOICE_AGENT_CODEX_CONTEXT_FILE", "").strip()
        or "../.mobaile/runtime/RUNTIME_CONTEXT.md"
    )
    runtime_context = load_runtime_context(runtime_context_file, backend_root)
    guardrails_mode = os.getenv("VOICE_AGENT_CODEX_GUARDRAILS", "warn").strip().lower()
    dangerous_confirm_token = os.getenv(
        "VOICE_AGENT_CODEX_DANGEROUS_CONFIRM_TOKEN", "[allow-dangerous]"
    ).strip()

    configured_executor = configured_default_executor()
    available_agents = available_agent_executors(codex_binary, claude_binary)
    default_executor = resolve_default_executor(configured_executor, available_agents)

    return AgentRuntimeEnvironmentSettings(
        codex_binary=codex_binary,
        claude_binary=claude_binary,
        codex_home=codex_home,
        codex_enable_web_search=codex_enable_web_search,
        codex_model_override=codex_model_override,
        codex_model_options=codex_model_options,
        codex_reasoning_effort_override=codex_reasoning_effort_override,
        codex_reasoning_effort_options=codex_reasoning_effort_options,
        claude_model_override=claude_model_override,
        claude_model_options=claude_model_options,
        codex_timeout_sec=codex_timeout_sec,
        claude_timeout_sec=claude_timeout_sec,
        playwright_output_dir=playwright_output_dir,
        playwright_user_data_dir=playwright_user_data_dir,
        use_agent_context=use_agent_context,
        runtime_context_file=runtime_context_file,
        runtime_context=runtime_context,
        guardrails_mode=guardrails_mode,
        dangerous_confirm_token=dangerous_confirm_token,
        configured_default_executor=configured_executor,
        default_executor=default_executor,
    )


def load_profile_environment_settings(backend_root: Path) -> ProfileEnvironmentSettings:
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

    return ProfileEnvironmentSettings(
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
    )


def load_service_environment_settings(backend_root: Path) -> ServiceEnvironmentSettings:
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

    return ServiceEnvironmentSettings(
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
    )


def _read_non_negative_int_env(name: str, default: int) -> int:
    raw_value = os.getenv(name, str(default)).strip()
    try:
        parsed = int(raw_value)
    except ValueError:
        return default
    return max(0, parsed)


def _read_phone_access_mode_env() -> PhoneAccessMode:
    return normalize_phone_access_mode(os.getenv("VOICE_AGENT_PHONE_ACCESS_MODE", "tailscale"))


def _runtime_option_values(
    raw_value: str | None,
    fallback_values: tuple[str, ...],
    *,
    normalize: Callable[[str], str] = lambda value: value.strip(),
    allowed: Callable[[str], bool] | None = None,
) -> list[str]:
    options: list[str] = []
    seen: set[str] = set()

    def add(raw_item: str) -> None:
        normalized = normalize(raw_item)
        if not normalized:
            return
        if allowed is not None and not allowed(normalized):
            return
        key = normalized.casefold()
        if key in seen:
            return
        seen.add(key)
        options.append(normalized)

    if raw_value:
        for item in raw_value.split(","):
            add(item)
    for item in fallback_values:
        add(item)
    return options


def discover_codex_model_options(
    *,
    codex_binary: str,
    codex_home: Path,
    installed_version: tuple[int, int, int] | None = None,
) -> tuple[str, ...]:
    if not _read_enabled_env("VOICE_AGENT_CODEX_MODEL_DISCOVERY", default=True):
        return ()

    cache_path = codex_home / _CODEX_MODELS_CACHE_FILENAME
    try:
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ()
    if not isinstance(payload, dict):
        return ()

    cache_version = _parse_semver(payload.get("client_version"))
    installed_version = installed_version if installed_version is not None else _codex_cli_version(codex_binary)
    if cache_version is None or installed_version is None or cache_version > installed_version:
        return ()

    raw_models = payload.get("models")
    if not isinstance(raw_models, list):
        return ()

    options: list[str] = []
    seen: set[str] = set()
    for raw_model in raw_models:
        if not isinstance(raw_model, dict):
            continue
        if str(raw_model.get("visibility", "")).strip().lower() != "list":
            continue
        slug = str(raw_model.get("slug", "")).strip()
        if not slug:
            continue
        key = slug.casefold()
        if key in seen:
            continue
        seen.add(key)
        options.append(slug)
    return tuple(options)


def _resolve_codex_model_override(raw_value: str | None, options: tuple[str, ...]) -> str:
    normalized = (raw_value or "").strip()
    if normalized.casefold() in _CODEX_MODEL_AUTO_VALUES:
        return options[0] if options else DEFAULT_CODEX_MODEL
    return normalized


def _version_gated_codex_model_options(installed_version: tuple[int, int, int] | None) -> tuple[str, ...]:
    if installed_version is None:
        return ()
    return tuple(
        model
        for model, minimum_version in CODEX_VERSION_GATED_MODEL_OPTIONS
        if installed_version >= minimum_version
    )


def _codex_cli_version(codex_binary: str) -> tuple[int, int, int] | None:
    try:
        result = subprocess.run(
            [codex_binary, "--version"],
            capture_output=True,
            check=False,
            text=True,
            timeout=_CODEX_VERSION_TIMEOUT_SEC,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return _parse_semver(f"{result.stdout}\n{result.stderr}")


def _parse_semver(value: object) -> tuple[int, int, int] | None:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", str(value or ""))
    if match is None:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def _read_enabled_env(name: str, *, default: bool) -> bool:
    fallback = "true" if default else "false"
    return os.getenv(name, fallback).strip().lower() not in _FALSEY_ENV_VALUES


def _read_truthy_env(name: str, *, default: bool) -> bool:
    fallback = "true" if default else "false"
    return os.getenv(name, fallback).strip().lower() in _TRUTHY_ENV_VALUES
