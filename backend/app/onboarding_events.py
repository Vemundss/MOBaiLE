from __future__ import annotations

import json
import threading
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class OnboardingEventRecorder:
    def __init__(self, path: Path, *, max_report_events: int = 50) -> None:
        self._path = path
        self._max_report_events = max_report_events
        self._lock = threading.Lock()

    def record(self, event_type: str, details: dict[str, Any] | None = None) -> None:
        event = {
            "type": event_type,
            "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "details": self._safe_details(details or {}),
        }
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            line = json.dumps(event, sort_keys=True, separators=(",", ":"))
            with self._lock:
                with self._path.open("a", encoding="utf-8") as handle:
                    handle.write(line + "\n")
        except OSError:
            return

    def report(self) -> dict[str, Any]:
        events = self._read_events()
        counts = Counter(str(event.get("type", "")).strip() for event in events)
        counts.pop("", None)
        latest = events[-1] if events else None
        return {
            "path": str(self._path),
            "event_count": len(events),
            "counts": dict(sorted(counts.items())),
            "latest_event_at": latest.get("created_at") if latest else None,
            "events": events[-self._max_report_events :],
        }

    def _read_events(self) -> list[dict[str, Any]]:
        if not self._path.exists():
            return []
        events: list[dict[str, Any]] = []
        try:
            lines = self._path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        for line in lines:
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                events.append(payload)
        return events

    @staticmethod
    def _safe_details(details: dict[str, Any]) -> dict[str, Any]:
        safe: dict[str, Any] = {}
        blocked_fragments = ("token", "secret", "password", "pair_code", "authorization")
        for key, value in details.items():
            normalized_key = str(key).strip()
            if not normalized_key:
                continue
            if any(fragment in normalized_key.lower() for fragment in blocked_fragments):
                continue
            if isinstance(value, str | int | float | bool) or value is None:
                safe[normalized_key] = value
            elif isinstance(value, list):
                safe[normalized_key] = [
                    item for item in value if isinstance(item, str | int | float | bool) or item is None
                ][:20]
            elif isinstance(value, dict):
                safe[normalized_key] = OnboardingEventRecorder._safe_details(value)
        return safe
