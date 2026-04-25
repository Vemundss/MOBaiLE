from __future__ import annotations

from pathlib import Path

from app.capability_probes import (
    classify_apple_event_failure,
    probe_binary,
    probe_calendar_adapter,
    probe_transcriber,
)


def test_probe_binary_returns_resolved_path_for_existing_file(tmp_path: Path) -> None:
    tool = tmp_path / "codex"
    tool.write_text("#!/bin/sh\n", encoding="utf-8")

    probe = probe_binary("codex_cli", "Codex CLI", str(tool))

    assert probe.status == "ready"
    assert probe.details["resolved_path"] == str(tool.resolve())


def test_probe_transcriber_requires_openai_key(monkeypatch) -> None:
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)

    probe = probe_transcriber("openai")

    assert probe.status == "blocked"
    assert probe.code == "auth_missing"


def test_probe_calendar_adapter_maps_permission_errors(monkeypatch) -> None:
    monkeypatch.setattr("app.capability_probes.desktop.platform.system", lambda: "Darwin")
    monkeypatch.setattr("app.capability_probes.desktop.shutil.which", lambda _: "/usr/bin/osascript")
    monkeypatch.setattr("app.capability_probes.desktop.is_process_running", lambda _: True)

    def fail_fetch() -> list[object]:
        raise RuntimeError("Calendar got an error: Not authorized (-1743)")

    probe = probe_calendar_adapter(
        deep=True,
        launch_app=False,
        fetch_calendar_events=fail_fetch,
    )

    assert probe.status == "blocked"
    assert probe.code == "permission_required"


def test_classify_apple_event_failure_marks_missing_data_degraded() -> None:
    status, code, message = classify_apple_event_failure("Execution error: Can’t get event. (-1728)", "Calendar")

    assert status == "degraded"
    assert code == "data_unavailable"
    assert "Calendar is reachable" in message
