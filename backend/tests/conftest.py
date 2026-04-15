from __future__ import annotations

import importlib
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def backend_test_env(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_DB_PATH", str(tmp_path / "runs.db"))
    monkeypatch.setenv(
        "VOICE_AGENT_CAPABILITIES_REPORT_PATH",
        str(tmp_path / "capabilities.json"),
    )


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
