from __future__ import annotations

import json
from pathlib import Path

from app.runtime_environment_loader import (
    load_agent_runtime_environment_settings,
    load_service_environment_settings,
    load_workspace_environment_settings,
)

from .api_test_support import write_executable


def test_load_workspace_environment_settings_defaults_to_safe_upload_root(monkeypatch, tmp_path: Path) -> None:
    default_workdir = (tmp_path / "workspace").resolve()
    monkeypatch.setenv("VOICE_AGENT_DEFAULT_WORKDIR", str(default_workdir))
    monkeypatch.delenv("VOICE_AGENT_SECURITY_MODE", raising=False)
    monkeypatch.delenv("VOICE_AGENT_WORKDIR_ROOT", raising=False)
    monkeypatch.delenv("VOICE_AGENT_FILE_ROOTS", raising=False)
    monkeypatch.delenv("VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS", raising=False)

    settings = load_workspace_environment_settings(tmp_path)

    assert settings.security_mode == "safe"
    assert settings.full_access_mode is False
    assert settings.default_workdir == default_workdir
    assert settings.workdir_root == default_workdir
    assert settings.allow_absolute_file_reads is False
    assert settings.file_roots == (default_workdir, settings.uploads_root)
    assert settings.path_access_roots == (default_workdir, settings.uploads_root)


def test_load_agent_runtime_environment_settings_filters_options_and_resolves_executor(
    monkeypatch,
    tmp_path: Path,
) -> None:
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("", encoding="utf-8")
    context_file = tmp_path / "RUNTIME_CONTEXT.md"
    context_file.write_text("runtime context", encoding="utf-8")

    monkeypatch.setenv("VOICE_AGENT_CODEX_BINARY", str(fake_codex))
    monkeypatch.setenv("VOICE_AGENT_CLAUDE_BINARY", "missing-claude")
    monkeypatch.setenv("VOICE_AGENT_DEFAULT_EXECUTOR", "claude")
    monkeypatch.setenv("VOICE_AGENT_CODEX_HOME", "config/codex-home")
    monkeypatch.setenv("VOICE_AGENT_CODEX_REASONING_EFFORT", "turbo")
    monkeypatch.setenv("VOICE_AGENT_CODEX_REASONING_EFFORT_OPTIONS", "high,medium,turbo,high")
    monkeypatch.setenv("VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR", "playwright-output")
    monkeypatch.setenv("VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR", "playwright-profile")
    monkeypatch.setenv("VOICE_AGENT_RUNTIME_CONTEXT_FILE", str(context_file))

    settings = load_agent_runtime_environment_settings(tmp_path)

    assert settings.default_executor == "codex"
    assert settings.codex_home == (tmp_path / "config" / "codex-home").resolve()
    assert settings.codex_reasoning_effort_override == ""
    assert settings.codex_reasoning_effort_options == ("high", "medium", "minimal", "low", "xhigh")
    assert settings.playwright_output_dir == (tmp_path / "playwright-output").resolve()
    assert settings.playwright_user_data_dir == (tmp_path / "playwright-profile").resolve()
    assert settings.runtime_context == "runtime context"


def test_load_agent_runtime_environment_settings_reads_compatible_codex_model_cache(
    monkeypatch,
    tmp_path: Path,
) -> None:
    fake_codex = write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "echo 'codex-cli 0.124.0'\n",
    )
    codex_home = tmp_path / "codex-home"
    codex_home.mkdir()
    _write_codex_models_cache(
        codex_home,
        client_version="0.124.0",
        models=[
            {"slug": "gpt-5.4", "visibility": "list"},
            {"slug": "gpt-5.5", "visibility": "list"},
            {"slug": "codex-auto-review", "visibility": "hide"},
        ],
    )

    monkeypatch.setenv("VOICE_AGENT_CODEX_MODEL_DISCOVERY", "auto")
    monkeypatch.setenv("VOICE_AGENT_CODEX_BINARY", str(fake_codex))
    monkeypatch.setenv("VOICE_AGENT_CODEX_HOME", str(codex_home))
    monkeypatch.delenv("VOICE_AGENT_CODEX_MODEL", raising=False)
    monkeypatch.delenv("VOICE_AGENT_CODEX_MODEL_OPTIONS", raising=False)

    settings = load_agent_runtime_environment_settings(tmp_path)

    assert settings.codex_model_override == "gpt-5.4"
    assert settings.codex_model_options[:2] == ("gpt-5.4", "gpt-5.5")
    assert "codex-auto-review" not in settings.codex_model_options


