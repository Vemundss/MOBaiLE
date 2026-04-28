from __future__ import annotations

from pathlib import Path

import pytest
from fastapi import HTTPException

from app.models.schemas import ChatArtifact
from app.runtime_environment import RuntimeEnvironment
from app.workspace_service import WorkspaceService


def _environment(monkeypatch, tmp_path: Path, **extra_env: str) -> RuntimeEnvironment:
    for name in (
        "VOICE_AGENT_DEFAULT_WORKDIR",
        "VOICE_AGENT_SECURITY_MODE",
        "VOICE_AGENT_FILE_ROOTS",
        "VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS",
    ):
        monkeypatch.delenv(name, raising=False)

    monkeypatch.setenv("VOICE_AGENT_API_TOKEN", "test-token")
    monkeypatch.setenv("VOICE_AGENT_DEFAULT_WORKDIR", str(tmp_path / "workspace"))
    for key, value in extra_env.items():
        monkeypatch.setenv(key, value)
    return RuntimeEnvironment.from_env(tmp_path)


def test_workspace_service_lists_directories_before_files(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path)
    service = WorkspaceService(env)
    (env.default_workdir / "src").mkdir(parents=True, exist_ok=True)
    (env.default_workdir / "README.md").write_text("hello", encoding="utf-8")

    listing = service.list_directory(str(env.default_workdir))

    assert listing.path == str(env.default_workdir)
    names = [entry.name for entry in listing.entries]
    assert "src" in names
    assert "README.md" in names
    assert names.index("src") < names.index("README.md")
    readme = next(entry for entry in listing.entries if entry.name == "README.md")
    assert readme.size_bytes == 5
    assert readme.mime in {"text/markdown", "text/x-markdown"}
    assert next(entry for entry in listing.entries if entry.name == "src").size_bytes is None
    assert listing.truncated is False


def test_workspace_service_truncates_after_sorted_prefix(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path, VOICE_AGENT_MAX_DIRECTORY_ENTRIES="2")
    service = WorkspaceService(env)
    (env.default_workdir / "b-dir").mkdir(parents=True, exist_ok=True)
    (env.default_workdir / "a-dir").mkdir(parents=True, exist_ok=True)
    (env.default_workdir / "c-file.txt").write_text("hello", encoding="utf-8")

    listing = service.list_directory(str(env.default_workdir))

    assert [entry.name for entry in listing.entries] == ["a-dir", "b-dir"]
    assert listing.truncated is True


def test_workspace_service_hides_internal_uploads_root_from_parent_listing(
    monkeypatch,
    tmp_path: Path,
) -> None:
    env = _environment(monkeypatch, tmp_path)
    service = WorkspaceService(env)
    (env.default_workdir / "src").mkdir(parents=True, exist_ok=True)

    listing = service.list_directory(str(env.default_workdir))

    assert [entry.name for entry in listing.entries] == ["src"]
    assert listing.truncated is False


def test_workspace_service_create_directory_uses_default_workdir_for_relative_paths(
    monkeypatch,
    tmp_path: Path,
) -> None:
    env = _environment(monkeypatch, tmp_path)
    service = WorkspaceService(env)

    created = service.create_directory("notes/archive")

    assert created.created is True
    assert created.path == str((env.default_workdir / "notes" / "archive").resolve())
    assert Path(created.path).is_dir()


def test_workspace_service_allows_allowed_absolute_paths_when_absolute_reads_disabled(
    monkeypatch,
    tmp_path: Path,
) -> None:
    env = _environment(
        monkeypatch,
        tmp_path,
        VOICE_AGENT_FILE_ROOTS=str(tmp_path),
        VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS="false",
    )
    service = WorkspaceService(env)
    sample = env.default_workdir / "sample.txt"
    sample.write_text("hello", encoding="utf-8")

    response = service.file_response(str(sample))

    assert response.path == str(sample)


