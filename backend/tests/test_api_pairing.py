from __future__ import annotations

import importlib
import json
import threading
import time
from pathlib import Path


def test_pair_exchange_is_single_use_under_concurrency(make_client, monkeypatch, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        (
            "{"
            '"server_url":"http://127.0.0.1:8000",'
            '"api_token":"abc-token",'
            '"session_id":"iphone-app",'
            '"pair_code":"pair-1234",'
            '"pair_code_expires_at":"2999-01-01T00:00:00Z"'
            "}"
        ),
        encoding="utf-8",
    )
    client, _ = make_client(
        provider="mock",
        api_token="abc-token",
        extra_env={"VOICE_AGENT_PAIRING_FILE": str(pairing_file)},
    )
    module = importlib.import_module("app.main")
    original_rotate = module.PAIRING_SERVICE._rotate_pair_code

    def slow_rotate(payload):
        time.sleep(0.1)
        return original_rotate(payload)

    monkeypatch.setattr(module.PAIRING_SERVICE, "_rotate_pair_code", slow_rotate)

    responses: list = []
    start = threading.Event()

    def redeem_pair_code() -> None:
        start.wait()
        responses.append(
            client.post("/v1/pair/exchange", json={"pair_code": "pair-1234", "session_id": "ios1"})
        )

    threads = [threading.Thread(target=redeem_pair_code) for _ in range(2)]
    for thread in threads:
        thread.start()
    start.set()
    for thread in threads:
        thread.join()

    assert sorted(resp.status_code for resp in responses) == [200, 401]
    assert any(
        resp.status_code == 200
        and resp.json()["api_token"] != "abc-token"
        and resp.json()["session_id"] == "ios1"
        for resp in responses
    )
    updated = pairing_file.read_text(encoding="utf-8")
    assert '"pair_code":"pair-1234"' not in updated.replace(" ", "")


def test_pair_exchange_returns_scoped_token_and_rotates_code(make_client, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        (
            "{"
            '"server_url":"https://relay.example.com",'
            '"server_urls":["https://relay.example.com","http://100.111.99.51:8000"],'
            '"api_token":"abc-token",'
            '"session_id":"iphone-app",'
            '"pair_code":"pair-1234",'
            '"pair_code_expires_at":"2999-01-01T00:00:00Z"'
            "}"
        ),
        encoding="utf-8",
    )
    client, _ = make_client(
        provider="mock",
        api_token="abc-token",
        extra_env={"VOICE_AGENT_PAIRING_FILE": str(pairing_file)},
    )
    resp = client.post("/v1/pair/exchange", json={"pair_code": "pair-1234", "session_id": "ios1"})
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["api_token"] != "abc-token"
    assert payload["refresh_token"]
    assert payload["session_id"] == "ios1"
    assert payload["server_url"] == "https://relay.example.com"
    assert payload["server_urls"][0] == "https://relay.example.com"
    assert "http://100.111.99.51:8000" in payload["server_urls"][1:]
    updated = pairing_file.read_text(encoding="utf-8")
    assert '"pair_code":"pair-1234"' not in updated.replace(" ", "")
    assert payload["api_token"] not in updated
    assert payload["refresh_token"] not in updated


def test_paired_token_authorizes_protected_requests(make_client, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        (
            "{"
            '"server_url":"http://127.0.0.1:8000",'
            '"api_token":"abc-token",'
            '"session_id":"iphone-app",'
            '"pair_code":"pair-1234",'
            '"pair_code_expires_at":"2999-01-01T00:00:00Z"'
            "}"
        ),
        encoding="utf-8",
    )
    client, _ = make_client(
        provider="mock",
        api_token="abc-token",
        extra_env={"VOICE_AGENT_PAIRING_FILE": str(pairing_file)},
    )

    pair_resp = client.post("/v1/pair/exchange", json={"pair_code": "pair-1234", "session_id": "ios1"})
    assert pair_resp.status_code == 200
    paired_token = pair_resp.json()["api_token"]
    assert paired_token != "abc-token"

    config_resp = client.get("/v1/config", headers={"Authorization": f"Bearer {paired_token}"})
    assert config_resp.status_code == 200


def test_pair_refresh_rotates_access_token_and_keeps_refresh_token(make_client, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        (
            "{"
            '"server_url":"http://127.0.0.1:8000",'
            '"api_token":"abc-token",'
            '"session_id":"iphone-app",'
            '"pair_code":"pair-1234",'
            '"pair_code_expires_at":"2999-01-01T00:00:00Z"'
            "}"
        ),
        encoding="utf-8",
    )
    client, _ = make_client(
        provider="mock",
        api_token="abc-token",
        extra_env={"VOICE_AGENT_PAIRING_FILE": str(pairing_file)},
    )

    exchange = client.post("/v1/pair/exchange", json={"pair_code": "pair-1234", "session_id": "ios1"})
    assert exchange.status_code == 200
    issued = exchange.json()

    refresh = client.post(
        "/v1/pair/refresh",
        json={"refresh_token": issued["refresh_token"], "session_id": "ios1"},
    )
    assert refresh.status_code == 200
    refreshed = refresh.json()

    assert refreshed["api_token"] != issued["api_token"]
    assert refreshed["refresh_token"] == issued["refresh_token"]
    assert refreshed["session_id"] == "ios1"

    stale_resp = client.get("/v1/config", headers={"Authorization": f"Bearer {issued['api_token']}"})
    assert stale_resp.status_code == 401

    config_resp = client.get("/v1/config", headers={"Authorization": f"Bearer {refreshed['api_token']}"})
    assert config_resp.status_code == 200


def test_pair_refresh_bootstraps_refresh_token_from_existing_paired_access_token(make_client, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        json.dumps(
            {
                "server_url": "http://127.0.0.1:8000",
                "api_token": "abc-token",
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
                "paired_clients": [
                    {
                        "token_sha256": "legacy-placeholder",
                        "session_id": "ios1",
                        "issued_at": "2026-04-01T00:00:00Z",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    client, _ = make_client(
        provider="mock",
        api_token="abc-token",
        extra_env={"VOICE_AGENT_PAIRING_FILE": str(pairing_file)},
    )

    module = importlib.import_module("app.main")
    updated_payload = json.loads(pairing_file.read_text(encoding="utf-8"))
    updated_payload["paired_clients"] = [
        {
            "token_sha256": module.PAIRING_SERVICE.hash_api_token("legacy-paired-token"),
            "session_id": "ios1",
            "issued_at": "2026-04-01T00:00:00Z",
        }
    ]
    pairing_file.write_text(json.dumps(updated_payload), encoding="utf-8")

    refresh = client.post(
        "/v1/pair/refresh",
        headers={"Authorization": "Bearer legacy-paired-token"},
        json={"session_id": "ios1"},
    )
    assert refresh.status_code == 200
    refreshed = refresh.json()

    assert refreshed["api_token"] == "legacy-paired-token"
    assert refreshed["refresh_token"]
    assert refreshed["session_id"] == "ios1"

    config_resp = client.get("/v1/config", headers={"Authorization": "Bearer legacy-paired-token"})
    assert config_resp.status_code == 200

    stored = json.loads(pairing_file.read_text(encoding="utf-8"))
    assert stored["paired_clients"][0]["refresh_token_sha256"]
