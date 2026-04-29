from __future__ import annotations

import asyncio
import importlib
import json
import threading
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
    attachment_path = tmp_path / "notes.txt"
    attachment_path.write_text("hello-file", encoding="utf-8")
    attachment = {
        "type": "file",
        "title": "notes.txt",
        "path": str(attachment_path),
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


def test_audio_transcription_runs_outside_event_loop(make_client, monkeypatch):
    client, token = make_client(provider="mock")
    module = importlib.import_module("app.main")
    observed: dict[str, bool | str] = {}

    def fake_transcribe(**_: object) -> str:
        observed["thread_name"] = threading.current_thread().name
        try:
            asyncio.get_running_loop()
            observed["has_running_loop"] = True
        except RuntimeError:
            observed["has_running_loop"] = False
        return "inspect this repo"

    monkeypatch.setattr(module.TRANSCRIBER, "transcribe", fake_transcribe)

    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={"session_id": "audio-threaded", "executor": "local"},
    )

    assert resp.status_code == 200
    assert observed["has_running_loop"] is False
    assert observed["thread_name"] != threading.current_thread().name


def test_audio_run_can_be_cancelled_during_transcription(make_client, monkeypatch):
    client, token = make_client(provider="mock")
    module = importlib.import_module("app.main")
    started = threading.Event()
    release = threading.Event()
    observed: dict[str, object] = {}

    def fake_transcribe(**_: object) -> str:
        started.set()
        assert release.wait(timeout=5)
        return "create a hello python script and run it"

    monkeypatch.setattr(module.TRANSCRIBER, "transcribe", fake_transcribe)

    def post_audio() -> None:
        observed["response"] = client.post(
            "/v1/audio",
            headers=auth_headers(token),
            files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
            data={"session_id": "audio-cancel", "run_id": "audio-cancel", "executor": "local"},
        )

    worker = threading.Thread(target=post_audio)
    worker.start()
    assert started.wait(timeout=5)

    cancel = client.post("/v1/runs/audio-cancel/cancel", headers=auth_headers(token))
    assert cancel.status_code == 200

    cancelled_run = client.get("/v1/runs/audio-cancel", headers=auth_headers(token))
    assert cancelled_run.status_code == 200
    cancelled_payload = cancelled_run.json()
    assert cancelled_payload["status"] == "cancelled"
    assert "run.cancelled" in [event["type"] for event in cancelled_payload["events"]]

    release.set()
    worker.join(timeout=5)
    assert not worker.is_alive()

    response = observed["response"]
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "run_cancelled"

    run = client.get("/v1/runs/audio-cancel", headers=auth_headers(token))
    assert run.status_code == 200
    payload = run.json()
    assert payload["status"] == "cancelled"
    assert "transcribing" in [event["stage"] for event in payload["events"] if event["stage"]]
    assert "run.cancelled" in [event["type"] for event in payload["events"]]


def test_audio_cancelled_transcription_error_remains_cancelled(make_client, monkeypatch):
    client, token = make_client(provider="mock")
    module = importlib.import_module("app.main")
    started = threading.Event()
    release = threading.Event()
    observed: dict[str, object] = {}

    def fake_transcribe(**_: object) -> str:
        started.set()
        assert release.wait(timeout=5)
        raise RuntimeError("provider timed out")

    monkeypatch.setattr(module.TRANSCRIBER, "transcribe", fake_transcribe)

    def post_audio() -> None:
        observed["response"] = client.post(
            "/v1/audio",
            headers=auth_headers(token),
            files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
            data={
                "session_id": "audio-cancel-error",
                "run_id": "audio-cancel-error",
                "executor": "local",
            },
        )

    worker = threading.Thread(target=post_audio)
    worker.start()
    assert started.wait(timeout=5)

    cancel = client.post("/v1/runs/audio-cancel-error/cancel", headers=auth_headers(token))
    assert cancel.status_code == 200
    release.set()
    worker.join(timeout=5)
    assert not worker.is_alive()

    response = observed["response"]
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "run_cancelled"

    run = client.get("/v1/runs/audio-cancel-error", headers=auth_headers(token))
    assert run.status_code == 200
    payload = run.json()
    assert payload["status"] == "cancelled"
    assert "run.failed" not in [event["type"] for event in payload["events"]]