def test_workspace_service_blocks_outside_absolute_paths_when_absolute_reads_disabled(
    monkeypatch,
    tmp_path: Path,
) -> None:
    env = _environment(
        monkeypatch,
        tmp_path,
        VOICE_AGENT_FILE_ROOTS=str(tmp_path / "workspace"),
        VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS="false",
    )
    service = WorkspaceService(env)
    outside = tmp_path / "outside.txt"
    outside.write_text("hello", encoding="utf-8")

    with pytest.raises(HTTPException, match="absolute file paths are disabled in safe mode"):
        service.file_response(str(outside))


def test_workspace_service_allows_uploaded_artifact_paths_when_absolute_reads_disabled(
    monkeypatch,
    tmp_path: Path,
) -> None:
    env = _environment(monkeypatch, tmp_path, VOICE_AGENT_ALLOW_ABSOLUTE_FILE_READS="false")
    service = WorkspaceService(env)

    upload = service.store_upload(
        session_id="ios-session",
        filename="notes.txt",
        content_type="text/plain",
        file_bytes=b"hello from phone",
    )
    response = service.file_response(upload.artifact.path)

    assert upload.artifact.title == "notes.txt"
    assert Path(upload.artifact.path).exists()
    assert response.path == upload.artifact.path


def test_workspace_service_rejects_empty_uploads(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path)
    service = WorkspaceService(env)

    with pytest.raises(HTTPException, match="uploaded file is empty"):
        service.store_upload(
            session_id="ios-session",
            filename="empty.txt",
            content_type="text/plain",
            file_bytes=b"",
        )


def test_workspace_service_normalizes_backend_file_url_attachments(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path)
    service = WorkspaceService(env)
    sample = env.default_workdir / "notes.txt"
    sample.parent.mkdir(parents=True, exist_ok=True)
    sample.write_text("hello", encoding="utf-8")

    [validated] = service.validate_attachment_artifacts([
        ChatArtifact(
            type="file",
            title="notes.txt",
            url=f"https://stale-host.example/v1/files?path={sample}",
        )
    ])

    assert validated.path == str(sample)
    assert validated.url is None


def test_workspace_service_inspects_text_file_with_bounded_preview(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path)
    service = WorkspaceService(env)
    sample = env.default_workdir / "notes.txt"
    sample.parent.mkdir(parents=True, exist_ok=True)
    sample.write_text("hello\nworld\nagain", encoding="utf-8")

    inspected = service.inspect_file(str(sample), text_preview_bytes=11)

    assert inspected.name == "notes.txt"
    assert inspected.path == str(sample)
    assert inspected.size_bytes == 17
    assert inspected.mime == "text/plain"
    assert inspected.artifact_type == "code"
    assert inspected.text_preview == "hello\nworld"
    assert inspected.text_preview_bytes == 11
    assert inspected.text_preview_truncated is True
    assert inspected.image_width is None
    assert inspected.image_height is None


def test_workspace_service_inspects_png_dimensions_without_text_preview(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path)
    service = WorkspaceService(env)
    image = env.default_workdir / "plot.png"
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + (13).to_bytes(4, "big")
        + b"IHDR"
        + (32).to_bytes(4, "big")
        + (18).to_bytes(4, "big")
        + b"\x08\x02\x00\x00\x00"
    )

    inspected = service.inspect_file(str(image))

    assert inspected.mime == "image/png"
    assert inspected.artifact_type == "image"
    assert inspected.image_width == 32
    assert inspected.image_height == 18
    assert inspected.text_preview is None
    assert inspected.text_preview_truncated is False


def test_workspace_service_inspect_does_not_preview_profile_state_content(monkeypatch, tmp_path: Path) -> None:
    env = _environment(monkeypatch, tmp_path, VOICE_AGENT_FILE_ROOTS=str(tmp_path))
    service = WorkspaceService(env)
    profile_file = env.profile_state_root / "default-user" / "AGENTS.md"
    profile_file.parent.mkdir(parents=True, exist_ok=True)
    profile_file.write_text("private profile guidance", encoding="utf-8")

    inspected = service.inspect_file(str(profile_file))

    assert inspected.size_bytes == len("private profile guidance")
    assert inspected.text_preview is None
    assert inspected.text_preview_bytes == 0
    assert inspected.text_preview_truncated is False
