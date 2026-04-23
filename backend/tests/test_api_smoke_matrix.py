from __future__ import annotations

import json
import os
from pathlib import Path

from .api_test_support import auth_headers, wait_for_run_to_settle, write_executable


def _make_codex_client(make_client, tmp_path: Path, *, extra_env: dict[str, str] | None = None):
    env_path = os.environ.get("PATH", "")
    env = {
        "PATH": f"{tmp_path}:{env_path}",
        "VOICE_AGENT_CODEX_BINARY": "codex",
        "VOICE_AGENT_CODEX_TIMEOUT_SEC": "60",
    }
    if extra_env:
        env.update(extra_env)
    return make_client(provider="mock", extra_env=env)


def test_api_smoke_matrix_stream_and_cancel(make_client, tmp_path: Path) -> None:
    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"--search\" ]]; then\n"
        "  shift\n"
        "fi\n"
        "if [[ \"${1:-}\" != \"exec\" ]]; then\n"
        "  exit 1\n"
        "fi\n"
        "shift\n"
        "if [[ \"${1:-}\" == \"resume\" ]]; then\n"
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
        "    -c)\n"
        "      shift 2\n"
        "      ;;\n"
        "    *)\n"
        "      break\n"
        "      ;;\n"
        "  esac\n"
        "done\n"
        "echo '{\"type\":\"thread.started\",\"thread_id\":\"thread-stream\"}'\n"
        "echo '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"agent_message\",\"text\":\"stream payload\"}}'\n"
        "echo '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1}}'\n",
    )
    client, token = _make_codex_client(make_client, tmp_path)
    headers = auth_headers(token)

    stream_resp = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "smoke-stream",
            "thread_id": "chat-stream",
            "utterance_text": "stream a run and settle cleanly",
            "executor": "codex",
        },
    )
    assert stream_resp.status_code == 200
    stream_run_id = stream_resp.json()["run_id"]

    stream_payload = wait_for_run_to_settle(client, token, stream_run_id)
    assert stream_payload["status"] == "completed"

    events_resp = client.get(f"/v1/runs/{stream_run_id}/events?after_seq=-1", headers=headers)
    assert events_resp.status_code == 200
    assert "event: activity.started" in events_resp.text
    assert "event: action.started" in events_resp.text

    write_executable(
        tmp_path / "codex",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"--search\" ]]; then\n"
        "  shift\n"
        "fi\n"
        "if [[ \"${1:-}\" != \"exec\" ]]; then\n"
        "  exit 1\n"
        "fi\n"
        "shift\n"
        "if [[ \"${1:-}\" == \"resume\" ]]; then\n"
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
        "    -c)\n"
        "      shift 2\n"
        "      ;;\n"
        "    *)\n"
        "      break\n"
        "      ;;\n"
        "  esac\n"
        "done\n"
        "echo '{\"type\":\"thread.started\",\"thread_id\":\"thread-stream\"}'\n"
        "echo '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"agent_message\",\"text\":\"stream payload\"}}'\n"
        "sleep 30\n",
    )

    cancel_create = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "smoke-cancel",
            "thread_id": "chat-cancel",
            "utterance_text": "keep the run active long enough to cancel it",
            "executor": "codex",
        },
    )
    assert cancel_create.status_code == 200
    cancel_run_id = cancel_create.json()["run_id"]

    cancel_resp = client.post(f"/v1/runs/{cancel_run_id}/cancel", headers=headers)
    assert cancel_resp.status_code == 200
    assert cancel_resp.json()["status"] == "cancel_requested"

    payload = wait_for_run_to_settle(client, token, cancel_run_id)
    assert payload["status"] == "cancelled"
    assert "cancelled" in payload["summary"].lower()


def test_api_smoke_matrix_blocked_then_resume_same_thread(make_client, tmp_path: Path) -> None:
    blocked_envelope = json.dumps(
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
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"--search\" ]]; then\n"
        "  shift\n"
        "fi\n"
        "if [[ \"${1:-}\" != \"exec\" ]]; then\n"
        "  exit 1\n"
        "fi\n"
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
        "    -c)\n"
        "      shift 2\n"
        "      ;;\n"
        "    *)\n"
        "      break\n"
        "      ;;\n"
        "  esac\n"
        "done\n"
        "if [[ -n \"$resume_id\" ]]; then\n"
        "  echo \"{\\\"type\\\":\\\"thread.started\\\",\\\"thread_id\\\":\\\"${resume_id}\\\"}\"\n"
        "  echo '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"resumed after unblock\"}}'\n"
        "  echo '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":2,\"cached_input_tokens\":0,\"output_tokens\":1}}'\n"
        "else\n"
        f"  echo '{{\"type\":\"thread.started\",\"thread_id\":\"thread-blocked\"}}'\n"
        f"  echo '{{\"type\":\"item.completed\",\"item\":{{\"id\":\"item_1\",\"type\":\"agent_message\",\"text\":{json.dumps(blocked_envelope)}}}}}'\n"
        "  sleep 30\n"
        "fi\n",
    )
    client, token = _make_codex_client(make_client, tmp_path)
    headers = auth_headers(token)

    first_create = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "smoke-resume",
            "thread_id": "chat-resume",
            "utterance_text": "hit the unblock path and preserve the thread",
            "executor": "codex",
        },
    )
    assert first_create.status_code == 200
    first_run_id = first_create.json()["run_id"]

    first_payload = wait_for_run_to_settle(client, token, first_run_id)
    assert first_payload["status"] == "blocked"
    assert "captcha" in first_payload["summary"].lower()
    assert first_payload["pending_human_unblock"]["instructions"].startswith("Complete the CAPTCHA")

    first_context = client.get("/v1/sessions/smoke-resume/context", headers=headers)
    assert first_context.status_code == 200
    first_context_payload = first_context.json()
    assert first_context_payload["latest_run_id"] == first_run_id
    assert first_context_payload["latest_run_status"] == "blocked"
    assert first_context_payload["latest_run_pending_human_unblock"]["instructions"].startswith(
        "Complete the CAPTCHA"
    )

    second_create = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "smoke-resume",
            "thread_id": "chat-resume",
            "utterance_text": "resume after the unblock step",
            "executor": "codex",
        },
    )
    assert second_create.status_code == 200
    second_run_id = second_create.json()["run_id"]

    second_payload = wait_for_run_to_settle(client, token, second_run_id)
    assert second_payload["status"] == "completed"
    second_chat_messages = [event["message"] for event in second_payload["events"] if event["type"] == "chat.message"]
    assert any("resumed after unblock" in message for message in second_chat_messages)

    second_context = client.get("/v1/sessions/smoke-resume/context", headers=headers)
    assert second_context.status_code == 200
    second_context_payload = second_context.json()
    assert second_context_payload["latest_run_id"] == second_run_id
    assert second_context_payload["latest_run_status"] == "completed"
    assert second_context_payload["latest_run_pending_human_unblock"] is None
