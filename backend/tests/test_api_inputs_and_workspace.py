from __future__ import annotations

import importlib
import json
from io import BytesIO
from pathlib import Path

from app.models.schemas import AgendaItem

from .api_test_support import auth_headers, wait_for_run_to_settle


def test_calendar_adapter_flow(make_client, monkeypatch):
    client, token = make_client(provider="mock")
    module = importlib.import_module("app.main")

    def fake_events():
        return [
            AgendaItem(
                start="09:00",
                end="10:00",
                title="Standup",
                calendar="Work",
                location="Room A",
            )
        ]

    monkeypatch.setattr(module.CALENDAR_SERVICE, "fetch_today_events", fake_events)

    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "cal1",
            "utterance_text": "Check my calendar today",
            "executor": "codex",
        },
    )
    assert resp.status_code == 200
    run_id = resp.json()["run_id"]

    payload = wait_for_run_to_settle(client, token, run_id, attempts=40)
    assert payload["status"] == "completed"
    activity_stages = [e["stage"] for e in payload["events"] if e["type"].startswith("activity.")]
    assert activity_stages == ["planning", "executing", "summarizing"]
    chat_events = [e for e in payload["events"] if e["type"] == "chat.message"]
    assert len(chat_events) >= 1
    assert '"assistant_response"' in chat_events[0]["message"]


def test_calendar_adapter_failure_emits_error_activity(make_client, monkeypatch):
    client, token = make_client(provider="mock")
    module = importlib.import_module("app.main")

    def failing_events():
        raise RuntimeError("calendar unavailable")

    monkeypatch.setattr(module.CALENDAR_SERVICE, "fetch_today_events", failing_events)

    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "cal-fail",
            "utterance_text": "Check my calendar today",
            "executor": "codex",
        },
    )
    assert resp.status_code == 200
    run_id = resp.json()["run_id"]

    payload = wait_for_run_to_settle(client, token, run_id, attempts=40)
    assert payload["status"] == "failed"
    activity_events = [event for event in payload["events"] if event["type"].startswith("activity.")]
    assert [event["stage"] for event in activity_events] == ["planning", "executing", "executing"]
    assert activity_events[-1]["level"] == "error"
    assert activity_events[-1]["display_message"] == "Calendar query failed."


def test_calendar_today_returns_structured_unsupported_response_on_linux(make_client, monkeypatch):
    client, token = make_client(provider="mock")
    monkeypatch.setattr("app.calendar_service.os.uname", lambda: type("Uname", (), {"sysname": "Linux"})())

    resp = client.get("/v1/tools/calendar/today", headers=auth_headers(token))
    assert resp.status_code == 503
    payload = resp.json()
    assert payload["supported"] is False
    assert payload["count"] == 0
    assert "macOS" in payload["detail"]


def test_local_utterance_flow(make_client):
    client, token = make_client()
    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "t1",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert resp.status_code == 200
    run_id = resp.json()["run_id"]

    payload = wait_for_run_to_settle(client, token, run_id, attempts=30)
    assert payload["status"] == "completed"
    activity_stages = [e["stage"] for e in payload["events"] if e["type"].startswith("activity.")]
    assert activity_stages == ["planning", "executing", "summarizing"]


def test_local_utterance_flow_accepts_typed_attachments(make_client, tmp_path: Path):
    attached = tmp_path / "workspace" / "notes.txt"
    attached.parent.mkdir(parents=True, exist_ok=True)
    attached.write_text("remember this", encoding="utf-8")

    client, token = make_client(
        extra_env={"VOICE_AGENT_DEFAULT_WORKDIR": str(tmp_path / "workspace")},
    )
    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "typed-attachments",
            "utterance_text": "",
            "executor": "local",
            "attachments": [
                {
                    "type": "file",
                    "title": "notes.txt",
                    "path": str(attached),
                    "mime": "text/plain",
                }
            ],
        },
    )
    assert resp.status_code == 200
    run_id = resp.json()["run_id"]

    payload = wait_for_run_to_settle(client, token, run_id, attempts=30)
    assert payload["status"] == "completed"
    assert payload["utterance_text"] == "Inspect notes.txt"


def test_audio_mock_flow(make_client):
    client, token = make_client(provider="mock")
    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
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


def test_audio_mock_flow_preserves_draft_context_and_attachments(make_client, tmp_path: Path):
    client, token = make_client(provider="mock")
    attachment = {
        "type": "file",
        "title": "notes.txt",
        "path": str(tmp_path / "notes.txt"),
        "mime": "text/plain",
    }
    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={
            "session_id": "audio-context",
            "executor": "local",
            "draft_text": "Run the smoke test again.",
            "transcript_hint": "Compare it with the last pass too.",
            "attachments_json": json.dumps([attachment]),
        },
    )
    assert resp.status_code == 200

    run_id = resp.json()["run_id"]
    run_resp = client.get(f"/v1/runs/{run_id}", headers=auth_headers(token))
    assert run_resp.status_code == 200
    payload = run_resp.json()
    assert payload["utterance_text"] == "Run the smoke test again.\n\nCompare it with the last pass too."


def test_audio_openai_missing_key(make_client):
    client, token = make_client(provider="openai", openai_api_key="")
    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={"session_id": "audio2", "executor": "local"},
    )
    assert resp.status_code == 502
    assert "OPENAI_API_KEY is not set" in resp.json()["detail"]


def test_audio_rejects_large_payload(make_client):
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_MAX_AUDIO_MB": "0.000001"},
    )
    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"more-than-one-byte"), "audio/wav")},
        data={"session_id": "audio3", "executor": "local"},
    )
    assert resp.status_code == 413
    assert "audio payload too large" in resp.json()["detail"]


