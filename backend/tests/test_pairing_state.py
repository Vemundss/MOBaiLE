from __future__ import annotations

import hashlib
import json
from pathlib import Path

from app.pairing_state import PairingState


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def test_pairing_state_server_urls_prefers_primary_and_dedupes() -> None:
    state = PairingState(Path("/tmp/pairing.json"))

    urls = state.server_urls(
        {
            "server_url": "https://relay.example.com",
            "server_urls": ["https://relay.example.com", "http://100.64.0.1:8000"],
        }
    )

    assert urls == ["https://relay.example.com", "http://100.64.0.1:8000"]


def test_pairing_state_issues_hashed_credentials_and_trims_history(tmp_path: Path) -> None:
    path = tmp_path / "pairing.json"
    state = PairingState(path)
    payload = {
        "paired_clients": [
            {"token_sha256": "old-1", "session_id": "a"},
            {"token_sha256": "old-2", "session_id": "b"},
        ]
    }

    api_token, refresh_token = state.issue_paired_client_credentials(
        payload,
        session_id="ios1",
        max_paired_client_tokens=2,
        hash_token=_hash_token,
    )

    stored = json.loads(path.read_text(encoding="utf-8"))
    assert api_token
    assert refresh_token
    assert api_token not in path.read_text(encoding="utf-8")
    assert refresh_token not in path.read_text(encoding="utf-8")
    assert len(stored["paired_clients"]) == 2
    assert stored["paired_clients"][-1]["token_sha256"] == _hash_token(api_token)
    assert stored["paired_clients"][-1]["refresh_token_sha256"] == _hash_token(refresh_token)


def test_pairing_state_matches_hashed_tokens() -> None:
    state = PairingState(Path("/tmp/pairing.json"))
    payload = {
        "paired_clients": [
            {"token_sha256": _hash_token("secret-token"), "session_id": "ios1"},
        ]
    }

    assert state.pairing_token_matches(payload, "secret-token", hash_token=_hash_token) is True
    assert state.pairing_token_matches(payload, "wrong-token", hash_token=_hash_token) is False
