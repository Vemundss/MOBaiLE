from __future__ import annotations

import importlib
import json
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


def test_codex_prompt_context_injection(monkeypatch, tmp_path: Path):
    context_file = tmp_path / "ctx.md"
    context_file.write_text("You are in test context.", encoding="utf-8")
    monkeypatch.setenv("VOICE_AGENT_CODEX_USE_CONTEXT", "true")
    monkeypatch.setenv("VOICE_AGENT_CODEX_CONTEXT_FILE", str(context_file))
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    built = module._build_codex_prompt("create hello script")
    assert "MOBaiLE runtime context" in built
    assert "You are in test context." in built
    assert "create hello script" in built


def test_profile_memory_seed_and_prompt_block(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_PROFILE_STATE_ROOT", str(tmp_path / "profiles"))
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    agents, memory = module._load_profile_context()
    assert "MOBaiLE AGENTS" in agents
    assert "MOBaiLE MEMORY" in memory

    built = module._build_codex_prompt(
        "check calendar today",
        profile_agents=agents,
        profile_memory=memory,
    )
    assert "Persistent AGENTS profile" in built
    assert "Persistent MEMORY" in built
    assert "~/.codex" in built
    assert "check calendar today" in built


def test_profile_memory_sync_accepts_memory_file_fallback(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_PROFILE_STATE_ROOT", str(tmp_path / "profiles"))
    monkeypatch.setenv("VOICE_AGENT_PROFILE_ID", "user-fallback")
    module = importlib.import_module("app.main")
    module = importlib.reload(module)

    workdir = tmp_path / "workspace"
    mobaile_dir = workdir / ".mobaile"
    mobaile_dir.mkdir(parents=True, exist_ok=True)
    primary = mobaile_dir / "MEMORY.md"
    fallback = workdir / "memory.md"

    primary.write_text("# stale\nold memory\n", encoding="utf-8")
    fallback.write_text("# fresh\nnew durable note\n", encoding="utf-8")
    now = time.time()
    os.utime(fallback, (now + 5, now + 5))

    module._sync_profile_memory_from_workdir(primary)

    profile_memory = tmp_path / "profiles" / "user-fallback" / "MEMORY.md"
    assert profile_memory.exists()
    text = profile_memory.read_text(encoding="utf-8")
    assert "new durable note" in text
    assert "old memory" not in text


def test_codex_structured_message_filters_noise(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    user_prompt = "create a python file"

    assert module._codex_structured_message("/bin/zsh -lc \"python3 hello.py\"", user_prompt) is None
    assert module._codex_structured_message("tokens used", user_prompt) is None
    assert module._codex_structured_message("You are running through MOBaiLE.", user_prompt) is None
    assert module._codex_structured_message("MOBaiLE runtime context:", user_prompt) is None
    assert module._codex_structured_message("You are the coding agent used by MOBaiLE.", user_prompt) is None
    assert module._codex_structured_message("Product intent: MOBaiLE makes a user's computer available from their phone.", user_prompt) is None
    assert module._codex_structured_message("Keep responses concise and grouped; avoid verbose step-by-step chatter.", user_prompt) is None
    assert module._codex_structured_message("```text", user_prompt) is None
    assert module._codex_structured_message("Created `hello.py` and ran it successfully.", user_prompt) is None
    assert module._codex_structured_message("1,147", user_prompt) is None
    assert module._codex_structured_message("Done. Created hello.py.", user_prompt) == "Done. Created hello.py."


def test_codex_assistant_extractor_emits_only_assistant_blocks(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    extractor = module._CodexAssistantExtractor("hello")
    lines = [
        "OpenAI Codex v0.0",
        "user",
        "hello",
        "codex",
        "I checked your calendar for today.",
        "- 10:00 Standup",
        "exec",
        "/bin/zsh -lc \"date\"",
        "codex",
        "Done.",
    ]
    out: list[str] = []
    for line in lines:
        out.extend(extractor.consume(line))
    out.extend(extractor.flush())
    assert any("I checked your calendar" in item for item in out)
    assert all("/bin/zsh" not in item for item in out)
    assert any(item == "Done." for item in out)


def test_parse_chat_envelope_payload_handles_wrapped_json(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    payload = '{"type":"assistant_response","version":"1.0","summary":"ok","sections":[],"agenda_items":[]}'
    parsed = module._parse_chat_envelope_payload(payload)
    assert parsed is not None
    assert parsed["type"] == "assistant_response"
    wrapped = json.dumps(payload)
    parsed_wrapped = module._parse_chat_envelope_payload(wrapped)
    assert parsed_wrapped is not None
    assert parsed_wrapped["summary"] == "ok"


def test_merge_assistant_lines_adds_structure(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    merged = module._merge_assistant_lines(
        [
            "What I Did:",
            "Created /Users/test/hello.py",
            "Result",
            "Hello, world!",
        ]
    )
    assert "What I Did:\nCreated /Users/test/hello.py" in merged
    assert "## Result\nHello, world!" in merged


def test_coerce_assistant_text_to_envelope_extracts_artifacts(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    envelope = module._coerce_assistant_text_to_envelope(
        "## What I Did\nCreated /Users/test/hello.py\n\n## Result\n![plot](/Users/test/plot.png)"
    )
    assert envelope.type == "assistant_response"
    assert envelope.message_id
    assert envelope.created_at
    assert len(envelope.sections) >= 1
    assert any(item.path == "/Users/test/hello.py" for item in envelope.artifacts)
    assert any(item.path == "/Users/test/plot.png" and item.type == "image" for item in envelope.artifacts)


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


def test_codex_guardrails_enforce_rejects_dangerous(monkeypatch, tmp_path: Path):
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={"VOICE_AGENT_CODEX_GUARDRAILS": "enforce"},
    )
    resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "guardrails-1",
            "utterance_text": "please run rm -rf /tmp/test",
            "executor": "codex",
        },
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["status"] == "rejected"
    run = client.get(f"/v1/runs/{payload['run_id']}", headers={"Authorization": f"Bearer {token}"})
    assert run.status_code == 200
    assert run.json()["status"] == "rejected"


def test_list_session_runs_and_diagnostics(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path)
    create = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "sess-list",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    final = None
    for _ in range(40):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        payload = run_resp.json()
        final = payload["status"]
        if final != "running":
            break
        time.sleep(0.05)
    assert final == "completed"

    listing = client.get(
        "/v1/sessions/sess-list/runs?limit=5",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert listing.status_code == 200
    listed = listing.json()
    assert len(listed) >= 1
    assert listed[0]["run_id"] == run_id

    diag = client.get(
        f"/v1/runs/{run_id}/diagnostics",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert diag.status_code == 200
    diagnostics = diag.json()
    assert diagnostics["run_id"] == run_id
    assert diagnostics["event_count"] >= 1
    assert "action.started" in diagnostics["event_type_counts"]
    assert payload["events"][0].get("event_id")
    assert payload["events"][0].get("created_at")


def test_calendar_adapter_flow(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
    module = importlib.import_module("app.main")

    def fake_events():
        return [
            module.AgendaItem(
                start="09:00",
                end="10:00",
                title="Standup",
                calendar="Work",
                location="Room A",
            )
        ]

    monkeypatch.setattr(module, "_fetch_today_calendar_events", fake_events)

    resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "cal1",
            "utterance_text": "Check my calendar today",
            "executor": "codex",
        },
    )
    assert resp.status_code == 200
    run_id = resp.json()["run_id"]

    final = None
    payload = None
    for _ in range(40):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        payload = run_resp.json()
        final = payload["status"]
        if final != "running":
            break
        time.sleep(0.05)
    assert final == "completed"
    assert payload is not None
    chat_events = [e for e in payload["events"] if e["type"] == "chat.message"]
    assert len(chat_events) >= 1
    assert "\"assistant_response\"" in chat_events[0]["message"]


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
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path), "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "true"},
    )
    resp = client.get(
        "/v1/files",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(file_path)},
    )
    assert resp.status_code == 200
    assert resp.text == "hello-file"


def test_file_fetch_rejects_outside_allowed_roots(monkeypatch, tmp_path: Path):
    outside = tmp_path / "outside.txt"
    outside.write_text("nope", encoding="utf-8")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "VOICE_AGENT_FILE_ROOTS": str(tmp_path / "allowed"),
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "true",
        },
    )
    resp = client.get(
        "/v1/files",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(outside)},
    )
    assert resp.status_code == 403


