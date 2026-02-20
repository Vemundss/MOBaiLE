from __future__ import annotations

import os
from dataclasses import dataclass

import requests


@dataclass
class TranscriptionError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


class Transcriber:
    """Transcription adapter with pluggable providers.

    Providers:
    - mock (default): deterministic local behavior for development.
    - openai: calls OpenAI audio transcription endpoint.
    """

    def __init__(self) -> None:
        self.provider = os.getenv("VOICE_AGENT_TRANSCRIBE_PROVIDER", "mock").strip().lower()
        self.default_mock_text = os.getenv("VOICE_AGENT_TRANSCRIBE_MOCK_TEXT", "").strip()
        self.openai_api_key = os.getenv("OPENAI_API_KEY", "").strip()
        self.openai_model = os.getenv("VOICE_AGENT_TRANSCRIBE_MODEL", "whisper-1").strip()
        self.openai_base_url = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
        self.timeout_sec = float(os.getenv("VOICE_AGENT_TRANSCRIBE_TIMEOUT_SEC", "45"))

    def transcribe(
        self,
        *,
        audio_bytes: bytes,
        filename: str,
        text_hint: str | None = None,
    ) -> str:
        if self.provider == "openai":
            return self._transcribe_openai(audio_bytes=audio_bytes, filename=filename, text_hint=text_hint)
        return self._transcribe_mock(audio_bytes=audio_bytes, filename=filename, text_hint=text_hint)

    def _transcribe_mock(
        self,
        *,
        audio_bytes: bytes,
        filename: str,
        text_hint: str | None = None,
    ) -> str:
        if text_hint and text_hint.strip():
            return text_hint.strip()
        if self.default_mock_text:
            return self.default_mock_text
        name = filename or "audio"
        if not audio_bytes:
            return f"received empty audio payload from {name}"
        return f"transcribed audio from {name}"

    def _transcribe_openai(
        self,
        *,
        audio_bytes: bytes,
        filename: str,
        text_hint: str | None = None,
    ) -> str:
        if text_hint and text_hint.strip():
            return text_hint.strip()
        if not self.openai_api_key:
            raise TranscriptionError("OPENAI_API_KEY is not set for openai transcription provider")
        if not audio_bytes:
            raise TranscriptionError("audio payload is empty")

        url = f"{self.openai_base_url}/audio/transcriptions"
        headers = {"Authorization": f"Bearer {self.openai_api_key}"}
        files = {"file": (filename or "audio.wav", audio_bytes, "application/octet-stream")}
        data = {"model": self.openai_model}

        try:
            response = requests.post(
                url,
                headers=headers,
                files=files,
                data=data,
                timeout=self.timeout_sec,
            )
        except requests.RequestException as exc:
            raise TranscriptionError(f"openai transcription request failed: {exc}") from exc

        if response.status_code >= 400:
            body = response.text.strip()
            detail = body if body else f"status={response.status_code}"
            raise TranscriptionError(f"openai transcription failed: {detail}")

        try:
            payload = response.json()
        except ValueError as exc:
            raise TranscriptionError("openai transcription response was not valid JSON") from exc

        text = str(payload.get("text", "")).strip()
        if not text:
            raise TranscriptionError("openai transcription response did not include text")
        return text
