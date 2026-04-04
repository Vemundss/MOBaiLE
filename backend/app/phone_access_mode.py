from __future__ import annotations

from typing import Literal


PhoneAccessMode = Literal["tailscale", "wifi", "local"]
PHONE_ACCESS_MODE_OPTIONS = ("tailscale", "wifi", "local")


def normalize_phone_access_mode(phone_access_mode: str) -> PhoneAccessMode:
    normalized = phone_access_mode.strip().lower()
    if normalized not in PHONE_ACCESS_MODE_OPTIONS:
        return "tailscale"
    return normalized  # type: ignore[return-value]
