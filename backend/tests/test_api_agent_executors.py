from __future__ import annotations

import json
import os
from pathlib import Path

from .api_test_support import auth_headers, wait_for_run_to_settle, write_executable


def test_cancel_codex_run(make_client, tmp_path: Path):
    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "echo 'OpenAI Codex fake'\n"
        "sleep 30\n",
    )
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "60",
        },
    )
    headers = auth_headers(token)
    create_resp = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "cancel1",
            "utterance_text": "long codex run",
            "executor": "codex",
        },
    )
    assert create_resp.status_code == 200
    run_id = create_resp.json()["run_id"]

    cancel_resp = client.post(f"/v1/runs/{run_id}/cancel", headers=headers)
    assert cancel_resp.status_code == 200
    assert cancel_resp.json()["status"] == "cancel_requested"

    payload = wait_for_run_to_settle(client, token, run_id)
    assert payload["status"] == "cancelled"
    assert "cancelled" in payload["summary"].lower()


def test_codex_human_unblock_transitions_to_blocked(make_client, tmp_path: Path):
    envelope = json.dumps(
        {
            "type": "assistant_response",
            "version": "1.0",
            "summary": "Human unblock required",
            "sections": [
                {
                    "title": "Human Unblock",
                    "body": "Complete the CAPTCHA in the current browser session, then send a resume reply from the phone.",
                }
            ],
            "agenda_items": [],
            "artifacts": [],
        }
    )
    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "echo '{\"type\":\"thread.started\",\"thread_id\":\"thread-blocked\"}'\n"
        f"echo '{{\"type\":\"item.completed\",\"item\":{{\"type\":\"agent_message\",\"text\":{json.dumps(envelope)}}}}}'\n"
        "sleep 30\n",
    )
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "60",
        },
    )
    headers = auth_headers(token)

    create_resp = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "blocked1",
            "thread_id": "chat-blocked",
            "utterance_text": "open the site and continue",
            "executor": "codex",
        },
    )
    assert create_resp.status_code == 200
    run_id = create_resp.json()["run_id"]

    payload = wait_for_run_to_settle(client, token, run_id)
    assert payload["status"] == "blocked"
    assert "captcha" in payload["summary"].lower()
    assert payload["pending_human_unblock"]["instructions"].startswith("Complete the CAPTCHA")
    assert "suggested_reply" in payload["pending_human_unblock"]
    event_types = [event["type"] for event in payload["events"]]
    assert "run.blocked" in event_types
    activity_events = [event for event in payload["events"] if event["type"].startswith("activity.")]
    assert [event["stage"] for event in activity_events] == ["planning", "executing", "blocked"]
    blocked_activity = next(event for event in activity_events if event["stage"] == "blocked")
    assert blocked_activity["level"] == "warning"
    assert blocked_activity["display_message"].startswith("Complete the CAPTCHA")
    blocked_index = next(index for index, event in enumerate(payload["events"]) if event["type"] == "run.blocked")
    activity_index = next(index for index, event in enumerate(payload["events"]) if event["stage"] == "blocked")
    assert activity_index < blocked_index

    context_resp = client.get("/v1/sessions/blocked1/context", headers=headers)
    assert context_resp.status_code == 200
    context_payload = context_resp.json()
    assert context_payload["latest_run_id"] == run_id
    assert context_payload["latest_run_status"] == "blocked"
    assert context_payload["latest_run_summary"] == payload["summary"]
    assert context_payload["latest_run_pending_human_unblock"]["instructions"].startswith("Complete the CAPTCHA")


def test_codex_run_timeout(make_client, tmp_path: Path):
    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "echo 'OpenAI Codex fake'\n"
        "sleep 2\n",
    )
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "1",
        },
    )
    create_resp = client.post(
        "/v1/utterances",
        headers=auth_headers(token),
        json={
            "session_id": "timeout1",
            "utterance_text": "long codex run",
            "executor": "codex",
        },
    )
    assert create_resp.status_code == 200
    run_id = create_resp.json()["run_id"]

    payload = wait_for_run_to_settle(client, token, run_id)
    assert payload["status"] == "failed"
    assert "timed out" in payload["summary"].lower()


def test_codex_thread_resume_by_client_thread_id(make_client, tmp_path: Path):
    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"--search\" ]]; then\n"
        "  shift\n"
        "fi\n"
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
    )
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "60",
        },
    )
    headers = auth_headers(token)

    create_first = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "session-resume",
            "thread_id": "chat-1",
            "utterance_text": "first prompt",
            "executor": "codex",
        },
    )
    assert create_first.status_code == 200
    first_run_id = create_first.json()["run_id"]

    first_payload = wait_for_run_to_settle(client, token, first_run_id)
    assert first_payload["status"] == "completed"
    first_chat_messages = [e["message"] for e in first_payload["events"] if e["type"] == "chat.message"]
    assert any("started memory" in msg for msg in first_chat_messages)

    create_second = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "session-resume",
            "thread_id": "chat-1",
            "utterance_text": "second prompt",
            "executor": "codex",
        },
    )
    assert create_second.status_code == 200
    second_run_id = create_second.json()["run_id"]

    second_payload = wait_for_run_to_settle(client, token, second_run_id)
    assert second_payload["status"] == "completed"
    second_chat_messages = [e["message"] for e in second_payload["events"] if e["type"] == "chat.message"]
    assert any("resumed memory" in msg for msg in second_chat_messages)


