from __future__ import annotations

import importlib
import os
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
    extra_env: dict[str, str] | None = None,
):
    monkeypatch.setenv("VOICE_AGENT_API_TOKEN", api_token)
    monkeypatch.setenv("VOICE_AGENT_TRANSCRIBE_PROVIDER", provider)
    monkeypatch.setenv("OPENAI_API_KEY", openai_api_key)
    monkeypatch.setenv("VOICE_AGENT_DB_PATH", str(tmp_path / "runs.db"))
    if extra_env:
        for key, value in extra_env.items():
            monkeypatch.setenv(key, value)
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


def test_audio_rejects_large_payload(monkeypatch, tmp_path: Path):
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={"VOICE_AGENT_MAX_AUDIO_MB": "0.000001"},
    )
    resp = client.post(
        "/v1/audio",
        headers={"Authorization": f"Bearer {token}"},
        files={"audio": ("sample.wav", BytesIO(b"more-than-one-byte"), "audio/wav")},
        data={"session_id": "audio3", "executor": "local"},
    )
    assert resp.status_code == 413
    assert "audio payload too large" in resp.json()["detail"]


def test_file_fetch_endpoint(monkeypatch, tmp_path: Path):
    file_path = tmp_path / "sample.txt"
    file_path.write_text("hello-file", encoding="utf-8")
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
    resp = client.get(
        "/v1/files",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(file_path)},
    )
    assert resp.status_code == 200
    assert resp.text == "hello-file"


def test_cancel_codex_run(monkeypatch, tmp_path: Path):
    fake_codex = tmp_path / "codex"
    fake_codex.write_text(
        "#!/usr/bin/env bash\n"
        "echo 'OpenAI Codex fake'\n"
        "sleep 30\n",
        encoding="utf-8",
    )
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "60",
        },
    )
    create_resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "cancel1",
            "utterance_text": "long codex run",
            "executor": "codex",
        },
    )
    assert create_resp.status_code == 200
    run_id = create_resp.json()["run_id"]

    cancel_resp = client.post(
        f"/v1/runs/{run_id}/cancel",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert cancel_resp.status_code == 200
    assert cancel_resp.json()["status"] == "cancel_requested"

    final = None
    for _ in range(80):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        assert run_resp.status_code == 200
        payload = run_resp.json()
        final = payload["status"]
        if final != "running":
            break
        time.sleep(0.05)
    assert final == "cancelled"
    assert "cancelled" in payload["summary"].lower()


def test_codex_run_timeout(monkeypatch, tmp_path: Path):
    fake_codex = tmp_path / "codex"
    fake_codex.write_text(
        "#!/usr/bin/env bash\n"
        "echo 'OpenAI Codex fake'\n"
        "sleep 2\n",
        encoding="utf-8",
    )
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "1",
        },
    )
    create_resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "timeout1",
            "utterance_text": "long codex run",
            "executor": "codex",
        },
    )
    assert create_resp.status_code == 200
    run_id = create_resp.json()["run_id"]

    final = None
    payload = None
    for _ in range(80):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        assert run_resp.status_code == 200
        payload = run_resp.json()
        final = payload["status"]
        if final != "running":
            break
        time.sleep(0.05)
    assert final == "failed"
    assert payload is not None
    assert "timed out" in payload["summary"].lower()
