from __future__ import annotations

import hashlib
import secrets
import threading
import time
from datetime import datetime, timezone

from fastapi import HTTPException

from app.models.schemas import (
    PairExchangeRequest,
    PairExchangeResponse,
    PairRefreshRequest,
)
from app.pairing_state import PairingState
from app.runtime_environment import RuntimeEnvironment


class PairingService:
    def __init__(self, env: RuntimeEnvironment, *, max_paired_client_tokens: int = 12) -> None:
        self._env = env
        self._state = PairingState(env.pairing_file)
        self._max_paired_client_tokens = max_paired_client_tokens
        self._pair_attempts_lock = threading.Lock()
        self._pair_attempts: dict[str, list[float]] = {}
        self._pair_exchange_lock = threading.Lock()

    def has_configured_api_token(self) -> bool:
        pairing = self._read_pairing_file()
        return bool(self._env.api_token) or bool(self._paired_client_records(pairing))

    def is_authorized_api_token(self, auth_header: str) -> bool:
        pairing = self._read_pairing_file()
        token = self._extract_bearer_token(auth_header)
        if not token:
            return False
        if self._env.api_token and secrets.compare_digest(token, self._env.api_token):
            return True
        return self._pairing_token_matches(pairing, token)

    def pairing_server_urls(self) -> list[str]:
        return self._pairing_server_urls(self._read_pairing_file())

    def exchange_pair_code(self, payload: PairExchangeRequest, *, client_id: str) -> PairExchangeResponse:
        self._enforce_pair_rate_limit(client_id)
        with self._pair_exchange_lock:
            pairing = self._read_pairing_file()
            expected = str(pairing.get("pair_code", "")).strip()
            expires_at = str(pairing.get("pair_code_expires_at", "")).strip()
            if not expected or not expires_at:
                raise HTTPException(status_code=503, detail="pairing code is not configured")
            if not secrets.compare_digest(payload.pair_code.strip(), expected):
                raise HTTPException(status_code=401, detail="invalid pairing code")
            try:
                expires = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
            except ValueError as exc:
                raise HTTPException(status_code=503, detail="pairing code configuration is invalid") from exc
            if datetime.now(tz=expires.tzinfo) > expires:
                raise HTTPException(status_code=401, detail="pairing code expired")

            self._rotate_pair_code(pairing)
            session_id = payload.session_id or str(pairing.get("session_id", "iphone-app")).strip() or "iphone-app"
            api_token, refresh_token = self._issue_paired_client_credentials(pairing, session_id=session_id)
            return self._pair_credentials_response(
                pairing,
                api_token=api_token,
                refresh_token=refresh_token,
                session_id=session_id,
            )

    def refresh_pairing_credentials(
        self,
        payload: PairRefreshRequest,
        *,
        auth_header: str,
        client_id: str,
    ) -> PairExchangeResponse:
        self._enforce_pair_rate_limit(client_id)
        with self._pair_exchange_lock:
            pairing = self._read_pairing_file()
            api_token, refresh_token, session_id = self._refresh_paired_client_credentials(
                pairing,
                auth_header=auth_header,
                refresh_token=payload.refresh_token,
                session_id=payload.session_id,
            )
            return self._pair_credentials_response(
                pairing,
                api_token=api_token,
                refresh_token=refresh_token,
                session_id=session_id,
            )

    def hash_api_token(self, token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    def _read_pairing_file(self) -> dict[str, object]:
        return self._state.read()

    def _pairing_server_urls(self, payload: dict[str, object]) -> list[str]:
        return self._state.server_urls(payload)

    def _write_pairing_file(self, payload: dict[str, object]) -> None:
        self._state.write(payload)

    def _rotate_pair_code(self, payload: dict[str, object]) -> None:
        self._state.rotate_pair_code(payload, ttl_min=self._env.pair_code_ttl_min)

    def _pair_credentials_response(
        self,
        pairing: dict[str, object],
        *,
        api_token: str,
        refresh_token: str,
        session_id: str,
    ) -> PairExchangeResponse:
        server_urls = self._pairing_server_urls(pairing)
        return PairExchangeResponse(
            api_token=api_token,
            refresh_token=refresh_token,
            session_id=session_id,
            security_mode=self._env.security_mode,  # type: ignore[arg-type]
            server_url=server_urls[0] if server_urls else str(pairing.get("server_url", "")).strip() or None,
            server_urls=server_urls,
        )

    def _extract_bearer_token(self, auth_header: str) -> str:
        prefix = "Bearer "
        if not auth_header.startswith(prefix):
            return ""
        return auth_header[len(prefix):].strip()

    def _paired_client_records(self, payload: dict[str, object]) -> list[dict[str, str]]:
        return self._state.paired_client_records(payload)

    def _paired_client_record_index_for_hashed_token(
        self,
        records: list[dict[str, str]],
        *,
        field: str,
        token: str,
    ) -> int | None:
        return self._state.paired_client_record_index_for_hashed_token(
            records,
            field=field,
            token=token,
            hash_token=self.hash_api_token,
        )

    def _pairing_token_matches(self, payload: dict[str, object], token: str) -> bool:
        return self._state.pairing_token_matches(payload, token, hash_token=self.hash_api_token)

    def _issue_paired_client_credentials(self, payload: dict[str, object], *, session_id: str) -> tuple[str, str]:
        return self._state.issue_paired_client_credentials(
            payload,
            session_id=session_id,
            max_paired_client_tokens=self._max_paired_client_tokens,
            hash_token=self.hash_api_token,
        )

    def _refresh_paired_client_credentials(
        self,
        payload: dict[str, object],
        *,
        auth_header: str,
        refresh_token: str | None,
        session_id: str | None,
    ) -> tuple[str, str, str]:
        records = self._paired_client_records(payload)
        normalized_refresh_token = (refresh_token or "").strip()
        normalized_auth_token = self._extract_bearer_token(auth_header)

        if normalized_refresh_token:
            record_index = self._paired_client_record_index_for_hashed_token(
                records,
                field="refresh_token_sha256",
                token=normalized_refresh_token,
            )
            if record_index is None:
                raise HTTPException(status_code=401, detail="missing or invalid refresh token")

            record = records[record_index]
            next_api_token = secrets.token_urlsafe(32)
            record["token_sha256"] = self.hash_api_token(next_api_token)
            record["refreshed_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            effective_session_id = record.get("session_id", "").strip() or session_id or "iphone-app"
            records[record_index] = record
            self._state.store_paired_client_records(
                payload,
                records,
                max_paired_client_tokens=self._max_paired_client_tokens,
            )
            return next_api_token, normalized_refresh_token, effective_session_id

        if not normalized_auth_token:
            raise HTTPException(status_code=401, detail="missing refresh token")
        if self._env.api_token and secrets.compare_digest(normalized_auth_token, self._env.api_token):
            raise HTTPException(status_code=403, detail="refresh bootstrap is only available for paired phones")

        record_index = self._paired_client_record_index_for_hashed_token(
            records,
            field="token_sha256",
            token=normalized_auth_token,
        )
        if record_index is None:
            raise HTTPException(status_code=401, detail="missing or invalid bearer token")

        record = records[record_index]
        next_refresh_token = secrets.token_urlsafe(32)
        record["refresh_token_sha256"] = self.hash_api_token(next_refresh_token)
        record["refreshed_at"] = record.get("refreshed_at", "").strip()
        if session_id and not record.get("session_id", "").strip():
            record["session_id"] = session_id
        effective_session_id = record.get("session_id", "").strip() or session_id or "iphone-app"
        records[record_index] = record
        self._state.store_paired_client_records(
            payload,
            records,
            max_paired_client_tokens=self._max_paired_client_tokens,
        )
        return normalized_auth_token, next_refresh_token, effective_session_id

    def _enforce_pair_rate_limit(self, client_id: str) -> None:
        now = time.monotonic()
        with self._pair_attempts_lock:
            attempts = self._pair_attempts.get(client_id, [])
            attempts = [t for t in attempts if now - t <= 60.0]
            if len(attempts) >= self._env.pair_attempt_limit_per_min:
                raise HTTPException(status_code=429, detail="too many pairing attempts, try again soon")
            attempts.append(now)
            self._pair_attempts[client_id] = attempts