def test_directory_listing_endpoint(monkeypatch, tmp_path: Path):
    (tmp_path / "src").mkdir(parents=True, exist_ok=True)
    (tmp_path / "README.md").write_text("hello", encoding="utf-8")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )
    resp = client.get(
        "/v1/directories",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(tmp_path)},
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["path"] == str(tmp_path)
    assert payload["entries"][0]["name"] == "src"
    names = [item["name"] for item in payload["entries"]]
    assert "README.md" in names
    assert payload["truncated"] is False


def test_directory_listing_creates_missing_path(monkeypatch, tmp_path: Path):
    missing = tmp_path / "new-folder"
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )
    resp = client.get(
        "/v1/directories",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(missing)},
    )
    assert resp.status_code == 404
    assert not missing.exists()


def test_directory_create_endpoint(monkeypatch, tmp_path: Path):
    missing = tmp_path / "new-folder"
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(tmp_path)},
    )
    create = client.post(
        "/v1/directories",
        headers={"Authorization": f"Bearer {token}"},
        json={"path": str(missing)},
    )
    assert create.status_code == 200
    payload = create.json()
    assert payload["path"] == str(missing)
    assert payload["created"] is True
    assert missing.exists()
    assert missing.is_dir()

    list_resp = client.get(
        "/v1/directories",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(missing)},
    )
    assert list_resp.status_code == 200
    assert list_resp.json()["entries"] == []


