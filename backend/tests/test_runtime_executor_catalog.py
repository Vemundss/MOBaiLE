from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from app.runtime_executor_catalog import (
    build_runtime_config_response,
    build_runtime_executor_descriptors,
)


def _fake_env() -> SimpleNamespace:
    return SimpleNamespace(
        default_executor="claude",
        codex_model_override="gpt-5.1",
        codex_model_options=("gpt-5.4-mini", "gpt-5.1"),
        codex_reasoning_effort_override="high",
        codex_reasoning_effort_options=("medium", "high", "xhigh"),
        claude_model_override="claude-sonnet-4-5",
        claude_model_options=("claude-opus-4", "claude-sonnet-4-5"),
        security_mode="safe",
        workdir_root=Path("/workspace"),
        allow_absolute_file_reads=False,
        file_roots=(Path("/workspace"), Path("/uploads")),
    )


def test_build_runtime_executor_descriptors_marks_defaults_and_models() -> None:
    env = _fake_env()

    descriptors = {item.id: item for item in build_runtime_executor_descriptors(env, available_agents={"codex"})}

    assert descriptors["local"].internal_only is True
    assert descriptors["codex"].available is True
    assert descriptors["codex"].settings[0].value == "gpt-5.1"
    assert descriptors["codex"].settings[2].id == "profile_agents"
    assert descriptors["codex"].settings[2].options == ["enabled", "disabled"]
    assert descriptors["codex"].settings[3].id == "profile_memory"
    assert descriptors["claude"].available is False
    assert descriptors["claude"].default is True


def test_build_runtime_config_response_projects_runtime_executor_state() -> None:
    env = _fake_env()

    response = build_runtime_config_response(
        env,
        available_executors=["codex", "claude"],
        transcribe_provider="mock",
        transcribe_ready=True,
        server_url="https://relay.example.com",
        server_urls=["https://relay.example.com", "http://100.64.0.1:8000"],
    )

    assert response.default_executor == "claude"
    assert response.available_executors == ["codex", "claude"]
    assert response.codex_reasoning_effort_options == ["medium", "high", "xhigh"]
    assert response.file_roots == ["/workspace", "/uploads"]
    assert response.server_urls == ["https://relay.example.com", "http://100.64.0.1:8000"]