def test_audio_openai_missing_key(make_client):
    client, token = make_client(provider="openai", openai_api_key="")
    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={"session_id": "audio2", "executor": "local"},
    )
    assert resp.status_code == 502
    detail = resp.json()["detail"]
    assert detail["code"] == "transcription_failed"
    assert "OPENAI_API_KEY is not set" in detail["message"]


def test_audio_openai_transcript_hint_does_not_bypass_provider(make_client):
    client, token = make_client(provider="openai", openai_api_key="")
    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={
            "session_id": "audio-openai-hint",
            "executor": "local",
            "transcript_hint": "do not execute this as a transcript",
        },
    )

    assert resp.status_code == 502
    detail = resp.json()["detail"]
    assert detail["code"] == "transcription_failed"
    assert "OPENAI_API_KEY is not set" in detail["message"]


def test_audio_unexpected_transcription_failure_marks_precreated_run_failed(make_client, monkeypatch):
    client, token = make_client(provider="mock")
    module = importlib.import_module("app.main")

    def fake_transcribe(**_: object) -> str:
        raise RuntimeError("encoder crashed")

    monkeypatch.setattr(module.TRANSCRIBER, "transcribe", fake_transcribe)

    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={"session_id": "audio-failed", "run_id": "audio-failed", "executor": "local"},
    )

    assert resp.status_code == 500
    detail = resp.json()["detail"]
    assert detail["code"] == "transcription_failed"

    run = client.get("/v1/runs/audio-failed", headers=auth_headers(token))
    assert run.status_code == 200
    payload = run.json()
    assert payload["status"] == "failed"
    assert "run.failed" in [event["type"] for event in payload["events"]]


def test_audio_rejects_large_payload(make_client):
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_MAX_AUDIO_MB": "0.000001"},
    )
    resp = client.post(
        "/v1/audio",
        headers=auth_headers(token),
        files={"audio": ("sample.wav", BytesIO(b"more-than-one-byte"), "audio/wav")},
        data={"session_id": "audio3", "run_id": "audio3", "executor": "local"},
    )
    assert resp.status_code == 413
    detail = resp.json()["detail"]
    assert detail["code"] == "audio_too_large"
    assert "audio payload too large" in detail["message"]
    run = client.get("/v1/runs/audio3", headers=auth_headers(token))
    assert run.status_code == 200
    assert run.json()["status"] == "failed"


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


def test_file_fetch_absolute_allowed_inside_roots_when_disabled(make_client, tmp_path: Path):
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
    assert resp.status_code == 200
    assert resp.text == "hello-file"


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


def test_file_fetch_supports_range_requests(make_client, tmp_path: Path):
    sample = tmp_path / "large.txt"
    sample.write_text("abcdefghij", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )
    headers = auth_headers(token)
    headers["Range"] = "bytes=2-5"

    resp = client.get("/v1/files", headers=headers, params={"path": str(sample)})

    assert resp.status_code == 206
    assert resp.content == b"cdef"
    assert resp.headers["content-range"] == "bytes 2-5/10"


def test_file_inspect_endpoint_returns_metadata_and_text_preview(make_client, tmp_path: Path):
    notes = tmp_path / "notes.md"
    notes.write_text("# Title\n\nbody text", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )

    resp = client.get(
        "/v1/files/inspect",
        headers=auth_headers(token),
        params={"path": str(notes), "text_preview_bytes": "8"},
    )

    assert resp.status_code == 200
    payload = resp.json()
    assert payload["name"] == "notes.md"
    assert payload["path"] == str(notes)
    assert payload["size_bytes"] == 18
    assert payload["mime"] in {"text/markdown", "text/x-markdown"}
    assert payload["artifact_type"] == "code"
    assert isinstance(payload["modified_at"], str)
    assert payload["text_preview"] == "# Title\n"
    assert payload["text_preview_bytes"] == 8
    assert payload["text_preview_offset"] == 0
    assert payload["text_preview_next_offset"] == 8
    assert payload["text_preview_truncated"] is True