def test_directory_listing_rejects_outside_allowed_roots(monkeypatch, tmp_path: Path):
    allowed = tmp_path / "allowed"
    allowed.mkdir(parents=True, exist_ok=True)
    outside = tmp_path / "outside"
    outside.mkdir(parents=True, exist_ok=True)
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={"VOICE_AGENT_FILE_ROOTS": str(allowed)},
    )
    resp = client.get(
        "/v1/directories",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(outside)},
    )
    assert resp.status_code == 403


def test_workdir_restricted_in_safe_mode(monkeypatch, tmp_path: Path):
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={"VOICE_AGENT_SECURITY_MODE": "safe"},
    )
    resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "safe1",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
            "working_directory": "/tmp",
        },
    )
    assert resp.status_code == 400
    assert "working_directory" in resp.json()["detail"]


def test_pair_exchange_returns_api_token_and_rotates_code(monkeypatch, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        (
            '{'
            '"server_url":"http://127.0.0.1:8000",'
            '"api_token":"abc-token",'
            '"session_id":"iphone-app",'
            '"pair_code":"pair-1234",'
            '"pair_code_expires_at":"2999-01-01T00:00:00Z"'
            '}'
        ),
        encoding="utf-8",
    )
    client, _ = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        api_token="abc-token",
        extra_env={"VOICE_AGENT_PAIRING_FILE": str(pairing_file)},
    )
    resp = client.post("/v1/pair/exchange", json={"pair_code": "pair-1234", "session_id": "ios1"})
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["api_token"] == "abc-token"
    assert payload["session_id"] == "ios1"
    updated = pairing_file.read_text(encoding="utf-8")
    assert '"pair_code":"pair-1234"' not in updated.replace(" ", "")


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


def test_codex_thread_resume_by_client_thread_id(monkeypatch, tmp_path: Path):
    fake_codex = tmp_path / "codex"
    fake_codex.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" != \"exec\" ]]; then exit 1; fi\n"
        "shift\n"
        "resume_id=\"\"\n"
        "if [[ \"${1:-}\" == \"resume\" ]]; then\n"
        "  resume_id=\"${2:-}\"\n"
        "  shift 2\n"
        "fi\n"
        "while [[ $# -gt 0 ]]; do\n"
        "  case \"$1\" in\n"
        "    --json|--skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox)\n"
        "      shift\n"
        "      ;;\n"
        "    --model)\n"
        "      shift 2\n"
        "      ;;\n"
        "    *)\n"
        "      break\n"
        "      ;;\n"
        "  esac\n"
        "done\n"
        "if [[ -n \"$resume_id\" ]]; then\n"
        "  thread=\"$resume_id\"\n"
        "  text=\"resumed memory\"\n"
        "else\n"
        "  thread=\"thread-abc\"\n"
        "  text=\"started memory\"\n"
        "fi\n"
        "echo \"{\\\"type\\\":\\\"thread.started\\\",\\\"thread_id\\\":\\\"${thread}\\\"}\"\n"
        "echo \"{\\\"type\\\":\\\"item.completed\\\",\\\"item\\\":{\\\"id\\\":\\\"item_1\\\",\\\"type\\\":\\\"agent_message\\\",\\\"text\\\":\\\"${text}\\\"}}\"\n"
        "echo '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1}}'\n",
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

    create_first = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "session-resume",
            "thread_id": "chat-1",
            "utterance_text": "first prompt",
            "executor": "codex",
        },
    )
    assert create_first.status_code == 200
    first_run_id = create_first.json()["run_id"]

    first_payload = None
    for _ in range(80):
        first_run = client.get(f"/v1/runs/{first_run_id}", headers={"Authorization": f"Bearer {token}"})
        assert first_run.status_code == 200
        first_payload = first_run.json()
        if first_payload["status"] != "running":
            break
        time.sleep(0.05)
    assert first_payload is not None
    assert first_payload["status"] == "completed"
    first_chat_messages = [e["message"] for e in first_payload["events"] if e["type"] == "chat.message"]
    assert any("started memory" in msg for msg in first_chat_messages)

    create_second = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "session-resume",
            "thread_id": "chat-1",
            "utterance_text": "second prompt",
            "executor": "codex",
        },
    )
    assert create_second.status_code == 200
    second_run_id = create_second.json()["run_id"]

    second_payload = None
    for _ in range(80):
        second_run = client.get(f"/v1/runs/{second_run_id}", headers={"Authorization": f"Bearer {token}"})
        assert second_run.status_code == 200
        second_payload = second_run.json()
        if second_payload["status"] != "running":
            break
        time.sleep(0.05)
    assert second_payload is not None
    assert second_payload["status"] == "completed"
    second_chat_messages = [e["message"] for e in second_payload["events"] if e["type"] == "chat.message"]
    assert any("resumed memory" in msg for msg in second_chat_messages)


