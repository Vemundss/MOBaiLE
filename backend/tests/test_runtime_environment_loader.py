from __future__ import annotations

from pathlib import Path

from app.runtime_environment_loader import load_agent_runtime_environment_settings
from app.runtime_environment_loader import load_service_environment_settings
from app.runtime_environment_loader import load_workspace_environment_settings


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
    context_file = tmp_path / "AGENT_CONTEXT.md"
    context_file.write_text("runtime context", encoding="utf-8")

    monkeypatch.setenv("VOICE_AGENT_CODEX_BINARY", str(fake_codex))
    monkeypatch.setenv("VOICE_AGENT_CLAUDE_BINARY", "missing-claude")
    monkeypatch.setenv("VOICE_AGENT_DEFAULT_EXECUTOR", "claude")
    monkeypatch.setenv("VOICE_AGENT_CODEX_HOME", "config/codex-home")
    monkeypatch.setenv("VOICE_AGENT_CODEX_REASONING_EFFORT", "turbo")
    monkeypatch.setenv("VOICE_AGENT_CODEX_REASONING_EFFORT_OPTIONS", "high,medium,turbo,high")
    monkeypatch.setenv("VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR", "playwright-output")
    monkeypatch.setenv("VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR", "playwright-profile")
    monkeypatch.setenv("VOICE_AGENT_CODEX_CONTEXT_FILE", str(context_file))

    settings = load_agent_runtime_environment_settings(tmp_path)

    assert settings.default_executor == "codex"
    assert settings.codex_home == (tmp_path / "config" / "codex-home").resolve()
    assert settings.codex_reasoning_effort_override == ""
    assert settings.codex_reasoning_effort_options == ("high", "medium", "minimal", "low", "xhigh")
    assert settings.playwright_output_dir == (tmp_path / "playwright-output").resolve()
    assert settings.playwright_user_data_dir == (tmp_path / "playwright-profile").resolve()
    assert settings.runtime_context == "runtime context"


def test_load_service_environment_settings_computes_byte_limits(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("VOICE_AGENT_MAX_AUDIO_MB", "1.5")
    monkeypatch.setenv("VOICE_AGENT_MAX_UPLOAD_MB", "0.25")
    monkeypatch.setenv("VOICE_AGENT_PAIR_CODE_TTL_MIN", "45")
    monkeypatch.setenv("VOICE_AGENT_PAIR_ATTEMPT_LIMIT_PER_MIN", "7")

    settings = load_service_environment_settings(tmp_path)

    assert settings.max_audio_bytes == int(1.5 * 1024 * 1024)
    assert settings.max_upload_bytes == int(0.25 * 1024 * 1024)
    assert settings.capabilities_report_path == (tmp_path / "data" / "capabilities.json").resolve()
    assert settings.db_path == (tmp_path / "data" / "runs.db")
    assert settings.pairing_file == (tmp_path / "pairing.json")
    assert settings.pair_code_ttl_min == 45
    assert settings.pair_attempt_limit_per_min == 7
