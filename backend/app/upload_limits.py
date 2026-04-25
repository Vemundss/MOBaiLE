from __future__ import annotations

from fastapi import HTTPException, UploadFile

from app.models.schemas import ApiErrorDetail

UPLOAD_READ_CHUNK_BYTES = 1024 * 1024


def payload_too_large_error(
    *,
    code: str,
    message: str,
    field: str,
    limit_bytes: int,
    limit_mb: float,
    received_bytes: int | None = None,
) -> HTTPException:
    detail = ApiErrorDetail(
        code=code,
        message=message,
        field=field,
        limit_bytes=limit_bytes,
        limit_mb=limit_mb,
        received_bytes=received_bytes,
    )
    return HTTPException(status_code=413, detail=detail.model_dump())


async def read_upload_bytes_limited(
    upload: UploadFile,
    *,
    field: str,
    max_bytes: int,
    max_mb: float,
) -> bytes:
    received = 0
    chunks: list[bytes] = []
    while True:
        chunk = await upload.read(UPLOAD_READ_CHUNK_BYTES)
        if not chunk:
            return b"".join(chunks)
        received += len(chunk)
        if received > max_bytes:
            raise payload_too_large_error(
                code=f"{field}_too_large",
                message=f"{field} payload too large (max {max_mb:g} MB)",
                field=field,
                limit_bytes=max_bytes,
                limit_mb=max_mb,
                received_bytes=received,
            )
        chunks.append(chunk)


def validate_upload_content_length(
    upload: UploadFile,
    *,
    field: str,
    max_bytes: int,
    max_mb: float,
) -> None:
    content_length_header = upload.headers.get("content-length")
    if not content_length_header:
        return
    try:
        content_length = int(content_length_header)
    except ValueError:
        return
    if content_length > max_bytes:
        raise payload_too_large_error(
            code=f"{field}_too_large",
            message=f"{field} payload too large (max {max_mb:g} MB)",
            field=field,
            limit_bytes=max_bytes,
            limit_mb=max_mb,
            received_bytes=content_length,
        )
