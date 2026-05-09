from __future__ import annotations

import json
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.models.schemas import (
    CredentialRequestCreateRequest,
    CredentialRequestFulfillRequest,
    CredentialRequestFulfillResponse,
    CredentialRequestRecord,
    CredentialRequestResolveResponse,
)


class CredentialRequestNotFoundError(KeyError):
    pass


class CredentialRequestConflictError(ValueError):
    pass


class CredentialRequestValidationError(ValueError):
    pass


class CredentialRequestService:
    def __init__(self, path: Path, *, max_value_chars: int = 16_000) -> None:
        self._path = path
        self._max_value_chars = max_value_chars
        self._lock = threading.Lock()
        self._credential_values: dict[str, dict[str, str]] = {}

    def create(self, payload: CredentialRequestCreateRequest) -> CredentialRequestRecord:
        now = _utc_now()
        record = CredentialRequestRecord(
            request_id=str(uuid.uuid4()),
            session_id=payload.session_id.strip(),
            run_id=(payload.run_id or "").strip() or None,
            title=payload.title.strip(),
            reason=payload.reason.strip(),
            fields=payload.fields,
            status="pending",
            created_at=_format_time(now),
            expires_at=_format_time(now + timedelta(seconds=payload.expires_in_seconds)),
            updated_at=_format_time(now),
        )
        with self._lock:
            records = self._load_records_locked()
            records.append(record)
            self._write_records_locked(records)
        return record

    def list(
        self,
        *,
        session_id: str | None = None,
        status: str | None = None,
    ) -> list[CredentialRequestRecord]:
        with self._lock:
            records = self._load_records_locked()
            records = self._expire_pending_records_locked(records)
            filtered = records
            if session_id:
                normalized_session_id = session_id.strip()
                filtered = [record for record in filtered if record.session_id == normalized_session_id]
            if status:
                normalized_status = status.strip().lower()
                filtered = [record for record in filtered if record.status == normalized_status]
            return sorted(filtered, key=lambda record: record.created_at, reverse=True)

    def get(self, request_id: str) -> CredentialRequestRecord:
        with self._lock:
            records = self._load_records_locked()
            records = self._expire_pending_records_locked(records)
            for record in records:
                if record.request_id == request_id:
                    return record
        raise CredentialRequestNotFoundError(request_id)

    def fulfill(
        self,
        request_id: str,
        payload: CredentialRequestFulfillRequest,
    ) -> CredentialRequestFulfillResponse:
        if payload.persist:
            raise CredentialRequestValidationError(
                "persistent credential storage is not available yet; retry with persist=false"
            )
        with self._lock:
            records = self._load_records_locked()
            records = self._expire_pending_records_locked(records)
            for index, record in enumerate(records):
                if record.request_id != request_id:
                    continue
                self._ensure_pending(record)
                submitted_values = self._validated_values(record, payload.values)
                handle = f"credential-request://{record.request_id}"
                self._credential_values[handle] = submitted_values
                updated = record.model_copy(
                    update={
                        "status": "fulfilled",
                        "fulfilled_at": _format_time(_utc_now()),
                        "updated_at": _format_time(_utc_now()),
                        "submitted_fields": sorted(submitted_values),
                        "credential_handle": handle,
                    }
                )
                records[index] = updated
                self._write_records_locked(records)
                return CredentialRequestFulfillResponse(
                    request_id=updated.request_id,
                    status="fulfilled",
                    credential_handle=handle,
                    submitted_fields=updated.submitted_fields,
                )
        raise CredentialRequestNotFoundError(request_id)

    def resolve(self, request_id: str, *, consume: bool = True) -> CredentialRequestResolveResponse:
        with self._lock:
            records = self._load_records_locked()
            records = self._expire_pending_records_locked(records)
            for record in records:
                if record.request_id != request_id:
                    continue
                if record.status != "fulfilled":
                    raise CredentialRequestConflictError(f"credential request is {record.status}")
                handle = record.credential_handle or f"credential-request://{record.request_id}"
                values = self._credential_values.get(handle)
                if values is None:
                    raise CredentialRequestConflictError(
                        "credential values are unavailable or already consumed"
                    )
                if consume:
                    values = self._credential_values.pop(handle)
                return CredentialRequestResolveResponse(
                    request_id=record.request_id,
                    status="resolved",
                    credential_handle=handle,
                    values=dict(values),
                )
        raise CredentialRequestNotFoundError(request_id)

    def cancel(self, request_id: str) -> CredentialRequestRecord:
        with self._lock:
            records = self._load_records_locked()
            records = self._expire_pending_records_locked(records)
            for index, record in enumerate(records):
                if record.request_id != request_id:
                    continue
                self._ensure_pending(record)
                updated = record.model_copy(
                    update={
                        "status": "cancelled",
                        "updated_at": _format_time(_utc_now()),
                    }
                )
                records[index] = updated
                self._write_records_locked(records)
                return updated
        raise CredentialRequestNotFoundError(request_id)

    def _validated_values(
        self,
        record: CredentialRequestRecord,
        values: dict[str, str],
    ) -> dict[str, str]:
        field_ids = {field.id for field in record.fields}
        unknown = sorted(key for key in values if key not in field_ids)
        if unknown:
            raise CredentialRequestValidationError(f"unknown credential field(s): {', '.join(unknown)}")
        missing = [
            field.label
            for field in record.fields
            if not field.optional and not values.get(field.id, "").strip()
        ]
        if missing:
            raise CredentialRequestValidationError(f"missing required credential field(s): {', '.join(missing)}")
        too_large = [
            key
            for key, value in values.items()
            if len(value) > self._max_value_chars
        ]
        if too_large:
            raise CredentialRequestValidationError(f"credential field too large: {', '.join(sorted(too_large))}")
        return dict(values)

    @staticmethod
    def _ensure_pending(record: CredentialRequestRecord) -> None:
        if record.status != "pending":
            raise CredentialRequestConflictError(f"credential request is {record.status}")

    def _expire_pending_records_locked(
        self,
        records: list[CredentialRequestRecord],
    ) -> list[CredentialRequestRecord]:
        now = _utc_now()
        changed = False
        updated_records: list[CredentialRequestRecord] = []
        for record in records:
            if record.status == "pending" and _parse_time(record.expires_at) <= now:
                record = record.model_copy(
                    update={
                        "status": "expired",
                        "updated_at": _format_time(now),
                    }
                )
                changed = True
            updated_records.append(record)
        if changed:
            self._write_records_locked(updated_records)
        return updated_records

    def _load_records_locked(self) -> list[CredentialRequestRecord]:
        if not self._path.exists():
            return []
        try:
            payload = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        if not isinstance(payload, list):
            return []
        records: list[CredentialRequestRecord] = []
        for item in payload:
            if not isinstance(item, dict):
                continue
            try:
                records.append(CredentialRequestRecord.model_validate(item))
            except ValueError:
                continue
        return records

    def _write_records_locked(self, records: list[CredentialRequestRecord]) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = [record.model_dump(mode="json") for record in records]
        self._path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _format_time(value: datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def _parse_time(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)