def test_load_agent_runtime_environment_settings_ignores_newer_codex_model_cache(
    monkeypatch,
    tmp_path: Path,
) -> None:
    fake_codex = write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "echo 'codex-cli 0.118.0'\n",
    )
    codex_home = tmp_path / "codex-home"
    codex_home.mkdir()
    _write_codex_models_cache(
        codex_home,
        client_version="0.124.0",
        models=[
            {"slug": "gpt-5.4", "visibility": "list"},
            {"slug": "gpt-5.5", "visibility": "list"},
        ],
    )

    monkeypatch.setenv("VOICE_AGENT_CODEX_MODEL_DISCOVERY", "auto")
    monkeypatch.setenv("VOICE_AGENT_CODEX_BINARY", str(fake_codex))
    monkeypatch.setenv("VOICE_AGENT_CODEX_HOME", str(codex_home))
    monkeypatch.delenv("VOICE_AGENT_CODEX_MODEL", raising=False)
    monkeypatch.delenv("VOICE_AGENT_CODEX_MODEL_OPTIONS", raising=False)

    settings = load_agent_runtime_environment_settings(tmp_path)

    assert settings.codex_model_override == "gpt-5.4"
    assert settings.codex_model_options == ("gpt-5.4", "gpt-5.4-mini", "gpt-5.1")


def test_load_agent_runtime_environment_settings_adds_version_gated_codex_models(
    monkeypatch,
    tmp_path: Path,
) -> None:
    fake_codex = write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "echo 'codex-cli 0.125.0'\n",
    )
    codex_home = tmp_path / "codex-home"
    codex_home.mkdir()

    monkeypatch.setenv("VOICE_AGENT_CODEX_MODEL_DISCOVERY", "auto")
    monkeypatch.setenv("VOICE_AGENT_CODEX_BINARY", str(fake_codex))
    monkeypatch.setenv("VOICE_AGENT_CODEX_HOME", str(codex_home))
    monkeypatch.delenv("VOICE_AGENT_CODEX_MODEL", raising=False)
    monkeypatch.delenv("VOICE_AGENT_CODEX_MODEL_OPTIONS", raising=False)

    settings = load_agent_runtime_environment_settings(tmp_path)

    assert settings.codex_model_override == "gpt-5.4"
    assert settings.codex_model_options == ("gpt-5.4", "gpt-5.4-mini", "gpt-5.1", "gpt-5.5")


def test_load_service_environment_settings_computes_byte_limits(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("VOICE_AGENT_MAX_AUDIO_MB", "1.5")
    monkeypatch.setenv("VOICE_AGENT_MAX_UPLOAD_MB", "0.25")
    monkeypatch.setenv("VOICE_AGENT_PAIR_CODE_TTL_MIN", "45")
    monkeypatch.setenv("VOICE_AGENT_PAIR_ATTEMPT_LIMIT_PER_MIN", "7")
    monkeypatch.delenv("VOICE_AGENT_CAPABILITIES_REPORT_PATH", raising=False)
    monkeypatch.delenv("VOICE_AGENT_DB_PATH", raising=False)
    monkeypatch.delenv("VOICE_AGENT_PAIRING_FILE", raising=False)

    settings = load_service_environment_settings(tmp_path)

    assert settings.max_audio_bytes == int(1.5 * 1024 * 1024)
    assert settings.max_upload_bytes == int(0.25 * 1024 * 1024)
    assert settings.capabilities_report_path == (tmp_path / "data" / "capabilities.json").resolve()
    assert settings.db_path == (tmp_path / "data" / "runs.db")
    assert settings.pairing_file == (tmp_path / "pairing.json")
    assert settings.pair_code_ttl_min == 45
    assert settings.pair_attempt_limit_per_min == 7


def _write_codex_models_cache(
    codex_home: Path,
    *,
    client_version: str,
    models: list[dict[str, str]],
) -> None:
    (codex_home / "models_cache.json").write_text(
        json.dumps(
            {
                "client_version": client_version,
                "models": models,
            }
        ),
        encoding="utf-8",
    )
