from __future__ import annotations

import json


def parse_claude_stream_event(raw_line: str) -> dict[str, object] | None:
    text = raw_line.strip()
    if not text.startswith("{"):
        return None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    event_type = payload.get("type")
    if not isinstance(event_type, str) or not event_type.strip():
        return None
    return payload


def claude_session_id(payload: dict[str, object]) -> str | None:
    for value in _walk_values(payload):
        if not isinstance(value, dict):
            continue
        for key in ("session_id", "sessionId"):
            raw = value.get(key)
            if isinstance(raw, str) and raw.strip():
                return raw.strip()
    for key in ("session_id", "sessionId"):
        raw = payload.get(key)
        if isinstance(raw, str) and raw.strip():
            return raw.strip()
    return None


def claude_assistant_text(payload: dict[str, object]) -> str | None:
    event_type = str(payload.get("type", "")).strip().lower()
    if event_type != "assistant":
        return None

    content = payload.get("message")
    if isinstance(content, dict):
        content = content.get("content")
    if content is None:
        content = payload.get("content")

    parts: list[str] = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, str):
                text = block.strip()
                if text:
                    parts.append(text)
                continue
            if not isinstance(block, dict):
                continue
            block_type = str(block.get("type", "")).strip().lower()
            if block_type not in {"text", "output_text"}:
                continue
            text = str(block.get("text", "")).strip()
            if text:
                parts.append(text)
    elif isinstance(content, str):
        text = content.strip()
        if text:
            parts.append(text)

    if not parts:
        return None
    return "\n\n".join(parts)


def _walk_values(value: object) -> list[object]:
    items = [value]
    if isinstance(value, dict):
        for child in value.values():
            items.extend(_walk_values(child))
    elif isinstance(value, list):
        for child in value:
            items.extend(_walk_values(child))
    return items
