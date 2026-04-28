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
    FileInspectionResponse,
    UploadResponse,
)
from app.runtime_environment import RuntimeEnvironment

DEFAULT_TEXT_PREVIEW_BYTES = 64 * 1024
MAX_TEXT_PREVIEW_BYTES = 256 * 1024


@dataclass(frozen=True)
class _SortableDirectoryEntry:
    sort_key: tuple[int, str, str]
    name: str
    path: str
    is_directory: bool
    size_bytes: int | None = None
    mime: str | None = None


class WorkspaceService:
    def __init__(self, environment: RuntimeEnvironment):
        self.environment = environment

    def file_response(self, raw_path: str) -> FileResponse:
        target = self._resolve_file_target(raw_path)
        media_type, _ = mimetypes.guess_type(str(target))
        return FileResponse(str(target), media_type=media_type or "application/octet-stream")

    def inspect_file(
        self,
        raw_path: str,
        *,
        text_preview_bytes: int = DEFAULT_TEXT_PREVIEW_BYTES,
    ) -> FileInspectionResponse:
        target = self._resolve_file_target(raw_path)
        size_bytes = target.stat().st_size
        mime = mimetypes.guess_type(target.name)[0]
        artifact_type = artifact_type_for_upload(target.name, mime)
        text_preview, preview_byte_count, text_truncated = self._text_preview(
            target,
            artifact_type=artifact_type,
            mime=mime,
            size_bytes=size_bytes,
            requested_bytes=text_preview_bytes,
        )
        image_width, image_height = self._image_dimensions(target, mime=mime)
        return FileInspectionResponse(
            name=target.name,
            path=str(target),
            size_bytes=size_bytes,
            mime=mime,
            artifact_type=artifact_type,
            text_preview=text_preview,
            text_preview_bytes=preview_byte_count,
            text_preview_truncated=text_truncated,
            image_width=image_width,
            image_height=image_height,
        )

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
                size_bytes=child.size_bytes,
                mime=child.mime,
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

        size_bytes: int | None = None
        mime: str | None = None
        if not is_directory:
            try:
                size_bytes = child.stat(follow_symlinks=False).st_size
            except OSError:
                size_bytes = None
            mime = mimetypes.guess_type(child.name)[0]

        return _SortableDirectoryEntry(
            sort_key=(0 if is_directory else 1, child.name.lower(), child.name),
            name=child.name,
            path=child.path,
            is_directory=is_directory,
            size_bytes=size_bytes,
            mime=mime,
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
                target = self._resolve_file_target(path)
                validated.append(artifact.model_copy(update={"path": str(target)}))
                continue

            backend_path = self._path_from_backend_file_url(url)
            if backend_path is None:
                raise HTTPException(status_code=400, detail="attachment URL must point to /v1/files on this backend")
            target = self._resolve_file_target(backend_path)
            validated.append(artifact.model_copy(update={"path": str(target), "url": None}))
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

    def _text_preview(
        self,
        target: Path,
        *,
        artifact_type: str,
        mime: str | None,
        size_bytes: int,
        requested_bytes: int,
    ) -> tuple[str | None, int, bool]:
        if not self._can_preview_text(target, artifact_type=artifact_type, mime=mime):
            return None, 0, False
        limit = min(max(requested_bytes, 0), MAX_TEXT_PREVIEW_BYTES)
        if limit == 0:
            return "", 0, size_bytes > 0
        try:
            data = target.open("rb").read(limit + 1)
        except OSError as exc:
            raise HTTPException(status_code=403, detail="permission denied for file path") from exc
        preview_data = data[:limit]
        for encoding in ("utf-8", "utf-16", "utf-16-le", "utf-16-be", "iso-8859-1"):
            try:
                text = preview_data.decode(encoding)
                return text, len(preview_data), len(data) > limit or size_bytes > len(preview_data)
            except UnicodeDecodeError:
                continue
        return preview_data.decode("utf-8", errors="replace"), len(preview_data), len(data) > limit

    def _can_preview_text(self, target: Path, *, artifact_type: str, mime: str | None) -> bool:
        if self._is_sensitive_preview_path(target):
            return False
        if artifact_type == "code":
            return True
        lower_mime = (mime or "").lower()
        if lower_mime.startswith("text/"):
            return True
        return any(token in lower_mime for token in ("json", "xml", "yaml", "toml"))

    def _is_sensitive_preview_path(self, target: Path) -> bool:
        sensitive_names = {".env", "pairing.json", "pairing-qr.png"}
        if target.name in sensitive_names:
            return True
        sensitive_roots = [
            self.environment.backend_root / "data",
            self.environment.profile_state_root,
            self.environment.legacy_session_state_root,
        ]
        return any(self._is_relative_to(target, root.resolve()) for root in sensitive_roots)

    def _image_dimensions(self, target: Path, *, mime: str | None) -> tuple[int | None, int | None]:
        lower_mime = (mime or "").lower()
        if not lower_mime.startswith("image/"):
            return None, None
        try:
            header = target.open("rb").read(256 * 1024)
        except OSError:
            return None, None
        return self._png_dimensions(header) or self._gif_dimensions(header) or self._jpeg_dimensions(header) or (None, None)

    @staticmethod
    def _png_dimensions(header: bytes) -> tuple[int, int] | None:
        if len(header) < 24 or not header.startswith(b"\x89PNG\r\n\x1a\n") or header[12:16] != b"IHDR":
            return None
        return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")

    @staticmethod
    def _gif_dimensions(header: bytes) -> tuple[int, int] | None:
        if len(header) < 10 or header[:6] not in {b"GIF87a", b"GIF89a"}:
            return None
        return int.from_bytes(header[6:8], "little"), int.from_bytes(header[8:10], "little")

    @staticmethod
    def _jpeg_dimensions(header: bytes) -> tuple[int, int] | None:
        if len(header) < 4 or not header.startswith(b"\xff\xd8"):
            return None
        offset = 2
        sof_markers = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
        while offset + 8 < len(header):
            if header[offset] != 0xFF:
                offset += 1
                continue
            marker = header[offset + 1]
            if marker in {0xD8, 0xD9}:
                offset += 2
                continue
            segment_length = int.from_bytes(header[offset + 2 : offset + 4], "big")
            if segment_length < 2:
                return None
            if marker in sof_markers and offset + 8 < len(header):
                height = int.from_bytes(header[offset + 5 : offset + 7], "big")
                width = int.from_bytes(header[offset + 7 : offset + 9], "big")
                return width, height
            offset += 2 + segment_length
        return None

    @staticmethod
    def _is_relative_to(path: Path, root: Path) -> bool:
        try:
            path.relative_to(root)
            return True
        except ValueError:
            return False
