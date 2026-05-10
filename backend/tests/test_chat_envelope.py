from __future__ import annotations

import json

from .api_test_support import reload_module


def test_codex_output_filter_drops_runtime_noise():
    module = reload_module("app.main")
    user_prompt = "create a python file"
    leak_markers = module.ENV.runtime_context_leak_markers()

    assert (
        module.filter_codex_assistant_message(
            "/bin/zsh -lc \"python3 hello.py\"",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert module.filter_codex_assistant_message("tokens used", user_prompt, leak_markers) is None
    assert (
        module.filter_codex_assistant_message(
            "You are running through MOBaiLE.",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert (
        module.filter_codex_assistant_message(
            "MOBaiLE runtime context:",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert (
        module.filter_codex_assistant_message(
            "You are the coding agent used by MOBaiLE.",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert (
        module.filter_codex_assistant_message(
            "Product intent: MOBaiLE makes a user's computer available from their phone.",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert (
        module.filter_codex_assistant_message(
            "Backend activity events are the source of truth for progress in the phone UI.",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert (
        module.filter_codex_assistant_message(
            "Do not dump raw logs or long command output unless the user asks.",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert (
        module.filter_codex_assistant_message(
            "Keep responses concise and grouped; avoid verbose step-by-step chatter.",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert module.filter_codex_assistant_message("```text", user_prompt, leak_markers) is None
    assert (
        module.filter_codex_assistant_message(
            "Created `hello.py` and ran it successfully.",
            user_prompt,
            leak_markers,
        )
        is None
    )
    assert module.filter_codex_assistant_message("1,147", user_prompt, leak_markers) is None
    assert (
        module.filter_codex_assistant_message(
            "Done. Created hello.py.",
            user_prompt,
            leak_markers,
        )
        == "Done. Created hello.py."
    )


def test_codex_assistant_extractor_emits_only_assistant_blocks():
    module = reload_module("app.main")
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


def test_parse_chat_envelope_payload_handles_wrapped_json():
    module = reload_module("app.chat_envelope")
    payload = '{"type":"assistant_response","version":"1.0","summary":"ok","sections":[],"agenda_items":[]}'
    parsed = module.parse_chat_envelope_payload(payload)
    assert parsed is not None
    assert parsed["type"] == "assistant_response"
    assert parsed["file_changes"] == []
    assert parsed["commands_run"] == []
    assert parsed["tests_run"] == []
    assert parsed["warnings"] == []
    assert parsed["next_actions"] == []
    wrapped = json.dumps(payload)
    parsed_wrapped = module.parse_chat_envelope_payload(wrapped)
    assert parsed_wrapped is not None
    assert parsed_wrapped["summary"] == "ok"


def test_merge_assistant_lines_adds_structure():
    module = reload_module("app.chat_envelope")
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


def test_merge_assistant_lines_recognizes_result_metadata_headings():
    module = reload_module("app.chat_envelope")
    merged = module.merge_assistant_lines(
        [
            "Result:",
            "Updated the phone formatter.",
            "Changed Files:",
            "- backend/app/chat_envelope.py",
            "Verification:",
            "npm run backend:lint passed",
            "Warnings:",
            "Restart was deferred during the active run.",
        ]
    )

    assert "## Changed Files\n- backend/app/chat_envelope.py" in merged
    assert "## Verification\nnpm run backend:lint passed" in merged
    assert "## Warnings\nRestart was deferred during the active run." in merged


def test_coerce_assistant_text_to_envelope_polishes_inline_final_status_lines():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope(
        "Updated the launch note wording to:\n\n"
        "At run start, check the requested project root for AGENTS.md or agents.md and read it if present.\n\n"
        "Commit: 49978f1 Read repo instructions at run start\n"
        "Verification: Red test failed first on the old wording\n"
        "Focused test then passed\n"
        "npm run backend:lint passed\n"
        "UV_PROJECT_ENVIRONMENT=../.mobaile/backend-test-venv uv run pytest "
        "tests/test_codex_executor.py tests/test_runtime_prompt.py passed: 10 tests\n"
        "git diff --check clean\n"
        "Runtime synced; backend service is running\n"
        "Restart deferred because this active run is still in progress\n"
        "Repo is clean: main...origin/main"
    )

    sections = {section.title: section.body for section in envelope.sections}
    command_statuses = {command.command: command.status for command in envelope.commands_run}

    assert envelope.summary == "Updated the launch note wording."
    assert sections["Result"].startswith("Updated the launch note wording.")
    assert "Verification:" not in sections["Result"]
    assert "Commit:" in sections["Notes"]
    assert "- Red test failed first on the old wording." in sections["Verification"]
    assert "- Focused test then passed." in sections["Verification"]
    assert command_statuses["npm run backend:lint"] == "passed"
    assert (
        command_statuses[
            "UV_PROJECT_ENVIRONMENT=../.mobaile/backend-test-venv uv run pytest "
            "tests/test_codex_executor.py tests/test_runtime_prompt.py"
        ]
        == "passed"
    )
    assert command_statuses["git diff --check"] == "passed"


def test_coerce_assistant_text_to_envelope_extracts_artifacts():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope(
        "## What I Did\nCreated /Users/test/hello.py\n\n## Result\n![plot](/Users/test/plot.png)"
    )
    assert envelope.type == "assistant_response"
    assert envelope.message_id
    assert envelope.created_at
    assert len(envelope.sections) >= 1
    assert any(item.path == "/Users/test/hello.py" for item in envelope.artifacts)
    assert any(item.path == "/Users/test/plot.png" and item.type == "image" for item in envelope.artifacts)
    assert any(item.path == "/Users/test/hello.py" and item.status == "created" for item in envelope.file_changes)
    assert any(item.path == "/Users/test/plot.png" and item.status == "generated" for item in envelope.file_changes)


def test_coerce_assistant_text_to_envelope_extracts_paths_with_spaces():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope(
        "Updated /Users/test/Mobile Documents/session/Release Notes.md and "
        "[opened report](/Users/test/Mobile Documents/session/report.pdf)."
    )

    paths = {item.path for item in envelope.artifacts}
    assert "/Users/test/Mobile Documents/session/Release Notes.md" in paths
    assert "/Users/test/Mobile Documents/session/report.pdf" in paths


def test_chat_envelope_transport_truncates_without_corrupting_json():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope(
        "## Result\n" + ("This is a long phone-facing result. " * 200)
    )

    rendered = module.chat_envelope_transport_json(envelope, max_chars=900)
    parsed = json.loads(rendered)

    assert len(rendered) <= 900
    assert parsed["type"] == "assistant_response"
    assert "...[truncated]" in rendered


def test_coerce_assistant_text_to_envelope_extracts_phone_surface_metadata():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope(
        "## Changed Files\n"
        "- Updated `backend/app/chat_envelope.py` to emit typed metadata.\n\n"
        "## Verification\n"
        "- `cd backend && uv run pytest tests/test_chat_envelope.py` passed.\n\n"
        "## Warnings\n"
        "- iOS simulator screenshots were not captured.\n\n"
        "## Next Step\n"
        "- Open Run Logs if you want the raw command stream.\n\n"
        "## Result\n"
        "The phone now receives a richer final result."
    )

    assert envelope.message_kind == "final"
    assert envelope.file_changes[0].path == "backend/app/chat_envelope.py"
    assert envelope.file_changes[0].status == "modified"
    assert envelope.commands_run[0].command == "cd backend && uv run pytest tests/test_chat_envelope.py"
    assert envelope.commands_run[0].status == "passed"
    assert envelope.tests_run[0].status == "passed"
    assert envelope.warnings[0].level == "warning"
    assert envelope.next_actions[0].kind == "open_logs"


def test_coerce_assistant_text_to_envelope_lifts_structured_result_manifest():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope(
        "## Result\n"
        "Phone result cards now use explicit metadata.\n\n"
        "```mobaile_result\n"
        "{\n"
        '  "summary": "Structured result ready.",\n'
        '  "file_changes": [\n'
        '    {"path": "backend/app/chat_envelope.py", "status": "modified", "summary": "Added manifest support."}\n'
        "  ],\n"
        '  "commands_run": [\n'
        '    {"command": "uv run pytest tests/test_chat_envelope.py", "status": "passed", "exit_code": 0}\n'
        "  ],\n"
        '  "tests_run": [\n'
        '    {"name": "tests/test_chat_envelope.py", "status": "passed", "summary": "10 passed"}\n'
        "  ],\n"
        '  "warnings": [\n'
        '    {"message": "Visual screenshots still need review.", "level": "info"}\n'
        "  ],\n"
        '  "next_actions": [\n'
        '    {"title": "Preview parser", "kind": "inspect_artifact", "path": "backend/app/chat_envelope.py"},\n'
        '    {"title": "Open Run Logs", "kind": "open_logs"}\n'
        "  ]\n"
        "}\n"
        "```\n"
    )

    rendered = envelope.model_dump_json()

    assert envelope.summary == "Structured result ready."
    assert envelope.file_changes[0].path == "backend/app/chat_envelope.py"
    assert envelope.file_changes[0].artifact is not None
    assert envelope.file_changes[0].artifact.path == "backend/app/chat_envelope.py"
    assert envelope.commands_run[0].exit_code == 0
    assert envelope.tests_run[0].summary == "10 passed"
    assert envelope.warnings[0].level == "info"
    assert envelope.next_actions[0].artifact is not None
    assert envelope.next_actions[0].artifact.path == "backend/app/chat_envelope.py"
    assert "mobaile_result" not in rendered
    assert "Added manifest support." in rendered


def test_coerce_assistant_text_to_envelope_lifts_json_wrapped_result_manifest():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope(
        "Done.\n\n"
        "```json\n"
        '{"mobaile_result":{"file_changes":[{"path":"ios/VoiceAgentApp/ChatRenderers.swift","status":"modified"}]}}\n'
        "```"
    )

    assert envelope.file_changes[0].path == "ios/VoiceAgentApp/ChatRenderers.swift"
    assert envelope.file_changes[0].artifact is not None


def test_shell_envelope_does_not_infer_metadata_from_terminal_output():
    module = reload_module("app.chat_envelope")
    envelope = module.enhance_chat_envelope(
        module.ChatEnvelope(
            summary="Command completed successfully",
            sections=[
                module.ChatSection(title="Command", body="`rg test`"),
                module.ChatSection(
                    title="Output",
                    body=(
                        "AGENTS.md:- Backend Python changes: run `uv run pytest tests/test_api.py`\n"
                        "AGENTS.md:- Known hotspots: `storage/run_store.py`, `tests/test_api.py`."
                    ),
                ),
            ],
            shell_results=[
                module.ChatShellResult(
                    command="rg test",
                    status="passed",
                    exit_code=0,
                    stdout=(
                        "AGENTS.md:- Backend Python changes: run `uv run pytest tests/test_api.py`\n"
                        "AGENTS.md:- Known hotspots: `storage/run_store.py`, `tests/test_api.py`."
                    ),
                    stderr="",
                    summary="ran 'rg test'",
                )
            ],
        )
    )

    assert envelope.shell_results
    assert envelope.file_changes == []
    assert envelope.commands_run == []
    assert envelope.tests_run == []


def test_coerce_assistant_text_to_envelope_marks_progress_messages():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope("Running the test suite now...")

    assert envelope.message_kind == "progress"
    assert module.concise_chat_summary(envelope) is None


def test_coerce_assistant_text_to_envelope_marks_curly_apostrophe_progress_messages():
    module = reload_module("app.chat_envelope")
    envelope = module.coerce_assistant_text_to_envelope("I’m checking the runtime copy now.")

    assert envelope.message_kind == "progress"
    assert module.concise_chat_summary(envelope) is None