def test_file_inspect_endpoint_supports_preview_offset_and_search(make_client, tmp_path: Path):
    notes = tmp_path / "notes.md"
    notes.write_text("alpha\nBeta match\nmore text\nbeta again", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )

    resp = client.get(
        "/v1/files/inspect",
        headers=auth_headers(token),
        params={
            "path": str(notes),
            "text_preview_bytes": "9",
            "text_preview_offset": "6",
            "text_search": "BETA",
        },
    )

    assert resp.status_code == 200
    payload = resp.json()
    assert payload["text_preview"] == "Beta matc"
    assert payload["text_preview_bytes"] == 9
    assert payload["text_preview_offset"] == 6
    assert payload["text_preview_next_offset"] == 15
    assert payload["text_search_query"] == "BETA"
    assert payload["text_search_match_count"] == 2
    assert payload["text_search_matches"] == [
        {"line_number": 2, "line_text": "Beta match"},
        {"line_number": 4, "line_text": "beta again"},
    ]


def test_file_inspect_endpoint_reports_sensitive_preview_block(make_client, tmp_path: Path):
    secret = tmp_path / ".env.local"
    secret.write_text("TOKEN=private", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )

    resp = client.get(
        "/v1/files/inspect",
        headers=auth_headers(token),
        params={"path": str(secret), "text_search": "TOKEN"},
    )

    assert resp.status_code == 200
    payload = resp.json()
    assert payload["text_preview"] is None
    assert payload["preview_blocked_reason"] == "sensitive_path"
    assert payload["text_search_query"] == "TOKEN"
    assert payload["text_search_match_count"] == 0
    assert payload["text_search_matches"] == []


def test_file_inspect_endpoint_rejects_outside_allowed_roots(make_client, tmp_path: Path):
    allowed = tmp_path / "allowed"
    outside = tmp_path / "outside.txt"
    allowed.mkdir(parents=True, exist_ok=True)
    outside.write_text("nope", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_FILE_ROOTS": str(allowed),
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "true",
        },
    )

    resp = client.get("/v1/files/inspect", headers=auth_headers(token), params={"path": str(outside)})

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
    readme = next(item for item in payload["entries"] if item["name"] == "README.md")
    assert readme["size_bytes"] == 5
    assert readme["mime"] in {"text/markdown", "text/x-markdown"}
    assert isinstance(readme["modified_at"], str)
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
    detail = resp.json()["detail"]
    assert detail["code"] == "file_too_large"
    assert "file payload too large" in detail["message"]


def test_upload_endpoint_rejects_empty_file(make_client, tmp_path: Path):
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(tmp_path / "workspace"),
        },
    )
    resp = client.post(
        "/v1/uploads",
        headers=auth_headers(token),
        files={"file": ("empty.txt", BytesIO(b""), "text/plain")},
        data={"session_id": "ios-session"},
    )
    assert resp.status_code == 400
    assert resp.json()["detail"] == "uploaded file is empty"


def test_utterance_rejects_missing_attachment_reference(make_client, tmp_path: Path):
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(tmp_path / "workspace"),
        },
    )
    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "ios-session",
            "utterance_text": "inspect this",
            "attachments": [{"type": "file", "title": "notes.txt"}],
            "executor": "local",
        },
    )
    assert resp.status_code == 400
    assert resp.json()["detail"] == "attachment must include a file path or backend file URL"


def test_utterance_accepts_backend_file_url_attachment(make_client, tmp_path: Path):
    workdir = tmp_path / "workspace"
    file_path = workdir / "notes.txt"
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_text("hello-file", encoding="utf-8")
    client, token = make_client(
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workdir),
            "VOICE_AGENT_FILE_ROOTS": str(workdir),
        },
    )
    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "ios-session",
            "utterance_text": "inspect this",
            "attachments": [
                {
                    "type": "file",
                    "title": "notes.txt",
                    "url": f"http://old-host.example/v1/files?path={file_path}",
                }
            ],
            "executor": "local",
        },
    )
    assert resp.status_code == 200


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
