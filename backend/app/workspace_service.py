from __future__ import annotations

import mimetypes
from pathlib import Path
import uuid

from fastapi import HTTPException
from fastapi.responses import FileResponse

from app.chat_attachments import artifact_type_for_upload
from app.chat_attachments import sanitize_upload_name
from app.models.schemas import ChatArtifact
from app.models.schemas import DirectoryCreateResponse
from app.models.schemas import DirectoryEntry
from app.models.schemas import DirectoryListingResponse
from app.models.schemas import UploadResponse
from app.runtime_environment import RuntimeEnvironment


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

        try:
            children = sorted(target.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower()))
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail="permission denied for directory path") from exc

        entries: list[DirectoryEntry] = []
        truncated = False
        for idx, child in enumerate(children):
            if idx >= self.environment.max_directory_entries:
                truncated = True
                break
            entries.append(
                DirectoryEntry(
                    name=child.name,
                    path=str(child),
                    is_directory=child.is_dir(),
                )
            )
        return DirectoryListingResponse(path=str(target), entries=entries, truncated=truncated)

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

    def _resolve_file_target(self, raw_path: str) -> Path:
        target = Path(raw_path.strip()).expanduser()
        if target.is_absolute():
            target = target.resolve()
            if not self.environment.allow_absolute_file_reads and not self._is_relative_to(
                target,
                self.environment.uploads_root,
            ):
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
