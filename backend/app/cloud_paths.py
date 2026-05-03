from __future__ import annotations

from pathlib import Path


def is_cloud_synced_path(path: Path) -> bool:
    raw = str(path.expanduser())
    cloud_markers = (
        "/Library/Mobile Documents/",
        "/Library/CloudStorage/iCloud Drive/",
    )
    return any(marker in raw for marker in cloud_markers)
