from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from .api_test_support import auth_headers


def test_credential_request_fulfillment_redacts_secret_values(make_client, tmp_path: Path) -> None:
    client, token = make_client(
        extra_env={
            "VOICE_AGENT_DB_PATH": str(tmp_path / "runs.db"),
        }
    )

    create = client.post(
        "/v1/credential-requests",
        headers=auth_headers(token),
        json={
            "session_id": "session-1",
            "run_id": "run-1",
            "title": "GitHub login",
            "reason": "The agent needs a one-time login to continue.",
            "fields": [
                {"id": "username", "label": "Username", "kind": "username", "secret": False},
                {"id": "password", "label": "Password", "kind": "password", "secret": True},
            ],
        },
    )

    assert create.status_code == 200
    request_payload = create.json()
    request_id = request_payload["request_id"]
    assert request_payload["status"] == "pending"
    assert "hunter2" not in json.dumps(request_payload)

    fulfill = client.post(
        f"/v1/credential-requests/{request_id}/fulfill",
        headers=auth_headers(token),
        json={
            "values": {
                "username": "octocat",
                "password": "hunter2",
            },
            "persist": False,
        },
    )

    assert fulfill.status_code == 200
    fulfill_payload = fulfill.json()
    assert fulfill_payload == {
        "request_id": request_id,
        "status": "fulfilled",
        "credential_handle": f"credential-request://{request_id}",
        "submitted_fields": ["password", "username"],
    }
    assert "hunter2" not in json.dumps(fulfill_payload)

    record = client.get(f"/v1/credential-requests/{request_id}", headers=auth_headers(token))
    assert record.status_code == 200
    record_payload = record.json()
    assert record_payload["status"] == "fulfilled"
    assert record_payload["submitted_fields"] == ["password", "username"]
    assert "hunter2" not in json.dumps(record_payload)

    metadata_path = tmp_path / "credential-requests.json"
    assert metadata_path.exists()
    metadata = metadata_path.read_text(encoding="utf-8")
    assert "hunter2" not in metadata
    assert "octocat" not in metadata


def test_credential_request_rejects_persistence_until_keychain_storage_exists(make_client) -> None:
    client, token = make_client()
    created = client.post(
        "/v1/credential-requests",
        headers=auth_headers(token),
        json={
            "session_id": "session-1",
            "title": "Service token",
            "reason": "Need a token for a protected deploy.",
            "fields": [{"id": "token", "label": "Token", "kind": "token", "secret": True}],
        },
    )
    request_id = created.json()["request_id"]

    response = client.post(
        f"/v1/credential-requests/{request_id}/fulfill",
        headers=auth_headers(token),
        json={"values": {"token": "secret-token"}, "persist": True},
    )

    assert response.status_code == 400
    assert "persistent credential storage is not available yet" in response.json()["detail"]


def test_credential_request_resolve_is_local_only_and_consumes_values(make_client, tmp_path: Path) -> None:
    client, token = make_client(
        extra_env={
            "VOICE_AGENT_DB_PATH": str(tmp_path / "runs.db"),
        }
    )
    created = client.post(
        "/v1/credential-requests",
        headers=auth_headers(token),
        json={
            "session_id": "session-1",
            "title": "Deploy token",
            "reason": "Need a one-time deploy credential.",
            "fields": [{"id": "token", "label": "Token", "kind": "token", "secret": True}],
        },
    )
    request_id = created.json()["request_id"]

    fulfilled = client.post(
        f"/v1/credential-requests/{request_id}/fulfill",
        headers=auth_headers(token),
        json={"values": {"token": "test-secret-token"}, "persist": False},
    )
    assert fulfilled.status_code == 200

    resolved = client.post(
        f"/v1/credential-requests/{request_id}/resolve",
        headers=auth_headers(token),
    )

    assert resolved.status_code == 200
    assert resolved.json() == {
        "request_id": request_id,
        "status": "resolved",
        "credential_handle": f"credential-request://{request_id}",
        "values": {"token": "test-secret-token"},
    }

    resolved_again = client.post(
        f"/v1/credential-requests/{request_id}/resolve",
        headers=auth_headers(token),
    )
    assert resolved_again.status_code == 409
    assert "already consumed" in resolved_again.json()["detail"]

    metadata = (tmp_path / "credential-requests.json").read_text(encoding="utf-8")
    assert "test-secret-token" not in metadata


def test_credential_request_resolve_rejects_non_local_clients(make_client) -> None:
    client, token = make_client()
    created = client.post(
        "/v1/credential-requests",
        headers=auth_headers(token),
        json={
            "session_id": "session-1",
            "title": "Browser login",
            "reason": "Need credentials for a protected browser flow.",
        },
    )
    request_id = created.json()["request_id"]
    fulfilled = client.post(
        f"/v1/credential-requests/{request_id}/fulfill",
        headers=auth_headers(token),
        json={"values": {"username": "test-user", "password": "test-password"}, "persist": False},
    )
    assert fulfilled.status_code == 200

    remote_client = TestClient(client.app, client=("203.0.113.10", 50000))
    remote_resolve = remote_client.post(
        f"/v1/credential-requests/{request_id}/resolve",
        headers=auth_headers(token),
    )

    assert remote_resolve.status_code == 403
    assert "only available from this computer" in remote_resolve.json()["detail"]

    local_resolve = client.post(
        f"/v1/credential-requests/{request_id}/resolve",
        headers=auth_headers(token),
    )
    assert local_resolve.status_code == 200


def test_credential_request_list_filters_by_session_and_status(make_client) -> None:
    client, token = make_client()
    for session_id in ("session-a", "session-b"):
        response = client.post(
            "/v1/credential-requests",
            headers=auth_headers(token),
            json={
                "session_id": session_id,
                "title": f"Login for {session_id}",
                "reason": "Need credentials.",
            },
        )
        assert response.status_code == 200

    listed = client.get(
        "/v1/credential-requests",
        headers=auth_headers(token),
        params={"session_id": "session-a", "status": "pending"},
    )

    assert listed.status_code == 200
    payload = listed.json()
    assert len(payload["requests"]) == 1
    assert payload["requests"][0]["session_id"] == "session-a"
