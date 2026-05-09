from __future__ import annotations

import os
from pathlib import Path

from app.host_tools import resolve_binary_path
from app.models.schemas import CapabilityProbe


def probe_binary(capability_id: str, title: str, binary: str) -> CapabilityProbe:
    trimmed = binary.strip()
    resolved = resolve_binary_path(trimmed)
    details: dict[str, object] = {"binary": trimmed}
    if resolved:
        details["resolved_path"] = resolved
        return CapabilityProbe(
            id=capability_id,
            title=title,
            status="ready",
            code="ok",
            message=f"{title} is available.",
            details=details,
        )
    return CapabilityProbe(
        id=capability_id,
        title=title,
        status="blocked",
        code="missing_dependency",
        message=f"{title} is not available in PATH.",
        details=details,
    )


def probe_transcriber(provider: str) -> CapabilityProbe:
    normalized = provider.strip().lower() or "openai"
    details: dict[str, object] = {"provider": normalized}
    if normalized == "mock":
        return CapabilityProbe(
            id="transcribe_provider",
            title="Transcription provider",
            status="ready",
            code="ok",
            message="Mock transcription is active.",
            details=details,
        )
    if normalized == "openai":
        if os.getenv("OPENAI_API_KEY", "").strip():
            return CapabilityProbe(
                id="transcribe_provider",
                title="Transcription provider",
                status="ready",
                code="ok",
                message="OpenAI transcription is configured.",
                details=details,
            )
        return CapabilityProbe(
            id="transcribe_provider",
            title="Transcription provider",
            status="blocked",
            code="auth_missing",
            message="OpenAI transcription selected but OPENAI_API_KEY is not set.",
            details=details,
        )
    return CapabilityProbe(
        id="transcribe_provider",
        title="Transcription provider",
        status="degraded",
        code="unknown_provider",
        message=f"Provider '{normalized}' is not recognized by capability probe.",
        details=details,
    )


def probe_codex_search(enabled: bool) -> CapabilityProbe:
    return CapabilityProbe(
        id="codex_web_search",
        title="Codex live web search",
        status="ready" if enabled else "degraded",
        code="ok" if enabled else "disabled",
        message="Codex runs include live web search." if enabled else "Codex live web search is disabled.",
        details={"enabled": enabled},
    )


def probe_playwright_persistence(*, output_dir: Path, user_data_dir: Path) -> CapabilityProbe:
    details = {
        "output_dir": str(output_dir),
        "user_data_dir": str(user_data_dir),
    }
    output_ready = output_dir.exists() and os.access(output_dir, os.W_OK)
    user_data_ready = user_data_dir.exists() and os.access(user_data_dir, os.W_OK)
    if output_ready and user_data_ready:
        return CapabilityProbe(
            id="playwright_persistence",
            title="Playwright persistent state",
            status="ready",
            code="ok",
            message="Persistent Playwright output and browser profile directories are writable.",
            details=details,
        )
    return CapabilityProbe(
        id="playwright_persistence",
        title="Playwright persistent state",
        status="blocked",
        code="path_unavailable",
        message="Persistent Playwright output or browser profile directory is not writable.",
        details=details,
    )