def test_file_fetch_endpoint(make_client, tmp_path: Path):
    file_path = tmp_path / "sample.txt"
    file_path.write_text("hello-file", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path), "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "true"},
    )
    resp = client.get("/v1/files", headers=auth_headers(token), params={"path": str(file_path)})
    assert resp.status_code == 200
    assert resp.text == "hello-file"


def test_file_fetch_full_access_without_explicit_roots_allows_absolute_paths(make_client, tmp_path: Path):
    file_path = tmp_path / "sample.txt"
    file_path.write_text("hello-file", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_SECURITY_MODE": "full-access",
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "true",
        },
    )
    resp = client.get("/v1/files", headers=auth_headers(token), params={"path": str(file_path)})
    assert resp.status_code == 200
    assert resp.text == "hello-file"


def test_file_fetch_relative_path_uses_default_workdir(make_client, tmp_path: Path):
    workdir = tmp_path / "workspace"
    workdir.mkdir(parents=True, exist_ok=True)
    file_path = workdir / "plot_xy_temp.png"
    file_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workdir),
            "VOICE_AGENT_FILE_ROOTS": str(workdir),
        },
    )
    resp = client.get("/v1/files", headers=auth_headers(token), params={"path": "plot_xy_temp.png"})
    assert resp.status_code == 200
    assert resp.content.startswith(b"\x89PNG")


def test_file_fetch_absolute_blocked_when_disabled(make_client, tmp_path: Path):
    file_path = tmp_path / "sample.txt"
    file_path.write_text("hello-file", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_FILE_ROOTS": str(tmp_path),
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "false",
        },
    )
    resp = client.get("/v1/files", headers=auth_headers(token), params={"path": str(file_path)})
    assert resp.status_code == 403
    assert "absolute file paths are disabled" in resp.json()["detail"].lower()


def test_file_fetch_rejects_outside_allowed_roots(make_client, tmp_path: Path):
    outside = tmp_path / "outside.txt"
    outside.write_text("nope", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_FILE_ROOTS": str(tmp_path / "allowed"),
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "true",
        },
    )
    resp = client.get("/v1/files", headers=auth_headers(token), params={"path": str(outside)})
    assert resp.status_code == 403


def test_directory_listing_endpoint(make_client, tmp_path: Path):
    (tmp_path / "src").mkdir(parents=True, exist_ok=True)
    (tmp_path / "README.md").write_text("hello", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )
    resp = client.get("/v1/directories", headers=auth_headers(token), params={"path": str(tmp_path)})
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["path"] == str(tmp_path)
    assert payload["entries"][0]["name"] == "src"
    names = [item["name"] for item in payload["entries"]]
    assert "README.md" in names
    assert payload["truncated"] is False


def test_directory_listing_creates_missing_path(make_client, tmp_path: Path):
    missing = tmp_path / "new-folder"
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )
    resp = client.get("/v1/directories", headers=auth_headers(token), params={"path": str(missing)})
    assert resp.status_code == 404
    assert not missing.exists()


def test_directory_create_endpoint(make_client, tmp_path: Path):
    missing = tmp_path / "new-folder"
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )
    create = client.post(
        "/v1/directories",
        headers=auth_headers(token),
        json={"path": str(missing)},
    )
    assert create.status_code == 200
    payload = create.json()
    assert payload["path"] == str(missing)
    assert payload["created"] is True
    assert missing.exists()
    assert missing.is_dir()

    list_resp = client.get("/v1/directories", headers=auth_headers(token), params={"path": str(missing)})
    assert list_resp.status_code == 200
    assert list_resp.json()["entries"] == []


def test_upload_endpoint_stores_file_inside_allowed_roots(make_client, tmp_path: Path):
    workdir = tmp_path / "workspace"
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workdir),
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "false",
        },
    )
    resp = client.post(
        "/v1/uploads",
        headers=auth_headers(token),
        files={"file": ("notes.txt", BytesIO(b"hello from phone"), "text/plain")},
        data={"session_id": "ios-session"},
    )
    assert resp.status_code == 200
    payload = resp.json()
    artifact = payload["artifact"]
    stored_path = Path(artifact["path"])
    assert artifact["type"] == "code"
    assert artifact["title"] == "notes.txt"
    assert stored_path.exists()
    assert workdir in stored_path.parents
    assert ".mobaile_uploads" in stored_path.parts

    file_resp = client.get("/v1/files", headers=auth_headers(token), params={"path": str(stored_path)})
    assert file_resp.status_code == 200
    assert file_resp.content == b"hello from phone"


def test_upload_endpoint_rejects_large_file(make_client, tmp_path: Path):
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(tmp_path / "workspace"),
            "VOICE_AGENT_MAX_UPLOAD_MB": "0.0001",
        },
    )
    resp = client.post(
        "/v1/uploads",
        headers=auth_headers(token),
        files={"file": ("large.bin", BytesIO(b"x" * 512), "application/octet-stream")},
        data={"session_id": "ios-session"},
    )
    assert resp.status_code == 413
    assert "file payload too large" in resp.json()["detail"]


def test_directory_listing_rejects_outside_allowed_roots(make_client, tmp_path: Path):
    allowed = tmp_path / "allowed"
    allowed.mkdir(parents=True, exist_ok=True)
    outside = tmp_path / "outside"
    outside.mkdir(parents=True, exist_ok=True)
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(allowed)},
    )
    resp = client.get("/v1/directories", headers=auth_headers(token), params={"path": str(outside)})
    assert resp.status_code == 403


def test_workdir_restricted_in_safe_mode(make_client):
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_SECURITY_MODE": "safe"},
    )
    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "safe1",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
            "working_directory": "/tmp",
        },
    )
    assert resp.status_code == 400
    assert "working_directory" in resp.json()["detail"]
