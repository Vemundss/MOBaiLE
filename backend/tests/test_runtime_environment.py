from __future__ import annotations

from pathlib import Path

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
