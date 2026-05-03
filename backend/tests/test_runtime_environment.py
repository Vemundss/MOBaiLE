from __future__ import annotations

from pathlib import Path

from app.agent_runtime import build_agent_prompt, load_runtime_context
from app.runtime_environment import RuntimeEnvironment


def test_runtime_environment_autonomy_paths(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_API_TOKEN", "test-token")
    monkeypatch.setenv("VOICE_AGENT_CODEX_HOME", str(tmp_path / "codex-home"))
    monkeypatch.setenv("VOICE_AGENT_PLAYWRIGHT_OUTPUT_DIR", "data/playwright-out")
    monkeypatch.setenv("VOICE_AGENT_PLAYWRIGHT_USER_DATA_DIR", str(tmp_path / "playwright-profile"))
    monkeypatch.setenv("VOICE_AGENT_CODEX_ENABLE_WEB_SEARCH", "true")

    env = RuntimeEnvironment.from_env(tmp_path)

    assert env.codex_home == (tmp_path / "codex-home").resolve()
    assert env.playwright_output_dir == (tmp_path / "data" / "playwright-out").resolve()
    assert env.playwright_user_data_dir == (tmp_path / "playwright-profile").resolve()
    assert env.codex_enable_web_search is True


def test_runtime_environment_defaults_to_safe_and_unbounded_agent_timeout(monkeypatch, tmp_path: Path):
    default_workdir = (tmp_path / "workspace").resolve()
    monkeypatch.setenv("VOICE_AGENT_DEFAULT_WORKDIR", str(default_workdir))
    monkeypatch.delenv("VOICE_AGENT_SECURITY_MODE", raising=False)
    monkeypatch.delenv("VOICE_AGENT_WORKDIR_ROOT", raising=False)
    monkeypatch.delenv("VOICE_AGENT_FILE_ROOTS", raising=False)
    monkeypatch.delenv("VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS", raising=False)
    monkeypatch.delenv("VOICE_AGENT_CODEX_TIMEOUT_SEC", raising=False)
    monkeypatch.delenv("VOICE_AGENT_CLAUDE_TIMEOUT_SEC", raising=False)

    env = RuntimeEnvironment.from_env(tmp_path)

    assert env.security_mode == "safe"
    assert env.full_access_mode is False
    assert env.default_workdir == default_workdir
    assert env.workdir_root == default_workdir
    assert env.allow_absolute_file_reads is False
    assert env.file_roots == (default_workdir, env.uploads_root)
    assert env.codex_model_override == "gpt-5.4"
    assert env.codex_timeout_sec == 0
    assert env.claude_timeout_sec == 0


def test_runtime_environment_reads_phone_access_mode(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_PHONE_ACCESS_MODE", "wifi")

    env = RuntimeEnvironment.from_env(tmp_path)

    assert env.phone_access_mode == "wifi"


def test_load_runtime_context_falls_back_to_hidden_mobaile_dir(tmp_path: Path):
    hidden = tmp_path / ".mobaile" / "runtime" / "RUNTIME_CONTEXT.md"
    hidden.parent.mkdir(parents=True, exist_ok=True)
    hidden.write_text("hidden runtime context", encoding="utf-8")

    loaded = load_runtime_context("RUNTIME_CONTEXT.md", tmp_path / "backend")

    assert loaded == "hidden runtime context"


def test_guided_agent_prompt_includes_phone_feedback_guidance() -> None:
    prompt = build_agent_prompt(
        "Fix the bug",
        response_profile="guided",
        runtime_context="Runtime notes",
    )

    assert "Phone UX feedback guidance:" in prompt
    assert "Backend activity events are the source of truth for progress in the phone UI." in prompt
    assert "planning, executing, blocked, or summarizing" in prompt
    assert "Keep that note concise and non-repetitive" in prompt


def test_minimal_agent_prompt_omits_phone_feedback_guidance() -> None:
    prompt = build_agent_prompt(
        "Fix the bug",
        response_profile="minimal",
        runtime_context="Runtime notes",
    )

    assert "Phone UX feedback guidance:" not in prompt
