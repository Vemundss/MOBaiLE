from __future__ import annotations

import importlib
import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def backend_test_env(monkeypatch, tmp_path: Path, tmp_path_factory: pytest.TempPathFactory):
    env_root = tmp_path_factory.mktemp("backend-env")
    workspace = env_root / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    fake_bin = env_root / "bin"
    fake_bin.mkdir(parents=True, exist_ok=True)
    for binary in ("codex", "claude"):
        tool = fake_bin / binary
        tool.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        tool.chmod(0o755)

    monkeypatch.setenv("PATH", f"{fake_bin}:{os.environ.get('PATH', '')}")
    monkeypatch.setenv("VOICE_AGENT_DB_PATH", str(tmp_path / "runs.db"))
    monkeypatch.setenv(
        "VOICE_AGENT_CAPABILITIES_REPORT_PATH",
        str(tmp_path / "capabilities.json"),
    )
    monkeypatch.setenv("VOICE_AGENT_DEFAULT_WORKDIR", str(workspace))
    monkeypatch.setenv("VOICE_AGENT_SECURITY_MODE", "safe")
    monkeypatch.setenv("VOICE_AGENT_HOST", "127.0.0.1")
    monkeypatch.setenv("VOICE_AGENT_PHONE_ACCESS_MODE", "tailscale")
    monkeypatch.setenv("VOICE_AGENT_PUBLIC_SERVER_URL", "")
    monkeypatch.setenv("VOICE_AGENT_CODEX_BINARY", "codex")
    monkeypatch.setenv("VOICE_AGENT_CLAUDE_BINARY", "claude")
    monkeypatch.delenv("VOICE_AGENT_WORKDIR_ROOT", raising=False)
    monkeypatch.delenv("VOICE_AGENT_FILE_ROOTS", raising=False)
    monkeypatch.delenv("VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS", raising=False)
    monkeypatch.setenv("VOICE_AGENT_CODEX_MODEL_DISCOVERY", "off")


@pytest.fixture
def make_client(monkeypatch, tmp_path: Path):
    def _make_client(
        *,
        provider: str = "mock",
        api_token: str = "test-token",
        openai_api_key: str = "",
        extra_env: dict[str, str] | None = None,
    ):
        monkeypatch.setenv("VOICE_AGENT_API_TOKEN", api_token)
        monkeypatch.setenv("VOICE_AGENT_TRANSCRIBE_PROVIDER", provider)
        monkeypatch.setenv("OPENAI_API_KEY", openai_api_key)
        if extra_env:
            for key, value in extra_env.items():
                monkeypatch.setenv(key, value)
        module = importlib.import_module("app.main")
        module = importlib.reload(module)
        return TestClient(module.app), api_token

    return _make_client
