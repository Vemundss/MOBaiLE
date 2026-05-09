from __future__ import annotations

import json

import pytest
from fastapi import HTTPException

from app.chat_attachments import (
    artifact_type_for_upload,
    display_utterance_text,
    merge_voice_utterance,
    parse_audio_attachments,
    render_utterance_for_executor,
    sanitize_upload_name,
)
from app.models.schemas import ChatArtifact


def test_render_utterance_for_executor_includes_grouped_attachment_sections() -> None:
    attachments = [
        ChatArtifact(type="image", title="plot", path="/tmp/plot.png"),
        ChatArtifact(type="file", title="notes.txt", path="/tmp/notes.txt"),
    ]

    rendered = render_utterance_for_executor("", attachments)

    assert "Please inspect the attached files" in rendered
    assert "Attached images:" in rendered
    assert "![plot](/tmp/plot.png)" in rendered
    assert "Attached files:" in rendered
    assert "[notes.txt](/tmp/notes.txt)" in rendered


def test_display_and_merge_utterance_helpers_prefer_user_text() -> None:
    attachments = [ChatArtifact(type="file", title="notes.txt", path="/tmp/notes.txt")]

    assert display_utterance_text("Check this", attachments) == "Check this"
    assert display_utterance_text("", attachments) == "Inspect notes.txt"
    assert merge_voice_utterance("Run the smoke test again.", "Compare it with the last pass too.") == (
        "Run the smoke test again.\n\nCompare it with the last pass too."
    )


def test_parse_audio_attachments_validates_json_shape() -> None:
    with pytest.raises(HTTPException, match="attachments_json must be valid JSON"):
        parse_audio_attachments("{not-json")

    with pytest.raises(HTTPException, match="attachments_json must be a JSON array"):
        parse_audio_attachments(json.dumps({"type": "file"}))

    attachments = parse_audio_attachments(
        json.dumps([{"type": "file", "title": "notes.txt", "path": "/tmp/notes.txt"}])
    )
    assert len(attachments) == 1
    assert attachments[0].title == "notes.txt"


def test_upload_helpers_normalize_names_and_detect_code_files() -> None:
    assert sanitize_upload_name(" notes draft .txt ") == "notes-draft-.txt"
    assert sanitize_upload_name("...") == "attachment"
    assert artifact_type_for_upload("script.py", None) == "code"
    assert artifact_type_for_upload("photo.bin", "image/png") == "image"
    assert artifact_type_for_upload("archive.bin", None) == "file"
