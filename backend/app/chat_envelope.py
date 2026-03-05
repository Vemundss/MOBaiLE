from __future__ import annotations

import json
import mimetypes
import re
import uuid
from datetime import datetime
from datetime import timezone
from pathlib import Path

from app.models.schemas import ChatArtifact
from app.models.schemas import ChatEnvelope
from app.models.schemas import ChatSection


def parse_chat_envelope_payload(raw_text: str) -> dict[str, object] | None:
    candidate = raw_text.strip()
    if not candidate:
        return None
    if candidate.startswith("```") and candidate.endswith("```"):
        parts = candidate.split("\n")
        if len(parts) >= 3:
            candidate = "\n".join(parts[1:-1]).strip()

    parsed = None
    for _ in range(2):
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            parsed = None
            break
        if isinstance(parsed, str):
            candidate = parsed.strip()
            continue
        break
    if not isinstance(parsed, dict):
        return None
    if parsed.get("type") != "assistant_response":
        return None
    parsed.setdefault("version", "1.0")
    parsed.setdefault("message_id", str(uuid.uuid4()))
    parsed.setdefault("created_at", datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
    parsed.setdefault("summary", "")
    parsed.setdefault("sections", [])
    parsed.setdefault("agenda_items", [])
    parsed.setdefault("artifacts", [])
    return parsed


def merge_assistant_lines(lines: list[str]) -> str:
    merged_parts: list[str] = []
    section_labels = {"what i did", "result", "next step", "output"}
    for line in lines:
        text = line.strip()
        if not text:
            continue
        if not merged_parts:
            merged_parts.append(text)
            continue

        prev = merged_parts[-1]
        if prev.strip().lower().rstrip(":") in section_labels:
            merged_parts.append("\n" + text)
            continue
        if text.lower().rstrip(":") in section_labels:
            merged_parts.append("\n\n## " + text.rstrip(":"))
            continue
        if prev.endswith((":", ";")):
            merged_parts.append("\n" + text)
            continue
        if text.startswith(("-", "*", "##", "###", "```")):
            merged_parts.append("\n" + text)
            continue
        if text.startswith(("1.", "2.", "3.", "4.", "5.")):
            merged_parts.append("\n" + text)
            continue
        if prev.endswith((".", "!", "?", "`")):
            merged_parts.append("\n\n" + text)
            continue
        merged_parts.append("\n" + text)
    return "".join(merged_parts)


def split_sections_from_text(text: str) -> list[ChatSection]:
    cleaned = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not cleaned:
        return []
    if "## " in cleaned:
        sections: list[ChatSection] = []
        for block in re.split(r"(?m)^##\s+", cleaned):
            chunk = block.strip()
            if not chunk:
                continue
            lines = chunk.splitlines()
            title = lines[0].strip().rstrip(":")
            body = "\n".join(lines[1:]).strip() if len(lines) > 1 else ""
            if not body:
                continue
            sections.append(ChatSection(title=title[:64], body=body))
        if sections:
            return sections
    paragraphs = [p.strip() for p in re.split(r"\n{2,}", cleaned) if p.strip()]
    if len(paragraphs) <= 1:
        return [ChatSection(title="Result", body=cleaned)]
    sections = [ChatSection(title="What I Did", body=paragraphs[0])]
    sections.append(ChatSection(title="Result", body="\n\n".join(paragraphs[1:])))
    return sections


def extract_artifacts_from_text(text: str) -> list[ChatArtifact]:
    artifacts: list[ChatArtifact] = []
    seen: set[str] = set()
    image_pattern = r"!\[[^\]]*\]\(([^)]+)\)"
    for match in re.finditer(image_pattern, text):
        path = match.group(1).strip().strip("'\"")
        if not path or path in seen:
            continue
        seen.add(path)
        mime, _ = mimetypes.guess_type(path)
        artifacts.append(
            ChatArtifact(
                type="image",
                title=Path(path).name or "image",
                path=path,
                mime=mime or "image/png",
            )
        )
    path_pattern = r"(/[^ \n`'\"<>]+\.[A-Za-z0-9]{1,8})"
    for match in re.finditer(path_pattern, text):
        path = match.group(1).strip()
        if not path or path in seen:
            continue
        seen.add(path)
        mime, _ = mimetypes.guess_type(path)
        artifact_type = "image" if (mime or "").startswith("image/") else "file"
        artifacts.append(
            ChatArtifact(
                type=artifact_type,
                title=Path(path).name or path,
                path=path,
                mime=mime,
            )
        )
    return artifacts


def coerce_assistant_text_to_envelope(raw_text: str) -> ChatEnvelope:
    text = raw_text.strip()
    message_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    if not text:
        return ChatEnvelope(
            message_id=message_id,
            created_at=created_at,
            summary="",
            sections=[],
            agenda_items=[],
            artifacts=[],
        )
    sections = split_sections_from_text(text)
    artifacts = extract_artifacts_from_text(text)
    summary = sections[0].body if sections else text.split("\n", 1)[0]
    summary = summary.strip()
    if not summary:
        summary = "Completed"
    return ChatEnvelope(
        message_id=message_id,
        created_at=created_at,
        summary=summary[:280],
        sections=sections,
        artifacts=artifacts,
    )
