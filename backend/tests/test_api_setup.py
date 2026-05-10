from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .api_test_support import auth_headers


def _write_pairing_file(path: Path, *, pair_code: str = "123456") -> None:
    expires_at = (datetime.now(timezone.utc) + timedelta(minutes=30)).isoformat().replace("+00:00", "Z")
    path.write_text(
        json.dumps(
            {
                "server_url": "http://example.tail0000.ts.net:8000",
                "server_urls": ["http://example.tail0000.ts.net:8000"],
                "session_id": "iphone-app",
                "pair_code": pair_code,
                "pair_code_expires_at": expires_at,
            }
        )
        + "\n",
        encoding="utf-8",
    )


def test_setup_readiness_requires_auth_and_hides_pair_code(make_client, tmp_path: Path) -> None:
    pairing_file = tmp_path / "pairing.json"
    _write_pairing_file(pairing_file)
    (tmp_path / "pairing-qr.png").write_bytes(b"fake-png")
    client, token = make_client(
        extra_env={
            "VOICE_AGENT_PAIRING_FILE": str(pairing_file),
            "VOICE_AGENT_PHONE_ACCESS_MODE": "tailscale",
        }
    )

    assert client.get("/v1/setup/readiness").status_code == 401

    response = client.get("/v1/setup/readiness", headers=auth_headers(token))
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ready"
    assert payload["pairing"]["status"] == "ready"
    assert payload["pairing"]["qr_available"] is True
    assert payload["pairing"]["qr_url"] is None
    assert payload["agent_cli"]["available"] == ["codex", "claude"]
    assert payload["autonomy"]["setup_command"] == "mobaile ready"
    assert {item["id"] for item in payload["autonomy"]["checks"]} >= {
        "autonomy_security_mode",
        "autonomy_browser_profile",
        "autonomy_human_unblock",
    }
    assert "pair_code" not in json.dumps(payload)


def test_local_setup_page_surfaces_readiness_and_qr(make_client, tmp_path: Path) -> None:
    pairing_file = tmp_path / "pairing.json"
    _write_pairing_file(pairing_file)
    (tmp_path / "pairing-qr.png").write_bytes(b"fake-png")
    client, _ = make_client(extra_env={"VOICE_AGENT_PAIRING_FILE": str(pairing_file)})

    page = client.get("/setup")
    assert page.status_code == 200
    assert "MOBaiLE Setup" in page.text

    readiness = client.get("/setup/readiness")
    assert readiness.status_code == 200
    payload = readiness.json()
    assert payload["pairing"]["qr_url"] == "/setup/pairing-qr.png"

    qr = client.get("/setup/pairing-qr.png")
    assert qr.status_code == 200
    assert qr.content == b"fake-png"


def test_pair_exchange_records_local_onboarding_event(make_client, tmp_path: Path) -> None:
    pairing_file = tmp_path / "pairing.json"
    _write_pairing_file(pairing_file, pair_code="654321")
    events_path = tmp_path / "onboarding-events.jsonl"
    client, token = make_client(
        extra_env={
            "VOICE_AGENT_PAIRING_FILE": str(pairing_file),
            "VOICE_AGENT_DB_PATH": str(tmp_path / "runs.db"),
            "VOICE_AGENT_CAPABILITIES_REPORT_PATH": str(tmp_path / "capabilities.json"),
        }
    )
    # Keep the recorder local to tmp_path for this reloaded app instance.
    import app.main as main

    main.ONBOARDING_EVENTS = main.OnboardingEventRecorder(events_path)

    pair = client.post("/v1/pair/exchange", json={"pair_code": "654321"})
    assert pair.status_code == 200

    report = client.get("/v1/setup/onboarding-report", headers=auth_headers(token))
    assert report.status_code == 200
    assert report.json()["counts"]["pairing_success"] == 1
