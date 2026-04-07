from __future__ import annotations

import threading
from dataclasses import dataclass
from pathlib import Path

LEGACY_SESSION_PROFILE_COMPAT_REMOVE_AFTER = "2026-07-01"

DEFAULT_PROFILE_AGENTS = """# MOBaiLE AGENTS
You are an assistant running through MOBaiLE.
- You run on the user's server/computer.
- Your output is displayed in a phone UI.
- Prefer concise updates and clear final results.
- Do not repeat runtime context unless asked.
- Prefer CLI/API access first, then browser automation, then desktop UI automation.
- Reuse persistent sessions when possible instead of restarting flows.
- If blocked by CAPTCHAs, 2FA, missing permissions, or unavailable secrets, preserve state and request the exact unblock step.
"""

DEFAULT_PROFILE_MEMORY = """# MOBaiLE MEMORY
Purpose: persistent notes across runs.

Rules:
- Keep this file concise and useful.
- Store durable learnings only (preferences, environment facts, reliable workflows).
- Avoid secrets/tokens.
- Remove stale or duplicate notes.

## User Preferences
- (none yet)

## Environment Notes
- (none yet)

## Reliable Workflows
- (none yet)
"""


@dataclass
class ProfileStore:
    profile_state_root: Path
    legacy_session_state_root: Path
    profile_id: str
    profile_agents_max_chars: int
    profile_memory_max_chars: int
    default_profile_agents: str = DEFAULT_PROFILE_AGENTS
    default_profile_memory: str = DEFAULT_PROFILE_MEMORY

    def __post_init__(self) -> None:
        self.profile_state_root.mkdir(parents=True, exist_ok=True)
        self._file_lock = threading.Lock()

    def load_context(self, *, session_id_hint: str | None = None) -> tuple[str, str]:
        agents_path, memory_path = self.ensure_files(session_id_hint=session_id_hint)
        agents = self._clip_context(
            agents_path.read_text(encoding="utf-8"),
            self.profile_agents_max_chars,
        )
        memory = self._clip_context(
            memory_path.read_text(encoding="utf-8"),
            self.profile_memory_max_chars,
        )
        return agents, memory

    def stage_files_in_workdir(self, workdir: Path, *, session_id_hint: str | None = None) -> Path:
        agents_path, memory_path = self.ensure_files(session_id_hint=session_id_hint)
        mobaile_dir = (workdir / ".mobaile").resolve()
        mobaile_dir.mkdir(parents=True, exist_ok=True)
        workdir_agents = mobaile_dir / "AGENTS.md"
        workdir_memory = mobaile_dir / "MEMORY.md"
        workdir_agents.write_text(agents_path.read_text(encoding="utf-8"), encoding="utf-8")
        workdir_memory.write_text(memory_path.read_text(encoding="utf-8"), encoding="utf-8")
        return workdir_memory

    def sync_memory_from_workdir(self, workdir_memory_path: Path) -> None:
        candidates = [workdir_memory_path]
        mobaile_dir = workdir_memory_path.parent
        workdir = mobaile_dir.parent
        candidates.extend(
            [
                mobaile_dir / "memory.md",
                workdir / "MEMORY.md",
                workdir / "memory.md",
            ]
        )

        latest_text: str | None = None
        latest_mtime = -1.0
        for candidate in candidates:
            if not candidate.exists() or not candidate.is_file():
                continue
            text = candidate.read_text(encoding="utf-8")
            normalized = text.replace("\r\n", "\n").replace("\r", "\n").strip()
            if not normalized:
                continue
            mtime = candidate.stat().st_mtime
            if mtime >= latest_mtime:
                latest_mtime = mtime
                latest_text = normalized
        if not latest_text:
            return

        bounded = self._clip_context(latest_text, self.profile_memory_max_chars)
        self.ensure_files()
        self.profile_memory_path().write_text(bounded + "\n", encoding="utf-8")

    def ensure_files(self, *, session_id_hint: str | None = None) -> tuple[Path, Path]:
        profile_path = self.profile_dir()
        agents_path = self.profile_agents_path()
        memory_path = self.profile_memory_path()
        with self._file_lock:
            profile_path.mkdir(parents=True, exist_ok=True)
            if not agents_path.exists():
                seeded = self._seed_from_legacy(session_id_hint, "AGENTS.md")
                agents_path.write_text(
                    (seeded or self.default_profile_agents).strip() + "\n",
                    encoding="utf-8",
                )
            if not memory_path.exists():
                seeded = self._seed_from_legacy(session_id_hint, "MEMORY.md")
                memory_path.write_text(
                    (seeded or self.default_profile_memory).strip() + "\n",
                    encoding="utf-8",
                )
        return agents_path, memory_path

    def profile_dir(self) -> Path:
        return self.profile_state_root / self._stable_key(self.profile_id)

    def profile_agents_path(self) -> Path:
        return self.profile_dir() / "AGENTS.md"

    def profile_memory_path(self) -> Path:
        return self.profile_dir() / "MEMORY.md"

    def _legacy_session_dir(self, session_id: str) -> Path:
        return self.legacy_session_state_root / self._stable_key(session_id)

    def _seed_from_legacy(self, session_id_hint: str | None, file_name: str) -> str:
        # Remove after 2026-07-01 once installs have migrated from session-scoped state.
        if not session_id_hint:
            return ""
        legacy_file = self._legacy_session_dir(session_id_hint) / file_name
        if not legacy_file.exists() or not legacy_file.is_file():
            return ""
        return legacy_file.read_text(encoding="utf-8").strip()

    @staticmethod
    def _stable_key(raw_value: str) -> str:
        cleaned = "".join(char if char.isalnum() or char in "._-" else "_" for char in raw_value.strip())[:120]
        return cleaned or "default"

    @staticmethod
    def _clip_context(value: str, max_chars: int) -> str:
        text = value.strip()
        if max_chars <= 0 or len(text) <= max_chars:
            return text
        clipped = text[:max_chars].rstrip()
        return clipped + "\n...[truncated for context budget]"