def test_codex_profile_memory_persists_across_sessions(make_client, tmp_path: Path):
    write_executable(
        tmp_path / "codex",
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
    )
    env_path = os.environ.get("PATH", "")
    profile_root = tmp_path / "profiles"
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CODEX_BINARY": "codex",
            "VOICE_AGENT_CODEX_TIMEOUT_SEC": "60",
            "VOICE_AGENT_PROFILE_STATE_ROOT": str(profile_root),
            "VOICE_AGENT_PROFILE_ID": "user-1",
        },
    )
    headers = auth_headers(token)

    create_first = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "mem-session-a",
            "utterance_text": "first run",
            "executor": "codex",
        },
    )
    assert create_first.status_code == 200
    first_run_id = create_first.json()["run_id"]

    first_payload = wait_for_run_to_settle(client, token, first_run_id)
    assert first_payload["status"] == "completed"
    first_chat_messages = [e["message"] for e in first_payload["events"] if e["type"] == "chat.message"]
    assert any("no-memory" in msg for msg in first_chat_messages)

    create_second = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "mem-session-b",
            "utterance_text": "second run",
            "executor": "codex",
        },
    )
    assert create_second.status_code == 200
    second_run_id = create_second.json()["run_id"]

    second_payload = wait_for_run_to_settle(client, token, second_run_id)
    assert second_payload["status"] == "completed"
    second_chat_messages = [e["message"] for e in second_payload["events"] if e["type"] == "chat.message"]
    assert any("has-memory" in msg for msg in second_chat_messages)

    profile_memory = profile_root / "user-1" / "MEMORY.md"
    assert profile_memory.exists()
    assert "workflow-v1" in profile_memory.read_text(encoding="utf-8")


def test_claude_run_streams_assistant_messages_and_resumes_session(make_client, tmp_path: Path):
    write_executable(
        tmp_path / "claude",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "resume_id=\"\"\n"
        "while [[ $# -gt 0 ]]; do\n"
        "  case \"$1\" in\n"
        "    -p)\n"
        "      shift 2\n"
        "      ;;\n"
        "    --resume)\n"
        "      resume_id=\"${2:-}\"\n"
        "      shift 2\n"
        "      ;;\n"
        "    --output-format|--permission-mode)\n"
        "      shift 2\n"
        "      ;;\n"
        "    --verbose|--dangerously-skip-permissions)\n"
        "      shift\n"
        "      ;;\n"
        "    *)\n"
        "      shift\n"
        "      ;;\n"
        "  esac\n"
        "done\n"
        "if [[ -n \"$resume_id\" ]]; then\n"
        "  session=\"$resume_id\"\n"
        "  text=\"continued from claude\"\n"
        "else\n"
        "  session=\"claude-session-1\"\n"
        "  text=\"started from claude\"\n"
        "fi\n"
        "echo \"{\\\"type\\\":\\\"system\\\",\\\"session_id\\\":\\\"${session}\\\"}\"\n"
        "echo \"{\\\"type\\\":\\\"assistant\\\",\\\"session_id\\\":\\\"${session}\\\",\\\"message\\\":{\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"${text}\\\"}]}}\"\n"
        "echo \"{\\\"type\\\":\\\"result\\\",\\\"session_id\\\":\\\"${session}\\\",\\\"result\\\":\\\"ok\\\"}\"\n",
    )
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CLAUDE_BINARY": "claude",
            "VOICE_AGENT_CLAUDE_TIMEOUT_SEC": "60",
        },
    )
    headers = auth_headers(token)

    create_first = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "claude-resume",
            "thread_id": "chat-claude",
            "utterance_text": "first prompt",
            "executor": "claude",
        },
    )
    assert create_first.status_code == 200
    first_run_id = create_first.json()["run_id"]

    first_payload = wait_for_run_to_settle(client, token, first_run_id)
    assert first_payload["status"] == "completed"
    first_chat_messages = [e["message"] for e in first_payload["events"] if e["type"] == "chat.message"]
    assert any("started from claude" in msg for msg in first_chat_messages)

    create_second = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "claude-resume",
            "thread_id": "chat-claude",
            "utterance_text": "second prompt",
            "executor": "claude",
        },
    )
    assert create_second.status_code == 200
    second_run_id = create_second.json()["run_id"]

    second_payload = wait_for_run_to_settle(client, token, second_run_id)
    assert second_payload["status"] == "completed"
    second_chat_messages = [e["message"] for e in second_payload["events"] if e["type"] == "chat.message"]
    assert any("continued from claude" in msg for msg in second_chat_messages)
