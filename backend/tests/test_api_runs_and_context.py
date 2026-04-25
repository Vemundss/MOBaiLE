from __future__ import annotations

import importlib
import json
import os
from pathlib import Path

from app.models.schemas import RunRecord

from .api_test_support import auth_headers, wait_for_run_to_settle, write_executable


def test_auth_required(make_client):
    client, token = make_client()
    headers = auth_headers(token)
    assert client.get("/health").status_code == 200
    assert client.post("/v1/utterances", json={}).status_code == 401
    assert client.post("/v1/utterances", headers=headers, json={}).status_code == 422


def test_codex_guardrails_enforce_rejects_dangerous(make_client):
    client, token = make_client(
        extra_env={"VOICE_AGENT_CODEX_GUARDRAILS": "enforce"},
    )
    headers = auth_headers(token)
    resp = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "guardrails-1",
            "utterance_text": "please run rm -rf /tmp/test",
            "executor": "codex",
        },
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["status"] == "rejected"
    run = client.get(f"/v1/runs/{payload['run_id']}", headers=headers)
    assert run.status_code == 200
    assert run.json()["status"] == "rejected"


def test_list_session_runs_and_diagnostics(make_client):
    client, token = make_client()
    headers = auth_headers(token)
    create = client.post(
        "/v1/utterances",
        headers=headers,
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

    payload = wait_for_run_to_settle(client, token, run_id, attempts=40)
    assert payload["status"] == "completed"

    listing = client.get("/v1/sessions/sess-list/runs?limit=5", headers=headers)
    assert listing.status_code == 200
    listed = listing.json()
    assert len(listed) >= 1
    assert listed[0]["run_id"] == run_id

    diag = client.get(f"/v1/runs/{run_id}/diagnostics", headers=headers)
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


def test_run_events_endpoint_includes_typed_activity_payload(make_client):
    client, token = make_client()
    headers = auth_headers(token)
    create = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "sess-activity-events",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    final_run = wait_for_run_to_settle(client, token, run_id, attempts=40)
    pivot_seq = int(final_run["events"][-1]["seq"])
    module = importlib.import_module("app.main")
    module.RUN_STATE.append_activity_event(
        run_id,
        stage="executing",
        title="Executing",
        display_message="Running commands.",
    )

    response = client.get(f"/v1/runs/{run_id}/events?after_seq={pivot_seq}", headers=headers)
    assert response.status_code == 200
    assert '"type": "activity.updated"' in response.text
    assert '"stage": "executing"' in response.text
    assert '"title": "Executing"' in response.text


def test_run_diagnostics_endpoint_reports_activity_errors(make_client):
    client, token = make_client()
    headers = auth_headers(token)
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

    diag = client.get("/v1/runs/run-diagnostics-error/diagnostics", headers=headers)
    assert diag.status_code == 200
    diagnostics = diag.json()
    assert diagnostics["run_id"] == "run-diagnostics-error"
    assert diagnostics["has_stderr"] is False
    assert diagnostics["last_error"] == "Calendar query failed."
    assert diagnostics["latest_activity"] == "Calendar query failed."
    assert diagnostics["activity_stage_counts"] == {"executing": 1}


def test_run_events_endpoint_replays_from_after_seq(make_client):
    client, token = make_client()
    headers = auth_headers(token)
    create = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "sess-events",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    final_run = wait_for_run_to_settle(client, token, run_id, attempts=40)
    all_events = final_run["events"]
    assert len(all_events) >= 2
    pivot_seq = int(all_events[0]["seq"])

    response = client.get(f"/v1/runs/{run_id}/events?after_seq={pivot_seq}", headers=headers)
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


def test_run_events_page_endpoint_returns_bounded_event_windows(make_client):
    client, token = make_client()
    headers = auth_headers(token)
    create = client.post(
        "/v1/utterances",
        headers=headers,
        json={
            "session_id": "sess-events-page",
            "utterance_text": "create a hello python script and run it",
            "executor": "local",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    final_run = wait_for_run_to_settle(client, token, run_id, attempts=40)
    all_events = final_run["events"]
    assert len(all_events) >= 3

    bounded_run = client.get(f"/v1/runs/{run_id}?events_limit=0", headers=headers)
    assert bounded_run.status_code == 200
    assert bounded_run.json()["events"] == []

    first = client.get(f"/v1/runs/{run_id}/events-page?limit=2", headers=headers)
    assert first.status_code == 200
    first_payload = first.json()
    assert first_payload["run_id"] == run_id
    assert first_payload["limit"] == 2
    assert first_payload["total_count"] == len(all_events)
    assert len(first_payload["events"]) == 2
    assert [event["seq"] for event in first_payload["events"]] == [
        event["seq"] for event in all_events[-2:]
    ]
    assert first_payload["has_more_before"] is (len(all_events) > 2)
    assert first_payload["has_more_after"] is False

    second = client.get(
        f"/v1/runs/{run_id}/events-page?limit=2&before_seq={first_payload['next_before_seq']}",
        headers=headers,
    )
    assert second.status_code == 200
    second_payload = second.json()
    assert second_payload["events"]
    assert second_payload["events"][-1]["seq"] < first_payload["events"][0]["seq"]
    assert second_payload["has_more_after"] is True


def test_session_context_updates_and_runs_inherit_defaults(make_client, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    client, token = make_client(
        extra_env={
            "VOICE_AGENT_DEFAULT_EXECUTOR": "local",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": "missing-codex",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )
    headers = auth_headers(token)

    initial = client.get("/v1/sessions/sess-context/context", headers=headers)
    assert initial.status_code == 200
    assert initial.json()["executor"] == "local"
    assert initial.json()["working_directory"] is None
    assert initial.json()["resolved_working_directory"] == str(workspace)
    assert initial.json()["latest_run_id"] is None
    assert initial.json()["latest_run_status"] is None

    project_dir = workspace / "project"
    update = client.patch(
        "/v1/sessions/sess-context/context",
        headers=headers,
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
        headers=headers,
        json={
            "session_id": "sess-context",
            "utterance_text": "create a hello python script and run it",
        },
    )
    assert create.status_code == 200
    run_id = create.json()["run_id"]

    run = client.get(f"/v1/runs/{run_id}", headers=headers)
    assert run.status_code == 200
    run_payload = run.json()
    assert run_payload["executor"] == "local"
    assert run_payload["working_directory"] == str(project_dir)

    refreshed = client.get("/v1/sessions/sess-context/context", headers=headers)
    assert refreshed.status_code == 200
    refreshed_payload = refreshed.json()
    assert refreshed_payload["latest_run_id"] == run_id
    assert refreshed_payload["latest_run_status"] == "running"
    assert refreshed_payload["latest_run_summary"] == "Run started"
    assert refreshed_payload["latest_run_pending_human_unblock"] is None


def test_session_context_rejects_unavailable_executor(make_client):
    client, token = make_client(
        extra_env={
            "VOICE_AGENT_DEFAULT_EXECUTOR": "local",
            "VOICE_AGENT_CODEX_BINARY": "missing-codex",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    response = client.patch(
        "/v1/sessions/sess-context/context",
        headers=auth_headers(token),
        json={"executor": "codex"},
    )

    assert response.status_code == 400
    assert "not available" in response.json()["detail"]


def test_session_context_persists_runtime_overrides(make_client, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    write_executable(tmp_path / "codex", "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
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
        headers=auth_headers(token),
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


def test_session_context_rejects_invalid_codex_effort(make_client, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    write_executable(tmp_path / "codex", "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )

    response = client.patch(
        "/v1/sessions/sess-context/context",
        headers=auth_headers(token),
        json={"runtime_settings": [{"executor": "codex", "id": "reasoning_effort", "value": "turbo"}]},
    )

    assert response.status_code == 400
    assert "must be one of" in response.json()["detail"]


def test_session_context_runtime_settings_can_clear_overrides(make_client, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    write_executable(tmp_path / "codex", "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_MODEL": "gpt-5.4",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )
    headers = auth_headers(token)

    initial = client.patch(
        "/v1/sessions/sess-context/context",
        headers=headers,
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
        headers=headers,
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


def test_session_context_runtime_settings_payload_replaces_existing_state(make_client, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    write_executable(tmp_path / "codex", "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )
    headers = auth_headers(token)

    seeded = client.patch(
        "/v1/sessions/sess-context/context",
        headers=headers,
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
        headers=headers,
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


def test_slash_command_catalog_and_execution(make_client, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    client, token = make_client(
        extra_env={
            "VOICE_AGENT_DEFAULT_EXECUTOR": "local",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": "missing-codex",
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )
    headers = auth_headers(token)

    catalog = client.get("/v1/slash-commands", headers=headers)
    assert catalog.status_code == 200
    payload = catalog.json()
    assert [item["id"] for item in payload] == ["cwd", "executor"]
    assert payload[0]["group"] == "Runtime"
    assert payload[1]["usage"] == "/executor [local]"
    assert payload[1]["argument_options"] == ["local"]

    project_dir = workspace / "project"
    cwd_response = client.post(
        "/v1/sessions/sess-context/slash-commands/cwd",
        headers=headers,
        json={"arguments": str(project_dir)},
    )
    assert cwd_response.status_code == 200
    cwd_payload = cwd_response.json()
    assert cwd_payload["command_id"] == "cwd"
    assert cwd_payload["session_context"]["working_directory"] == str(project_dir)
    assert cwd_payload["session_context"]["resolved_working_directory"] == str(project_dir)

    executor_response = client.post(
        "/v1/sessions/sess-context/slash-commands/executor",
        headers=headers,
        json={"arguments": "local"},
    )
    assert executor_response.status_code == 200
    executor_payload = executor_response.json()
    assert executor_payload["command_id"] == "executor"
    assert executor_payload["session_context"]["executor"] == "local"
    assert "Available: local." in executor_payload["message"]


def test_slash_command_catalog_includes_model_and_effort_for_codex(make_client, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    write_executable(tmp_path / "codex", "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": str(tmp_path / "codex"),
            "VOICE_AGENT_CLAUDE_BINARY": "missing-claude",
        },
    )
    headers = auth_headers(token)

    catalog = client.get("/v1/slash-commands", headers=headers)
    assert catalog.status_code == 200
    payload = catalog.json()
    ids = [item["id"] for item in payload]
    assert ids == ["cwd", "executor", "model", "effort", "profile-agents", "profile-memory"]
    assert payload[2]["title"] == "Model Override"
    assert payload[3]["argument_options"] == ["backend-default", "minimal", "low", "medium", "high", "xhigh"]
    assert payload[4]["title"] == "Profile Instructions"
    assert payload[5]["title"] == "Profile Memory"

    model_response = client.post(
        "/v1/sessions/sess-context/slash-commands/model",
        headers=headers,
        json={"arguments": "gpt-5.4-mini"},
    )
    assert model_response.status_code == 200
    assert model_response.json()["session_context"]["codex_model"] == "gpt-5.4-mini"

    effort_response = client.post(
        "/v1/sessions/sess-context/slash-commands/effort",
        headers=headers,
        json={"arguments": "high"},
    )
    assert effort_response.status_code == 200
    assert effort_response.json()["session_context"]["codex_reasoning_effort"] == "high"


def test_slash_commands_follow_runtime_setting_registry(make_client, monkeypatch, tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    write_executable(tmp_path / "codex", "#!/usr/bin/env bash\nexit 0\n")
    env_path = os.environ.get("PATH", "")
    client, token = make_client(
        extra_env={
            "PATH": f"{tmp_path}:{env_path}",
            "VOICE_AGENT_DEFAULT_EXECUTOR": "codex",
            "VOICE_AGENT_DEFAULT_WORKDIR": str(workspace),
            "VOICE_AGENT_CODEX_BINARY": str(tmp_path / "codex"),
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

    headers = auth_headers(token)
    catalog = client.get("/v1/slash-commands", headers=headers)
    assert catalog.status_code == 200
    payload = catalog.json()
    assert [item["id"] for item in payload] == ["cwd", "executor", "model", "effort", "verbosity"]
    assert payload[-1]["usage"] == "/verbosity [backend-default|concise|detailed]"

    response = client.post(
        "/v1/sessions/sess-context/slash-commands/verbosity",
        headers=headers,
        json={"arguments": "detailed"},
    )
    assert response.status_code == 200
    runtime_settings = {
        (item["executor"], item["id"]): item["value"] for item in response.json()["session_context"]["runtime_settings"]
    }
    assert runtime_settings[("codex", "verbosity")] == "detailed"
