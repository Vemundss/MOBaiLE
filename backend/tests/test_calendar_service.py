from __future__ import annotations

from subprocess import CompletedProcess

import pytest

from app.calendar_service import CalendarService


def test_calendar_service_parses_event_rows_and_normalizes_missing_location() -> None:
    proc = CompletedProcess(
        args=["osascript"],
        returncode=0,
        stdout="09:00\t10:00\tStandup\tWork\tRoom A\n11:00\t11:30\t\tPersonal\tmissing value\n",
        stderr="",
    )

    items = CalendarService._parse_event_rows(proc)

    assert len(items) == 2
    assert items[0].title == "Standup"
    assert items[0].calendar == "Work"
    assert items[0].location == "Room A"
    assert items[1].title == "(Untitled)"
    assert items[1].calendar == "Personal"
    assert items[1].location is None


def test_calendar_service_rejects_non_macos(monkeypatch) -> None:
    service = CalendarService()
    monkeypatch.setattr(
        "app.calendar_service.os.uname",
        lambda: type("Uname", (), {"sysname": "Linux"})(),
    )

    with pytest.raises(RuntimeError, match="supports macOS only"):
        service.fetch_today_events()
