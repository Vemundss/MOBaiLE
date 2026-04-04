from __future__ import annotations

import json
import secrets
from datetime import datetime
from datetime import timedelta
from datetime import timezone
from pathlib import Path
from typing import Callable


HashToken = Callable[[str], str]


class PairingState:
    def __init__(self, pairing_file: Path) -> None:
        self._pairing_file = pairing_file

    def read(self) -> dict[str, object]:
        if not self._pairing_file.exists():
            return {}
        try:
            return json.loads(self._pairing_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def write(self, payload: dict[str, object]) -> None:
        self._pairing_file.parent.mkdir(parents=True, exist_ok=True)
        self._pairing_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    def server_urls(self, payload: dict[str, object]) -> list[str]:
        seen: set[str] = set()
        urls: list[str] = []

        for raw in payload.get("server_urls", []) if isinstance(payload.get("server_urls"), list) else []:
            if not isinstance(raw, str):
                continue
            candidate = raw.strip().rstrip("/")
            if not candidate or candidate in seen:
                continue
            seen.add(candidate)
            urls.append(candidate)

        primary = str(payload.get("server_url", "")).strip().rstrip("/")
        if primary and primary not in seen:
            urls.insert(0, primary)

        return urls

    def rotate_pair_code(self, payload: dict[str, object], *, ttl_min: int) -> None:
        payload["pair_code"] = secrets.token_urlsafe(10)
        payload["pair_code_expires_at"] = (
            datetime.now(timezone.utc) + timedelta(minutes=ttl_min)
        ).isoformat().replace("+00:00", "Z")
        self.write(payload)

    def paired_client_records(self, payload: dict[str, object]) -> list[dict[str, str]]:
        raw = payload.get("paired_clients")
        if not isinstance(raw, list):
            return []

        records: list[dict[str, str]] = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            token_hash = str(item.get("token_sha256", "")).strip()
            if not token_hash:
                continue
            records.append(
                {
                    "token_sha256": token_hash,
                    "refresh_token_sha256": str(item.get("refresh_token_sha256", "")).strip(),
                    "session_id": str(item.get("session_id", "")).strip(),
                    "issued_at": str(item.get("issued_at", "")).strip(),
                    "refreshed_at": str(item.get("refreshed_at", "")).strip(),
                }
            )
        return records

    def paired_client_record_index_for_hashed_token(
        self,
        records: list[dict[str, str]],
        *,
        field: str,
        token: str,
        hash_token: HashToken,
    ) -> int | None:
        token_hash = hash_token(token)
        for index, record in enumerate(records):
            candidate = record.get(field, "")
            if candidate and secrets.compare_digest(candidate, token_hash):
                return index
        return None

    def pairing_token_matches(
        self,
        payload: dict[str, object],
        token: str,
        *,
        hash_token: HashToken,
    ) -> bool:
        return (
            self.paired_client_record_index_for_hashed_token(
                self.paired_client_records(payload),
                field="token_sha256",
                token=token,
                hash_token=hash_token,
            )
            is not None
        )

    def issue_paired_client_credentials(
        self,
        payload: dict[str, object],
        *,
        session_id: str,
        max_paired_client_tokens: int,
        hash_token: HashToken,
    ) -> tuple[str, str]:
        token = secrets.token_urlsafe(32)
        refresh_token = secrets.token_urlsafe(32)
        records = self.paired_client_records(payload)
        records.append(
            {
                "token_sha256": hash_token(token),
                "refresh_token_sha256": hash_token(refresh_token),
                "session_id": session_id,
                "issued_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "refreshed_at": "",
            }
        )
        payload["paired_clients"] = records[-max_paired_client_tokens:]
        self.write(payload)
        return token, refresh_token

    def store_paired_client_records(
        self,
        payload: dict[str, object],
        records: list[dict[str, str]],
        *,
        max_paired_client_tokens: int,
    ) -> None:
        payload["paired_clients"] = records[-max_paired_client_tokens:]
        self.write(payload)
