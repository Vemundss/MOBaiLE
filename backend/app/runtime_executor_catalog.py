from __future__ import annotations

from typing import TYPE_CHECKING

from app.models.schemas import (
    RuntimeConfigResponse,
    RuntimeExecutorDescriptor,
    RuntimeSettingDescriptor,
)
from app.runtime_settings_catalog import (
    PROFILE_AGENTS_SETTING_ID,
    PROFILE_CONTEXT_OPTIONS,
    PROFILE_MEMORY_SETTING_ID,
)

if TYPE_CHECKING:
    from app.models.schemas import AgentExecutorName
    from app.runtime_environment import RuntimeEnvironment


AGENT_TITLES = {
    "local": "Local fallback",
    "codex": "Codex",
    "claude": "Claude Code",
}


def _profile_context_settings() -> list[RuntimeSettingDescriptor]:
    return [
        RuntimeSettingDescriptor(
            id=PROFILE_AGENTS_SETTING_ID,
            title="Profile Instructions",
            kind="enum",
            allow_custom=False,
            value="enabled",
            options=list(PROFILE_CONTEXT_OPTIONS),
        ),
        RuntimeSettingDescriptor(
            id=PROFILE_MEMORY_SETTING_ID,
            title="Profile Memory",
            kind="enum",
            allow_custom=False,
            value="enabled",
            options=list(PROFILE_CONTEXT_OPTIONS),
        ),
    ]


def build_runtime_executor_descriptors(
    env: "RuntimeEnvironment",
    *,
    available_agents: set["AgentExecutorName"],
) -> list[RuntimeExecutorDescriptor]:
    return [
        RuntimeExecutorDescriptor(
            id="local",
            title=AGENT_TITLES["local"],
            kind="internal",
            available=True,
            default=env.default_executor == "local",
            internal_only=True,
        ),
        RuntimeExecutorDescriptor(
            id="codex",
            title=AGENT_TITLES["codex"],
            kind="agent",
            available="codex" in available_agents,
            default=env.default_executor == "codex",
            model=env.codex_model_override or None,
            settings=[
                RuntimeSettingDescriptor(
                    id="model",
                    title="Model",
                    kind="enum",
                    allow_custom=True,
                    value=env.codex_model_override or None,
                    options=list(env.codex_model_options),
                ),
                RuntimeSettingDescriptor(
                    id="reasoning_effort",
                    title="Reasoning Effort",
                    kind="enum",
                    allow_custom=False,
                    value=env.codex_reasoning_effort_override or None,
                    options=list(env.codex_reasoning_effort_options),
                ),
                *_profile_context_settings(),
            ],
        ),
        RuntimeExecutorDescriptor(
            id="claude",
            title=AGENT_TITLES["claude"],
            kind="agent",
            available="claude" in available_agents,
            default=env.default_executor == "claude",
            model=env.claude_model_override or None,
            settings=[
                RuntimeSettingDescriptor(
                    id="model",
                    title="Model",
                    kind="enum",
                    allow_custom=True,
                    value=env.claude_model_override or None,
                    options=list(env.claude_model_options),
                ),
                *_profile_context_settings(),
            ],
        ),
    ]


def build_runtime_config_response(
    env: "RuntimeEnvironment",
    *,
    available_executors: list["AgentExecutorName"],
    transcribe_provider: str,
    transcribe_ready: bool,
    server_url: str | None = None,
    server_urls: list[str] | None = None,
) -> RuntimeConfigResponse:
    return RuntimeConfigResponse(
        security_mode=env.security_mode,  # type: ignore[arg-type]
        default_executor=env.default_executor,
        available_executors=available_executors,
        executors=build_runtime_executor_descriptors(
            env,
            available_agents=set(available_executors),
        ),
        transcribe_provider=transcribe_provider,
        transcribe_ready=transcribe_ready,
        codex_model=env.codex_model_override or None,
        codex_model_options=list(env.codex_model_options),
        codex_reasoning_effort=env.codex_reasoning_effort_override or None,
        codex_reasoning_effort_options=list(env.codex_reasoning_effort_options),
        claude_model=env.claude_model_override or None,
        claude_model_options=list(env.claude_model_options),
        workdir_root=str(env.workdir_root) if env.workdir_root is not None else None,
        allow_absolute_file_reads=env.allow_absolute_file_reads,
        file_roots=[str(root) for root in env.file_roots],
        server_url=server_url,
        server_urls=server_urls or [],
    )
