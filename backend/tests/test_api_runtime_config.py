from __future__ import annotations

import json
import os
from io import BytesIO
from pathlib import Path

from .api_test_support import auth_headers, wait_for_run_to_settle, write_executable


def test_runtime_config_includes_codex_model(make_client, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        json.dumps(
            {
                "server_url": "https://relay.example.com",
                "server_urls": [
                    "https://relay.example.com",
                    "http://100.111.99.51:8000",
                ],
                "session_id": "iphone-app",
                "pair_code": "pair-1234",
                "pair_code_expires_at": "2999-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    write_executable(tmp_path / "codex", "#!/usr/bin/env bash\nexit 0\n")
    write_executable(tmp_path / "claude", "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_MODEL": "gpt-5.1",
            "VOICE_AGENT_CODEX_REASONING_EFFORT": "high",
            "VOICE_AGENT_CLAUDE_MODEL": "claude-sonnet-4-5",
            "VOICE_AGENT_CODEX_MODEL_OPTIONS": "gpt-5.4-mini,custom-codex,gpt-5.4-mini",
            "VOICE_AGENT_CLAUDE_MODEL_OPTIONS": "claude-opus-4,claude-sonnet-4-5",
            "VOICE_AGENT_CODEX_REASONING_EFFORT_OPTIONS": "high,medium,turbo,high",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "claude",
            "VOICE_AGENT_PAIRING_FILE": str(pairing_file),
        },
    )
    resp = client.get("/v1/config", headers=auth_headers(token))
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["codex_model"] == "gpt-5.1"
    assert payload["codex_model_options"] == ["gpt-5.4-mini", "custom-codex", "gpt-5.4", "gpt-5.1"]
    assert payload["codex_reasoning_effort"] == "high"
    assert payload["codex_reasoning_effort_options"] == ["high", "medium", "minimal", "low", "xhigh"]
    assert payload["claude_model"] == "claude-sonnet-4-5"
    assert payload["claude_model_options"] == ["claude-opus-4", "claude-sonnet-4-5"]
    assert payload["default_executor"] == "claude"
    assert "codex" in payload["available_executors"]
    assert "claude" in payload["available_executors"]
    assert "local" not in payload["available_executors"]
    executors = {item["id"]: item for item in payload["executors"]}
    assert executors["codex"]["kind"] == "agent"
    assert executors["codex"]["model"] == "gpt-5.1"
    assert [setting["id"] for setting in executors["codex"]["settings"]] == [
        "model",
        "reasoning_effort",
        "profile_agents",
        "profile_memory",
    ]
    assert executors["codex"]["settings"][0]["kind"] == "enum"
    assert executors["codex"]["settings"][0]["allow_custom"] is True
    assert executors["codex"]["settings"][0]["value"] == "gpt-5.1"
    assert executors["codex"]["settings"][0]["options"] == ["gpt-5.4-mini", "custom-codex", "gpt-5.4", "gpt-5.1"]
    assert executors["codex"]["settings"][1]["allow_custom"] is False
    assert executors["codex"]["settings"][1]["value"] == "high"
    assert executors["codex"]["settings"][1]["options"] == ["high", "medium", "minimal", "low", "xhigh"]
    assert [setting["id"] for setting in executors["claude"]["settings"]] == [
        "model",
        "profile_agents",
        "profile_memory",
    ]
    assert executors["claude"]["settings"][0]["allow_custom"] is True
    assert executors["claude"]["settings"][0]["value"] == "claude-sonnet-4-5"
    assert executors["claude"]["settings"][0]["options"] == ["claude-opus-4", "claude-sonnet-4-5"]
    assert executors["local"]["settings"] == []
    assert executors["claude"]["default"] is True
    assert executors["local"]["internal_only"] is True
    assert payload["transcribe_provider"] == "mock"
    assert payload["transcribe_ready"] is True
    assert payload["server_url"] == "https://relay.example.com"
    assert payload["server_urls"][0] == "https://relay.example.com"
    assert "http://100.111.99.51:8000" in payload["server_urls"][1:]


def test_utterance_and_audio_omit_executor_use_resolved_default(make_client, tmp_path: Path):
    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "echo '{\"type\":\"thread.started\",\"thread_id\":\"thread-abc\"}'\n"
        "echo '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}'\n"
        "echo '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1}}'\n",
    )
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
        },
    )
    headers = auth_headers(token)

    utterance_resp = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "default-executor-text",
            "utterance_text": "inspect this repo",
        },
    )
    assert utterance_resp.status_code == 200
    text_run_id = utterance_resp.json()["run_id"]

    audio_resp = client.post(
        "/v1/audio",
        headers=headers,
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={
            "session_id": "default-executor-audio",
            "transcript_hint": "inspect this repo",
        },
    )
    assert audio_resp.status_code == 200
    audio_run_id = audio_resp.json()["run_id"]

    text_payload = wait_for_run_to_settle(client, token, text_run_id)
    assert text_payload["status"] == "completed"
    assert text_payload["executor"] == "codex"
    text_activity_stages = [
        e["stage"] for e in text_payload["events"] if e["type"].startswith("activity.")
    ]
    assert text_activity_stages == ["planning", "executing", "summarizing"]

    audio_payload = wait_for_run_to_settle(client, token, audio_run_id)
    assert audio_payload["status"] == "completed"
    assert audio_payload["executor"] == "codex"
    audio_activity_stages = [
        e["stage"] for e in audio_payload["events"] if e["type"].startswith("activity.")
    ]
    assert audio_activity_stages[:2] == ["transcribing", "transcribing"]
    assert audio_activity_stages[-3:] == ["planning", "executing", "summarizing"]


