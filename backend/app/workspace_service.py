from __future__ import annotations

import heapq
import mimetypes
import os
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from fastapi import HTTPException
from fastapi.responses import FileResponse

from app.chat_attachments import artifact_type_for_upload, sanitize_upload_name
from app.models.schemas import (
    ChatArtifact,
    DirectoryCreateResponse,
    DirectoryEntry,
    DirectoryListingResponse,
    UploadResponse,
)
from app.runtime_environment import RuntimeEnvironment


@dataclass(frozen=True)
class _SortableDirectoryEntry:
    sort_key: tuple[int, str, str]
    name: str
    path: str
    is_directory: bool


class WorkspaceService:
    def __init__(self, environment: RuntimeEnvironment):
        self.environment = environment

    def file_response(self, raw_path: str) -> FileResponse:
        target = self._resolve_file_target(raw_path)
        media_type, _ = mimetypes.guess_type(str(target))
        return FileResponse(str(target), media_type=media_type or "application/octet-stream")

    def list_directory(self, raw_path: str | None) -> DirectoryListingResponse:
        target = self._resolve_workspace_path(raw_path)
        self._ensure_allowed_path(target, detail="directory path is outside allowed roots")
        if not target.exists() or not target.is_dir():
            raise HTTPException(status_code=404, detail="directory not found")

        limit = max(self.environment.max_directory_entries, 0)
        try:
            with os.scandir(target) as children:
                visible_children = heapq.nsmallest(
                    limit + 1,
                    filter(
                        None,
                        (self._sortable_directory_entry(target, child) for child in children),
                    ),
                    key=lambda item: item.sort_key,
                )
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail="permission denied for directory path") from exc

        truncated = len(visible_children) > limit
        entries = [
            DirectoryEntry(
                name=child.name,
                path=child.path,
                is_directory=child.is_directory,
            )
            for child in visible_children[:limit]
        ]
        return DirectoryListingResponse(path=str(target), entries=entries, truncated=truncated)

    def _sortable_directory_entry(
        self,
        parent: Path,
        child: os.DirEntry[str],
    ) -> _SortableDirectoryEntry | None:
        if self._is_internal_uploads_directory(parent, child):
            return None

        try:
            is_directory = child.is_dir()
        except OSError:
            is_directory = False

        return _SortableDirectoryEntry(
            sort_key=(0 if is_directory else 1, child.name.lower(), child.name),
            name=child.name,
            path=child.path,
            is_directory=is_directory,
        )

    def _is_internal_uploads_directory(self, parent: Path, child: os.DirEntry[str]) -> bool:
        return (
            parent == self.environment.uploads_root.parent
            and child.name == self.environment.uploads_root.name
        )

    def create_directory(self, raw_path: str) -> DirectoryCreateResponse:
        target = self._resolve_workspace_path(raw_path)
        self._ensure_allowed_path(target, detail="directory path is outside allowed roots")
        if target.exists() and not target.is_dir():
            raise HTTPException(status_code=409, detail="path exists and is not a directory")

        created = False
        if not target.exists():
            try:
                target.mkdir(parents=True, exist_ok=True)
                created = True
            except OSError as exc:
                raise HTTPException(status_code=403, detail="permission denied for directory path") from exc

        return DirectoryCreateResponse(path=str(target), created=created)

    def store_upload(
        self,
        *,
        session_id: str,
        filename: str | None,
        content_type: str | None,
        file_bytes: bytes,
    ) -> UploadResponse:
        if not file_bytes:
            raise HTTPException(status_code=400, detail="uploaded file is empty")

        target_dir = self.environment.upload_session_dir(session_id)
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise HTTPException(status_code=403, detail="permission denied for upload path") from exc

        file_name = sanitize_upload_name(filename or "attachment")
        target = (target_dir / f"{uuid.uuid4()}-{file_name}").resolve()
        self._ensure_allowed_path(target, detail="upload path is outside allowed roots")
        try:
            target.write_bytes(file_bytes)
        except OSError as exc:
            raise HTTPException(status_code=403, detail="permission denied for upload path") from exc

        mime = (content_type or "").strip() or mimetypes.guess_type(file_name)[0]
        artifact = ChatArtifact(
            type=artifact_type_for_upload(file_name, mime),
            title=file_name,
            path=str(target),
            mime=mime,
        )
        return UploadResponse(artifact=artifact, size_bytes=len(file_bytes))

    def validate_attachment_artifacts(self, attachments: list[ChatArtifact]) -> list[ChatArtifact]:
        validated: list[ChatArtifact] = []
        for artifact in attachments:
            path = (artifact.path or "").strip()
            url = (artifact.url or "").strip()
            if not path and not url:
                raise HTTPException(status_code=400, detail="attachment must include a file path or backend file URL")
            if path:
                self._resolve_file_target(path)
                validated.append(artifact)
                continue

            backend_path = self._path_from_backend_file_url(url)
            if backend_path is None:
                raise HTTPException(status_code=400, detail="attachment URL must point to /v1/files on this backend")
            self._resolve_file_target(backend_path)
            validated.append(artifact)
        return validated

    def _resolve_file_target(self, raw_path: str) -> Path:
        target = Path(raw_path.strip()).expanduser()
        if target.is_absolute():
            target = target.resolve()
            if not self.environment.allow_absolute_file_reads and not self.environment.is_path_allowed(target):
                raise HTTPException(
                    status_code=403,
                    detail="absolute file paths are disabled in safe mode",
                )
        else:
            target = (self.environment.default_workdir / target).resolve()

        self._ensure_allowed_path(target, detail="file path is outside allowed roots")
        if not target.exists() or not target.is_file():
            raise HTTPException(status_code=404, detail="file not found")
        return target

    def _path_from_backend_file_url(self, raw_url: str) -> str | None:
        parsed = urlparse(raw_url)
        if parsed.path != "/v1/files":
            return None
        values = parse_qs(parsed.query).get("path", [])
        if not values:
            return None
        return values[0]

    def _resolve_workspace_path(self, raw_path: str | None) -> Path:
        raw_value = (raw_path or "").strip()
        if not raw_value:
            return self.environment.default_workdir

        target = Path(raw_value).expanduser()
        if target.is_absolute():
            return target.resolve()
        return (self.environment.default_workdir / target).resolve()

    def _ensure_allowed_path(self, target: Path, *, detail: str) -> None:
        if not self.environment.is_path_allowed(target):
            raise HTTPException(status_code=403, detail=detail)

    @staticmethod
    def _is_relative_to(path: Path, root: Path) -> bool:
        try:
            path.relative_to(root)
            return True
        except ValueError:
            return False
