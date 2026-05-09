from __future__ import annotations

import shutil
from pathlib import Path


def resolve_binary_path(binary: str) -> str:
    trimmed = binary.strip()
    if not trimmed:
        return ""
    if "/" in trimmed or trimmed.startswith("."):
        candidate = Path(trimmed).expanduser()
        if candidate.exists():
            return str(candidate.resolve())
        return ""
    return shutil.which(trimmed) or ""


def binary_available(binary: str) -> bool:
    return bool(resolve_binary_path(binary))