def test_capabilities_endpoint_returns_report(make_client, tmp_path: Path):
    client, token = make_client(provider="mock")
    resp = client.get("/v1/capabilities", headers=auth_headers(token))
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["report_path"] == str(tmp_path / "capabilities.json")
    capability_ids = {item["id"] for item in payload["capabilities"]}
    assert "codex_cli" in capability_ids
    assert "uv_cli" in capability_ids
    assert "npx_cli" in capability_ids
    assert "transcribe_provider" in capability_ids
    assert "codex_web_search" in capability_ids
    assert "codex_mcp_playwright" in capability_ids
    assert "codex_mcp_peekaboo" in capability_ids
    assert "playwright_persistence" in capability_ids
    assert "peekaboo_permissions" in capability_ids
    assert "calendar_adapter" in capability_ids
    report_path = tmp_path / "capabilities.json"
    assert report_path.exists()
    report_payload = json.loads(report_path.read_text(encoding="utf-8"))
    assert report_payload["checked_at"]
    assert "claude_cli" in capability_ids


def test_capabilities_light_probe_defers_subprocess_checks(make_client, tmp_path: Path):
    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "if [[ \"${1:-}\" == \"mcp\" ]]; then\n"
        "  echo 'mcp probe should be deep-only' >&2\n"
        "  exit 42\n"
        "fi\n"
        "exit 0\n",
    )
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
        },
    )

    resp = client.get("/v1/capabilities", headers=auth_headers(token))

    assert resp.status_code == 200
    by_id = {item["id"]: item for item in resp.json()["capabilities"]}
    assert by_id["codex_mcp_playwright"]["code"] == "deep_probe_required"
    assert by_id["codex_mcp_peekaboo"]["code"] == "deep_probe_required"
    assert by_id["peekaboo_permissions"]["code"] == "deep_probe_required"


def test_config_endpoint_keeps_local_as_internal_fallback_when_binaries_are_missing(make_client, tmp_path: Path):
    empty_path = tmp_path / "empty-bin"
    empty_path.mkdir()
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": str(empty_path),
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
        },
    )
    resp = client.get("/v1/config", headers=auth_headers(token))
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["default_executor"] == "local"
    assert payload["available_executors"] == []
    executors = {item["id"]: item for item in payload["executors"]}
    assert executors["local"]["default"] is True
    assert executors["codex"]["available"] is False
    assert executors["claude"]["available"] is False


def test_capabilities_openai_probe_requires_key(make_client):
    client, token = make_client(
        provider="openai",
        openai_api_key="",
    )
    resp = client.get("/v1/capabilities", headers=auth_headers(token))
    assert resp.status_code == 200
    payload = resp.json()
    by_id = {item["id"]: item for item in payload["capabilities"]}
    transcribe_probe = by_id["transcribe_provider"]
    assert transcribe_probe["status"] == "blocked"
    assert transcribe_probe["code"] == "auth_missing"


def test_config_endpoint_reports_openai_transcription_not_ready_without_key(make_client):
    client, token = make_client(
        provider="openai",
        openai_api_key="",
    )
    resp = client.get("/v1/config", headers=auth_headers(token))
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["transcribe_provider"] == "openai"
    assert payload["transcribe_ready"] is False


def test_explicit_unavailable_executor_returns_conflict(make_client, tmp_path: Path):
    empty_path = tmp_path / "empty-bin"
    empty_path.mkdir()
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": str(empty_path),
            "VOICE_AGENT_CODEX_BINARY": "codex",
        },
    )

    resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "missing-codex",
            "utterance_text": "inspect this repo",
            "executor": "codex",
        },
    )

    assert resp.status_code == 409
    assert "executor codex is not available" in resp.json()["detail"]
