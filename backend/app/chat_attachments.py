from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Literal

from fastapi import HTTPException

from app.models.schemas import ChatArtifact


def display_utterance_text(raw_text: str, attachments: list[ChatArtifact]) -> str:
    trimmed = raw_text.strip()
    if trimmed:
        return trimmed
    if len(attachments) == 1:
        title = attachments[0].title.strip() or "attachment"
        return f"Inspect {title}"
    return f"Inspect {len(attachments)} attachments"


def render_utterance_for_executor(raw_text: str, attachments: list[ChatArtifact]) -> str:
    trimmed = raw_text.strip()
    if not attachments:
        return trimmed

    images = [artifact for artifact in attachments if artifact.type == "image"]
    files = [artifact for artifact in attachments if artifact.type != "image"]
    sections: list[str] = [trimmed or _default_attachment_prompt(len(attachments))]

    if images:
        sections.append(
            "Attached images:\n" + "\n".join(
                line for line in (_attachment_reference_line(item) for item in images) if line
            )
        )
    if files:
        sections.append(
            "Attached files:\n" + "\n".join(
                line for line in (_attachment_reference_line(item) for item in files) if line
            )
        )
    return "\n\n".join(section for section in sections if section.strip())


def merge_voice_utterance(draft_text: str | None, transcript_text: str) -> str:
    parts = [
        (draft_text or "").strip(),
        transcript_text.strip(),
    ]
    return "\n\n".join(part for part in parts if part)


def parse_audio_attachments(raw_attachments: str | None) -> list[ChatArtifact]:
    payload = (raw_attachments or "").strip()
    if not payload:
        return []
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail="attachments_json must be valid JSON") from exc
    if not isinstance(decoded, list):
        raise HTTPException(status_code=400, detail="attachments_json must be a JSON array")
    try:
        return [ChatArtifact.model_validate(item) for item in decoded]
    except Exception as exc:
        raise HTTPException(status_code=400, detail="attachments_json contains an invalid attachment") from exc


def sanitize_upload_name(raw_name: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", raw_name.strip()).strip(".-")
    return cleaned or "attachment"


def artifact_type_for_upload(file_name: str, mime: str | None) -> Literal["image", "file", "code"]:
    lower_mime = (mime or "").lower()
    if lower_mime.startswith("image/"):
        return "image"
    if lower_mime.startswith("text/"):
        return "code"

    suffix = Path(file_name).suffix.lower()
    if suffix in {
        ".c",
        ".cc",
        ".cpp",
        ".css",
        ".go",
        ".h",
        ".hpp",
        ".html",
        ".java",
        ".js",
        ".json",
        ".kt",
        ".md",
        ".mjs",
        ".php",
        ".py",
        ".rb",
        ".rs",
        ".sh",
        ".sql",
        ".swift",
        ".toml",
        ".ts",
        ".tsx",
        ".txt",
        ".xml",
        ".yaml",
        ".yml",
    }:
        return "code"
    return "file"


def _default_attachment_prompt(count: int) -> str:
    if count == 1:
        return "Please inspect the attached file and summarize the important details."
    return "Please inspect the attached files and summarize the important details."


def _attachment_reference_line(artifact: ChatArtifact) -> str | None:
    reference = (artifact.path or artifact.url or "").strip()
    if not reference:
        title = artifact.title.strip()
        return f"- {title}" if title else None
    title = artifact.title.strip() or "attachment"
    if artifact.type == "image":
        return f"![{title}]({reference})"
    return f"[{title}]({reference})"