def test_codex_profile_memory_persists_across_sessions(monkeypatch, tmp_path: Path):
    fake_codex = tmp_path / "codex"
    fake_codex.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "mkdir -p .mobaile\n"
        "state=\"no-memory\"\n"
        "if [[ -f .mobaile/MEMORY.md ]] && grep -q \"workflow-v1\" .mobaile/MEMORY.md; then\n"
        "  state=\"has-memory\"\n"
        "fi\n"
        "cat > .mobaile/MEMORY.md <<'EOF'\n"
        "# MOBaiLE MEMORY\n"
        "## Reliable Workflows\n"
        "- workflow-v1: calendar lookup via macOS Calendar bridge\n"
        "EOF\n"
        "echo \"{\\\"type\\\":\\\"item.completed\\\",\\\"item\\\":{\\\"id\\\":\\\"item_1\\\",\\\"type\\\":\\\"agent_message\\\",\\\"text\\\":\\\"${state}\\\"}}\"\n"
        "echo '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1}}'\n",
        encoding="utf-8",
    )
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    profile_root = tmp_path / "profiles"
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "60",
            "VOICE_AGENT_PROFILE_STATE_ROOT": str(profile_root),
            "VOICE_AGENT_PROFILE_ID": "user-1",
        },
    )

    create_first = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "mem-session-a",
            "utterance_text": "first run",
            "executor": "codex",
        },
    )
    assert create_first.status_code == 200
    first_run_id = create_first.json()["run_id"]

    first_payload = None
    for _ in range(80):
        first_run = client.get(f"/v1/runs/{first_run_id}", headers={"Authorization": f"Bearer {token}"})
        assert first_run.status_code == 200
        first_payload = first_run.json()
        if first_payload["status"] != "running":
            break
        time.sleep(0.05)
    assert first_payload is not None
    assert first_payload["status"] == "completed"
    first_chat_messages = [e["message"] for e in first_payload["events"] if e["type"] == "chat.message"]
    assert any("no-memory" in msg for msg in first_chat_messages)

    create_second = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "mem-session-b",
            "utterance_text": "second run",
            "executor": "codex",
        },
    )
    assert create_second.status_code == 200
    second_run_id = create_second.json()["run_id"]

    second_payload = None
    for _ in range(80):
        second_run = client.get(f"/v1/runs/{second_run_id}", headers={"Authorization": f"Bearer {token}"})
        assert second_run.status_code == 200
        second_payload = second_run.json()
        if second_payload["status"] != "running":
            break
        time.sleep(0.05)
    assert second_payload is not None
    assert second_payload["status"] == "completed"
    second_chat_messages = [e["message"] for e in second_payload["events"] if e["type"] == "chat.message"]
    assert any("has-memory" in msg for msg in second_chat_messages)

    profile_memory = profile_root / "user-1" / "MEMORY.md"
    assert profile_memory.exists()
    assert "workflow-v1" in profile_memory.read_text(encoding="utf-8")
