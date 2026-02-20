from __future__ import annotations

import importlib
import time
from io import BytesIO
from pathlib import Path

from fastapi.testclient import TestClient


def make_client(
    monkeypatch,
    tmp_path: Path,
    *,
    provider: str = "mock",
    api_token: str = "test-token",
    openai_api_key: str = "",
):
    monkeypatch.setenv("VOICE_AGENT_API_TOKEN", api_token)
    monkeypatch.setenv("VOICE_AGENT_TRANSCRIBE_PROVIDER", provider)
    monkeypatch.setenv("OPENAI_API_KEY", openai_api_key)
    monkeypatch.setenv("VOICE_AGENT_DB_PATH", str(tmp_path / "runs.db"))
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    return TestClient(module.app), api_token


def test_auth_required(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path)
    assert client.get("/health").status_code == 200
    assert client.post("/v1/utterances", json={}).status_code == 401
    assert (
        client.post(
            "/v1/utterances",
            headers={"Authorization": f"Bearer {token}"},
            json={},
        ).status_code
        == 422
    )


def test_local_utterance_flow(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path)
    resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "t1",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert resp.status_code == 200
    run_id = resp.json()["run_id"]

    final = None
    for _ in range(30):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        assert run_resp.status_code == 200
        payload = run_resp.json()
        final = payload["status"]
        if final != "running":
            break
        time.sleep(0.05)
    assert final == "completed"


def test_audio_mock_flow(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
    resp = client.post(
        "/v1/audio",
        headers={"Authorization": f"Bearer {token}"},
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={
            "session_id": "audio1",
            "executor": "local",
            "transcript_hint": "create a hello python script and run it",
        },
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["transcript_text"] == "create a hello python script and run it"
    assert payload["status"] == "accepted"


def test_audio_openai_missing_key(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="openai", openai_api_key="")
    resp = client.post(
        "/v1/audio",
        headers={"Authorization": f"Bearer {token}"},
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={"session_id": "audio2", "executor": "local"},
    )
    assert resp.status_code == 502
    assert "OPENAI_API_KEY is not set" in resp.json()["detail"]
