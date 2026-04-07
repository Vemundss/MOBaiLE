from __future__ import annotations

import importlib
import json
import os
import threading
import time
from io import BytesIO
from pathlib import Path

from fastapi.testclient import TestClient

from app.models.schemas import AgendaItem, RunRecord


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
    monkeypatch.setenv("VOICE_AGENT_CAPABILITIES_REPORT_PATH", str(tmp_path / "capabilities.json"))
    if extra_env:
        for key, value in extra_env.items():
            monkeypatch.setenv(key, value)
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    return TestClient(module.app), api_token


def test_runtime_agent_prompt_injects_context(monkeypatch, tmp_path: Path):
    context_file = tmp_path / "ctx.md"
    context_file.write_text("You are in test context.", encoding="utf-8")
    monkeypatch.setenv("VOICE_AGENT_USE_RUNTIME_CONTEXT", "true")
    monkeypatch.setenv("VOICE_AGENT_RUNTIME_CONTEXT_FILE", str(context_file))
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    built = module.ENV.build_runtime_agent_prompt("create hello script", executor="codex")
    assert "MOBaiLE runtime context" in built
    assert "You are in test context." in built
    assert "create hello script" in built


def test_profile_memory_seed_and_prompt_block(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_PROFILE_STATE_ROOT", str(tmp_path / "profiles"))
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    agents, memory = module.PROFILE_STORE.load_context()
    assert "MOBaiLE AGENTS" in agents
    assert "MOBaiLE MEMORY" in memory

    built = module.ENV.build_runtime_agent_prompt(
        "check calendar today",
        executor="codex",
        profile_agents=agents,
        profile_memory=memory,
    )
    assert "Persistent AGENTS profile" in built
    assert "Persistent MEMORY" in built
    assert "~/.codex" in built
    assert "Prefer the least-fragile control surface" in built
    assert "Ask before installing packages user-wide or system-wide." in built
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

    module.PROFILE_STORE.sync_memory_from_workdir(primary)

    profile_memory = tmp_path / "profiles" / "user-fallback" / "MEMORY.md"
    assert profile_memory.exists()
    text = profile_memory.read_text(encoding="utf-8")
    assert "new durable note" in text
    assert "old memory" not in text


def test_codex_output_filter_drops_runtime_noise(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    user_prompt = "create a python file"
    leak_markers = module.ENV.runtime_context_leak_markers()

    assert module.filter_codex_assistant_message("/bin/zsh -lc \"python3 hello.py\"", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("tokens used", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("You are running through MOBaiLE.", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("MOBaiLE runtime context:", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("You are the coding agent used by MOBaiLE.", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("Product intent: MOBaiLE makes a user's computer available from their phone.", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("Backend activity events are the source of truth for progress in the phone UI.", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("Do not dump raw logs or long command output unless the user asks.", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("Keep responses concise and grouped; avoid verbose step-by-step chatter.", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("```text", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("Created `hello.py` and ran it successfully.", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("1,147", user_prompt, leak_markers) is None
    assert module.filter_codex_assistant_message("Done. Created hello.py.", user_prompt, leak_markers) == "Done. Created hello.py."


def test_codex_assistant_extractor_emits_only_assistant_blocks(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    extractor = module.CodexAssistantExtractor("hello", module.ENV.runtime_context_leak_markers())
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
    module = importlib.import_module("app.chat_envelope")
    module = importlib.reload(module)
    payload = '{"type":"assistant_response","version":"1.0","summary":"ok","sections":[],"agenda_items":[]}'
    parsed = module.parse_chat_envelope_payload(payload)
    assert parsed is not None
    assert parsed["type"] == "assistant_response"
    wrapped = json.dumps(payload)
    parsed_wrapped = module.parse_chat_envelope_payload(wrapped)
    assert parsed_wrapped is not None
    assert parsed_wrapped["summary"] == "ok"


def test_merge_assistant_lines_adds_structure(monkeypatch, tmp_path: Path):
    module = importlib.import_module("app.chat_envelope")
    module = importlib.reload(module)
    merged = module.merge_assistant_lines(
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
    module = importlib.import_module("app.chat_envelope")
    module = importlib.reload(module)
    envelope = module.coerce_assistant_text_to_envelope(
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
    module = importlib.import_module("app.main")
    module.RUN_STATE.append_activity_event(
        run_id,
        stage="executing",
        title="Executing",
        display_message="Running commands.",
    )

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
    assert diagnostics["activity_stage_counts"] == {
        "planning": 1,
        "executing": 2,
        "summarizing": 1,
    }
    assert diagnostics["latest_activity"] == "Preparing the final result."


def test_run_events_endpoint_includes_typed_activity_payload(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path)
    create = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "sess-activity-events",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    final_run: dict[str, object] | None = None
    for _ in range(40):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        payload = run_resp.json()
        if payload["status"] != "running":
            final_run = payload
            break
        time.sleep(0.05)

    assert final_run is not None
    pivot_seq = int(final_run["events"][-1]["seq"])
    module = importlib.import_module("app.main")
    module.RUN_STATE.append_activity_event(
        run_id,
        stage="executing",
        title="Executing",
        display_message="Running commands.",
    )

    response = client.get(
        f"/v1/runs/{run_id}/events?after_seq={pivot_seq}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert '"type": "activity.updated"' in response.text
    assert '"stage": "executing"' in response.text
    assert '"title": "Executing"' in response.text


def test_run_diagnostics_endpoint_reports_activity_errors(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path)
    module = importlib.import_module("app.main")
    module.RUN_STATE.store_run(
        RunRecord(
            run_id="run-diagnostics-error",
            session_id="sess-diagnostics-error",
            executor="local",
            utterance_text="check the failing integration",
            status="failed",
            summary="The calendar adapter failed before the summary was ready.",
            events=[],
        )
    )
    module.RUN_STATE.append_activity_event(
        "run-diagnostics-error",
        stage="executing",
        title="Executing",
        display_message="Calendar query failed.",
        level="error",
    )

    diag = client.get(
        "/v1/runs/run-diagnostics-error/diagnostics",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert diag.status_code == 200
    diagnostics = diag.json()
    assert diagnostics["run_id"] == "run-diagnostics-error"
    assert diagnostics["has_stderr"] is False
    assert diagnostics["last_error"] == "Calendar query failed."
    assert diagnostics["latest_activity"] == "Calendar query failed."
    assert diagnostics["activity_stage_counts"] == {"executing": 1}


def test_run_events_endpoint_replays_from_after_seq(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path)
    create = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "sess-events",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    final_run: dict[str, object] | None = None
    for _ in range(40):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        payload = run_resp.json()
        if payload["status"] != "running":
            final_run = payload
            break
        time.sleep(0.05)

    assert final_run is not None
    all_events = final_run["events"]
    assert len(all_events) >= 2
    pivot_seq = int(all_events[0]["seq"])

    response = client.get(
        f"/v1/runs/{run_id}/events?after_seq={pivot_seq}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200

    replayed_events = []
    for chunk in response.text.split("\n\n"):
        data_lines = []
        for line in chunk.splitlines():
            if line.startswith("data:"):
                raw = line[5:]
                data_lines.append(raw[1:] if raw.startswith(" ") else raw)
        if data_lines:
            replayed_events.append(json.loads("\n".join(data_lines)))

    assert replayed_events
    assert [event["seq"] for event in replayed_events] == [event["seq"] for event in all_events[1:]]


def test_session_context_updates_and_runs_inherit_defaults(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "VOICE_AGENT_DEFAULT_EXECUTOR": "local",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": "missing-codex",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    initial = client.get(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert initial.status_code == 200
    assert initial.json()["executor"] == "local"
    assert initial.json()["working_directory"] is None
    assert initial.json()["resolved_working_directory"] == str(workspace)
    assert initial.json()["latest_run_id"] is None
    assert initial.json()["latest_run_status"] is None

    project_dir = workspace / "project"
    update = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "executor": "local",
            "working_directory": str(project_dir),
        },
    )
    assert update.status_code == 200
    updated = update.json()
    assert updated["session_id"] == "sess-context"
    assert updated["executor"] == "local"
    assert updated["working_directory"] == str(project_dir)
    assert updated["resolved_working_directory"] == str(project_dir)

    create = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "sess-context",
            "utterance_text": "create a hello python script and run it",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    run = client.get(
        f"/v1/runs/{run_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert run.status_code == 200
    run_payload = run.json()
    assert run_payload["executor"] == "local"
    assert run_payload["working_directory"] == str(project_dir)

    refreshed = client.get(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert refreshed.status_code == 200
    refreshed_payload = refreshed.json()
    assert refreshed_payload["latest_run_id"] == run_id
    assert refreshed_payload["latest_run_status"] == "running"
    assert refreshed_payload["latest_run_summary"] == "Run started"
    assert refreshed_payload["latest_run_pending_human_unblock"] is None


def test_session_context_rejects_unavailable_executor(monkeypatch, tmp_path: Path):
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "VOICE_AGENT_DEFAULT_EXECUTOR": "local",
            "VOICE_AGENT_CODEX_BINARY": "missing-codex",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    response = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={"executor": "codex"},
    )

    assert response.status_code == 400
    assert "not available" in response.json()["detail"]


def test_session_context_persists_runtime_overrides(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_MODEL": "gpt-5.4",
            "VOICE_AGENT_CODEX_REASONING_EFFORT": "medium",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    response = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "executor": "codex",
            "runtime_settings": [
                {"executor": "codex", "id": "model", "value": "gpt-5.4-mini"},
                {"executor": "codex", "id": "reasoning_effort", "value": "xhigh"},
            ],
        },
    )

    assert response.status_code == 200
    payload = response.json()
    runtime_settings = {
        (item["executor"], item["id"]): item["value"] for item in payload["runtime_settings"]
    }
    assert payload["executor"] == "codex"
    assert payload["codex_model"] == "gpt-5.4-mini"
    assert payload["codex_reasoning_effort"] == "xhigh"
    assert payload["claude_model"] is None
    assert runtime_settings[("codex", "model")] == "gpt-5.4-mini"
    assert runtime_settings[("codex", "reasoning_effort")] == "xhigh"
    assert runtime_settings[("claude", "model")] is None


def test_session_context_rejects_invalid_codex_effort(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    response = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={"runtime_settings": [{"executor": "codex", "id": "reasoning_effort", "value": "turbo"}]},
    )

    assert response.status_code == 400
    assert "must be one of" in response.json()["detail"]


def test_session_context_runtime_settings_can_clear_overrides(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_MODEL": "gpt-5.4",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    initial = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "runtime_settings": [
                {"executor": "codex", "id": "model", "value": "gpt-5.4-mini"},
                {"executor": "codex", "id": "reasoning_effort", "value": "high"},
            ],
        },
    )
    assert initial.status_code == 200

    cleared = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "runtime_settings": [
                {"executor": "codex", "id": "model", "value": None},
                {"executor": "codex", "id": "reasoning_effort", "value": None},
            ],
        },
    )

    assert cleared.status_code == 200
    payload = cleared.json()
    runtime_settings = {
        (item["executor"], item["id"]): item["value"] for item in payload["runtime_settings"]
    }
    assert payload["codex_model"] is None
    assert payload["codex_reasoning_effort"] is None
    assert runtime_settings[("codex", "model")] is None
    assert runtime_settings[("codex", "reasoning_effort")] is None


def test_session_context_runtime_settings_payload_replaces_existing_state(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    seeded = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "runtime_settings": [
                {"executor": "codex", "id": "model", "value": "gpt-5.4-mini"},
                {"executor": "codex", "id": "reasoning_effort", "value": "high"},
            ],
        },
    )
    assert seeded.status_code == 200

    replaced = client.patch(
        "/v1/sessions/sess-context/context",
        headers={"Authorization": f"Bearer {token}"},
        json={"runtime_settings": []},
    )

    assert replaced.status_code == 200
    payload = replaced.json()
    runtime_settings = {
        (item["executor"], item["id"]): item["value"] for item in payload["runtime_settings"]
    }
    assert payload["codex_model"] is None
    assert payload["codex_reasoning_effort"] is None
    assert runtime_settings[("codex", "model")] is None
    assert runtime_settings[("codex", "reasoning_effort")] is None


def test_slash_command_catalog_and_execution(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "VOICE_AGENT_DEFAULT_EXECUTOR": "local",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": "missing-codex",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    catalog = client.get(
        "/v1/slash-commands",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert catalog.status_code == 200
    payload = catalog.json()
    assert [item["id"] for item in payload] == ["cwd", "executor"]
    assert payload[0]["group"] == "Runtime"
    assert payload[1]["usage"] == "/executor [local]"
    assert payload[1]["argument_options"] == ["local"]

    project_dir = workspace / "project"
    cwd_response = client.post(
        "/v1/sessions/sess-context/slash-commands/cwd",
        headers={"Authorization": f"Bearer {token}"},
        json={"arguments": str(project_dir)},
    )
    assert cwd_response.status_code == 200
    cwd_payload = cwd_response.json()
    assert cwd_payload["command_id"] == "cwd"
    assert cwd_payload["session_context"]["working_directory"] == str(project_dir)
    assert cwd_payload["session_context"]["resolved_working_directory"] == str(project_dir)

    executor_response = client.post(
        "/v1/sessions/sess-context/slash-commands/executor",
        headers={"Authorization": f"Bearer {token}"},
        json={"arguments": "local"},
    )
    assert executor_response.status_code == 200
    executor_payload = executor_response.json()
    assert executor_payload["command_id"] == "executor"
    assert executor_payload["session_context"]["executor"] == "local"
    assert "Available: local." in executor_payload["message"]


def test_slash_command_catalog_includes_model_and_effort_for_codex(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": str(fake_codex),
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    catalog = client.get(
        "/v1/slash-commands",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert catalog.status_code == 200
    payload = catalog.json()
    ids = [item["id"] for item in payload]
    assert ids == ["cwd", "executor", "model", "effort"]
    assert payload[2]["title"] == "Model Override"
    assert payload[3]["argument_options"] == ["backend-default", "minimal", "low", "medium", "high", "xhigh"]

    model_response = client.post(
        "/v1/sessions/sess-context/slash-commands/model",
        headers={"Authorization": f"Bearer {token}"},
        json={"arguments": "gpt-5.4-mini"},
    )
    assert model_response.status_code == 200
    assert model_response.json()["session_context"]["codex_model"] == "gpt-5.4-mini"

    effort_response = client.post(
        "/v1/sessions/sess-context/slash-commands/effort",
        headers={"Authorization": f"Bearer {token}"},
        json={"arguments": "high"},
    )
    assert effort_response.status_code == 200
    assert effort_response.json()["session_context"]["codex_reasoning_effort"] == "high"


def test_slash_commands_follow_runtime_setting_registry(monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": str(fake_codex),
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )
    module = importlib.import_module("app.main")
    schemas = importlib.import_module("app.models.schemas")

    def fake_runtime_executor_descriptors():
        return [
            schemas.RuntimeExecutorDescriptor(
                id="local",
                title="Local fallback",
                kind="internal",
                available=True,
                default=False,
                internal_only=True,
            ),
            schemas.RuntimeExecutorDescriptor(
                id="codex",
                title="Codex",
                kind="agent",
                available=True,
                default=True,
                settings=[
                    schemas.RuntimeSettingDescriptor(
                        id="model",
                        title="Model",
                        kind="enum",
                        allow_custom=True,
                        value="gpt-5.4",
                        options=["gpt-5.4", "gpt-5.4-mini"],
                    ),
                    schemas.RuntimeSettingDescriptor(
                        id="reasoning_effort",
                        title="Reasoning Effort",
                        kind="enum",
                        allow_custom=False,
                        value="medium",
                        options=["low", "medium", "high"],
                    ),
                    schemas.RuntimeSettingDescriptor(
                        id="verbosity",
                        title="Verbosity",
                        kind="enum",
                        allow_custom=False,
                        value="concise",
                        options=["concise", "detailed"],
                    ),
                ],
            ),
        ]

    monkeypatch.setattr(
        module.RuntimeEnvironment,
        "runtime_executor_descriptors",
        lambda self: fake_runtime_executor_descriptors(),
    )

    catalog = client.get(
        "/v1/slash-commands",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert catalog.status_code == 200
    payload = catalog.json()
    assert [item["id"] for item in payload] == ["cwd", "executor", "model", "effort", "verbosity"]
    assert payload[-1]["usage"] == "/verbosity [backend-default|concise|detailed]"

    response = client.post(
        "/v1/sessions/sess-context/slash-commands/verbosity",
        headers={"Authorization": f"Bearer {token}"},
        json={"arguments": "detailed"},
    )
    assert response.status_code == 200
    runtime_settings = {
        (item["executor"], item["id"]): item["value"] for item in response.json()["session_context"]["runtime_settings"]
    }
    assert runtime_settings[("codex", "verbosity")] == "detailed"


def test_calendar_adapter_flow(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
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
    activity_stages = [e["stage"] for e in payload["events"] if e["type"].startswith("activity.")]
    assert activity_stages == ["planning", "executing", "summarizing"]
    chat_events = [e for e in payload["events"] if e["type"] == "chat.message"]
    assert len(chat_events) >= 1
    assert "\"assistant_response\"" in chat_events[0]["message"]


def test_calendar_adapter_failure_emits_error_activity(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
    module = importlib.import_module("app.main")

    def failing_events():
        raise RuntimeError("calendar unavailable")

    monkeypatch.setattr(module.CALENDAR_SERVICE, "fetch_today_events", failing_events)

    resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "cal-fail",
            "utterance_text": "Check my calendar today",
            "executor": "codex",
        },
    )
    assert resp.status_code == 200
    run_id = resp.json()["run_id"]

    payload = None
    for _ in range(40):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        payload = run_resp.json()
        if payload["status"] != "running":
            break
        time.sleep(0.05)

    assert payload is not None
    assert payload["status"] == "failed"
    activity_events = [event for event in payload["events"] if event["type"].startswith("activity.")]
    assert [event["stage"] for event in activity_events] == ["planning", "executing", "executing"]
    assert activity_events[-1]["level"] == "error"
    assert activity_events[-1]["display_message"] == "Calendar query failed."


def test_calendar_today_returns_structured_unsupported_response_on_linux(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
    monkeypatch.setattr("app.calendar_service.os.uname", lambda: type("Uname", (), {"sysname": "Linux"})())

    resp = client.get(
        "/v1/tools/calendar/today",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 503
    payload = resp.json()
    assert payload["supported"] is False
    assert payload["count"] == 0
    assert "macOS" in payload["detail"]


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
    assert payload is not None
    activity_stages = [e["stage"] for e in payload["events"] if e["type"].startswith("activity.")]
    assert activity_stages == ["planning", "executing", "summarizing"]


def test_local_utterance_flow_accepts_typed_attachments(monkeypatch, tmp_path: Path):
    attached = tmp_path / "workspace" / "notes.txt"
    attached.parent.mkdir(parents=True, exist_ok=True)
    attached.write_text("remember this", encoding="utf-8")

    client, token = make_client(
        monkeypatch,
        tmp_path,
        extra_env={"VOICE_AGENT_DEFAULT_WORKDIR": str(tmp_path / "workspace")},
    )
    resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
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

    final = None
    payload = None
    for _ in range(30):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        assert run_resp.status_code == 200
        payload = run_resp.json()
        final = payload["status"]
        if final != "running":
            break
        time.sleep(0.05)
    assert final == "completed"
    assert payload is not None
    assert payload["utterance_text"] == "Inspect notes.txt"


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


def test_audio_mock_flow_preserves_draft_context_and_attachments(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
    attachment = {
        "type": "file",
        "title": "notes.txt",
        "path": str(tmp_path / "notes.txt"),
        "mime": "text/plain",
    }
    resp = client.post(
        "/v1/audio",
        headers={"Authorization": f"Bearer {token}"},
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
    run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
    assert run_resp.status_code == 200
    payload = run_resp.json()
    assert payload["utterance_text"] == "Run the smoke test again.\n\nCompare it with the last pass too."


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


def test_file_fetch_full_access_without_explicit_roots_allows_absolute_paths(monkeypatch, tmp_path: Path):
    file_path = tmp_path / "sample.txt"
    file_path.write_text("hello-file", encoding="utf-8")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "VOICE_AGENT_SECURITY_MODE": "full-access",
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "true",
        },
    )
    resp = client.get(
        "/v1/files",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(file_path)},
    )
    assert resp.status_code == 200
    assert resp.text == "hello-file"


def test_file_fetch_relative_path_uses_default_workdir(monkeypatch, tmp_path: Path):
    workdir = tmp_path / "workspace"
    workdir.mkdir(parents=True, exist_ok=True)
    file_path = workdir / "plot_xy_temp.png"
    file_path.write_bytes(b"\x89PNG\r\n\x1a\n")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workdir),
            "VOICE_AGENT_FILE_ROOTS": str(workdir),
        },
    )
    resp = client.get(
        "/v1/files",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": "plot_xy_temp.png"},
    )
    assert resp.status_code == 200
    assert resp.content.startswith(b"\x89PNG")


def test_file_fetch_absolute_blocked_when_disabled(monkeypatch, tmp_path: Path):
    file_path = tmp_path / "sample.txt"
    file_path.write_text("hello-file", encoding="utf-8")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "VOICE_AGENT_FILE_ROOTS": str(tmp_path),
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "false",
        },
    )
    resp = client.get(
        "/v1/files",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(file_path)},
    )
    assert resp.status_code == 403
    assert "absolute file paths are disabled" in resp.json()["detail"].lower()


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


def test_upload_endpoint_stores_file_inside_allowed_roots(monkeypatch, tmp_path: Path):
    workdir = tmp_path / "workspace"
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workdir),
            "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS": "false",
        },
    )
    resp = client.post(
        "/v1/uploads",
        headers={"Authorization": f"Bearer {token}"},
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

    file_resp = client.get(
        "/v1/files",
        headers={"Authorization": f"Bearer {token}"},
        params={"path": str(stored_path)},
    )
    assert file_resp.status_code == 200
    assert file_resp.content == b"hello from phone"


def test_pair_exchange_is_single_use_under_concurrency(monkeypatch, tmp_path: Path):
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
        monkeypatch,
        tmp_path,
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


def test_upload_endpoint_rejects_large_file(monkeypatch, tmp_path: Path):
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "VOICE_AGENT_DEFAULT_WORKDIR": str(tmp_path / "workspace"),
            "VOICE_AGENT_MAX_UPLOAD_MB": "0.0001",
        },
    )
    resp = client.post(
        "/v1/uploads",
        headers={"Authorization": f"Bearer {token}"},
        files={"file": ("large.bin", BytesIO(b"x" * 512), "application/octet-stream")},
        data={"session_id": "ios-session"},
    )
    assert resp.status_code == 413
    assert "file payload too large" in resp.json()["detail"]


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


def test_runtime_config_includes_codex_model(monkeypatch, tmp_path: Path):
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
    fake_codex = tmp_path / "codex"
    fake_codex.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    fake_claude = tmp_path / "claude"
    fake_claude.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    fake_claude.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
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
    resp = client.get(
        "/v1/config",
        headers={"Authorization": f"Bearer {token}"},
    )
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
    assert [setting["id"] for setting in executors["codex"]["settings"]] == ["model", "reasoning_effort"]
    assert executors["codex"]["settings"][0]["kind"] == "enum"
    assert executors["codex"]["settings"][0]["allow_custom"] is True
    assert executors["codex"]["settings"][0]["value"] == "gpt-5.1"
    assert executors["codex"]["settings"][0]["options"] == ["gpt-5.4-mini", "custom-codex", "gpt-5.4", "gpt-5.1"]
    assert executors["codex"]["settings"][1]["allow_custom"] is False
    assert executors["codex"]["settings"][1]["value"] == "high"
    assert executors["codex"]["settings"][1]["options"] == ["high", "medium", "minimal", "low", "xhigh"]
    assert [setting["id"] for setting in executors["claude"]["settings"]] == ["model"]
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


def test_utterance_and_audio_omit_executor_use_resolved_default(monkeypatch, tmp_path: Path):
    fake_codex = tmp_path / "codex"
    fake_codex.write_text(
        "#!/usr/bin/env bash\n"
        "echo '{\"type\":\"thread.started\",\"thread_id\":\"thread-abc\"}'\n"
        "echo '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}'\n"
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
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
        },
    )

    utterance_resp = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "default-executor-text",
            "utterance_text": "inspect this repo",
        },
    )
    assert utterance_resp.status_code == 200
    text_run_id = utterance_resp.json()["run_id"]

    audio_resp = client.post(
        "/v1/audio",
        headers={"Authorization": f"Bearer {token}"},
        files={"audio": ("sample.wav", BytesIO(b"fakewav"), "audio/wav")},
        data={
            "session_id": "default-executor-audio",
            "transcript_hint": "inspect this repo",
        },
    )
    assert audio_resp.status_code == 200
    audio_run_id = audio_resp.json()["run_id"]

    for run_id in (text_run_id, audio_run_id):
        final_payload = None
        for _ in range(80):
            run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
            assert run_resp.status_code == 200
            final_payload = run_resp.json()
            if final_payload["status"] != "running":
                break
            time.sleep(0.05)
        assert final_payload is not None
        assert final_payload["status"] == "completed"
        assert final_payload["executor"] == "codex"
        activity_stages = [e["stage"] for e in final_payload["events"] if e["type"].startswith("activity.")]
        assert activity_stages == ["planning", "executing", "summarizing"]


def test_capabilities_endpoint_returns_report(monkeypatch, tmp_path: Path):
    client, token = make_client(monkeypatch, tmp_path, provider="mock")
    resp = client.get(
        "/v1/capabilities",
        headers={"Authorization": f"Bearer {token}"},
    )
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


def test_config_endpoint_keeps_local_as_internal_fallback_when_binaries_are_missing(monkeypatch, tmp_path: Path):
    empty_path = tmp_path / "empty-bin"
    empty_path.mkdir()
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "PATH": str(empty_path),
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
        },
    )
    resp = client.get(
        "/v1/config",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["default_executor"] == "local"
    assert payload["available_executors"] == []
    executors = {item["id"]: item for item in payload["executors"]}
    assert executors["local"]["default"] is True
    assert executors["codex"]["available"] is False
    assert executors["claude"]["available"] is False


def test_capabilities_openai_probe_requires_key(monkeypatch, tmp_path: Path):
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="openai",
        openai_api_key="",
    )
    resp = client.get(
        "/v1/capabilities",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    payload = resp.json()
    by_id = {item["id"]: item for item in payload["capabilities"]}
    transcribe_probe = by_id["transcribe_provider"]
    assert transcribe_probe["status"] == "blocked"
    assert transcribe_probe["code"] == "auth_missing"


def test_config_endpoint_reports_openai_transcription_not_ready_without_key(monkeypatch, tmp_path: Path):
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="openai",
        openai_api_key="",
    )
    resp = client.get(
        "/v1/config",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["transcribe_provider"] == "openai"
    assert payload["transcribe_ready"] is False


def test_pair_exchange_returns_scoped_token_and_rotates_code(monkeypatch, tmp_path: Path):
    pairing_file = tmp_path / "pairing.json"
    pairing_file.write_text(
        (
            '{'
            '"server_url":"https://relay.example.com",'
            '"server_urls":["https://relay.example.com","http://100.111.99.51:8000"],'
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


def test_paired_token_authorizes_protected_requests(monkeypatch, tmp_path: Path):
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

    pair_resp = client.post("/v1/pair/exchange", json={"pair_code": "pair-1234", "session_id": "ios1"})
    assert pair_resp.status_code == 200
    paired_token = pair_resp.json()["api_token"]
    assert paired_token != "abc-token"

    config_resp = client.get(
        "/v1/config",
        headers={"Authorization": f"Bearer {paired_token}"},
    )
    assert config_resp.status_code == 200


def test_pair_refresh_rotates_access_token_and_keeps_refresh_token(monkeypatch, tmp_path: Path):
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

    stale_resp = client.get(
        "/v1/config",
        headers={"Authorization": f"Bearer {issued['api_token']}"},
    )
    assert stale_resp.status_code == 401

    config_resp = client.get(
        "/v1/config",
        headers={"Authorization": f"Bearer {refreshed['api_token']}"},
    )
    assert config_resp.status_code == 200


def test_pair_refresh_bootstraps_refresh_token_from_existing_paired_access_token(monkeypatch, tmp_path: Path):
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
        monkeypatch,
        tmp_path,
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

    config_resp = client.get(
        "/v1/config",
        headers={"Authorization": "Bearer legacy-paired-token"},
    )
    assert config_resp.status_code == 200

    stored = json.loads(pairing_file.read_text(encoding="utf-8"))
    assert stored["paired_clients"][0]["refresh_token_sha256"]


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


def test_codex_human_unblock_transitions_to_blocked(monkeypatch, tmp_path: Path):
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
    fake_codex = tmp_path / "codex"
    fake_codex.write_text(
        "#!/usr/bin/env bash\n"
        "echo '{\"type\":\"thread.started\",\"thread_id\":\"thread-blocked\"}'\n"
        f"echo '{{\"type\":\"item.completed\",\"item\":{{\"type\":\"agent_message\",\"text\":{json.dumps(envelope)}}}}}'\n"
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
            "session_id": "blocked1",
            "thread_id": "chat-blocked",
            "utterance_text": "open the site and continue",
            "executor": "codex",
        },
    )
    assert create_resp.status_code == 200
    run_id = create_resp.json()["run_id"]

    payload = None
    for _ in range(80):
        run_resp = client.get(f"/v1/runs/{run_id}", headers={"Authorization": f"Bearer {token}"})
        assert run_resp.status_code == 200
        payload = run_resp.json()
        if payload["status"] != "running":
            break
        time.sleep(0.05)

    assert payload is not None
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

    context_resp = client.get(
        "/v1/sessions/blocked1/context",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert context_resp.status_code == 200
    context_payload = context_resp.json()
    assert context_payload["latest_run_id"] == run_id
    assert context_payload["latest_run_status"] == "blocked"
    assert context_payload["latest_run_summary"] == payload["summary"]
    assert context_payload["latest_run_pending_human_unblock"]["instructions"].startswith("Complete the CAPTCHA")


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


def test_claude_run_streams_assistant_messages_and_resumes_session(monkeypatch, tmp_path: Path):
    fake_claude = tmp_path / "claude"
    fake_claude.write_text(
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
        encoding="utf-8",
    )
    fake_claude.chmod(0o755)
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        monkeypatch,
        tmp_path,
        provider="mock",
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_CLAUDE_BINARY": "claude",
            "VOICE_AGENT_CLAUDE_TIMEOUT_SEC": "60",
        },
    )

    create_first = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "claude-resume",
            "thread_id": "chat-claude",
            "utterance_text": "first prompt",
            "executor": "claude",
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
    assert any("started from claude" in msg for msg in first_chat_messages)

    create_second = client.post(
        "/v1/utterances",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "session_id": "claude-resume",
            "thread_id": "chat-claude",
            "utterance_text": "second prompt",
            "executor": "claude",
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
    assert any("continued from claude" in msg for msg in second_chat_messages)
