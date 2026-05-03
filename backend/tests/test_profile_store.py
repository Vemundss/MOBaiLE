from __future__ import annotations

from pathlib import Path

from app.profile_store import ProfileStore


def test_profile_store_skips_workdir_staging_in_icloud_paths(tmp_path: Path) -> None:
    store = ProfileStore(
        profile_state_root=tmp_path / "profiles",
        legacy_session_state_root=tmp_path / "sessions",
        profile_id="default-user",
        profile_agents_max_chars=3000,
        profile_memory_max_chars=6000,
    )
    workdir = tmp_path / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "repo"

    staged = store.stage_files_in_workdir(workdir, session_id_hint="iphone-app")

    assert staged is None
    assert not (workdir / ".mobaile").exists()


def test_profile_store_can_stage_workdir_files_when_cloud_skip_is_disabled(tmp_path: Path) -> None:
    store = ProfileStore(
        profile_state_root=tmp_path / "profiles",
        legacy_session_state_root=tmp_path / "sessions",
        profile_id="default-user",
        profile_agents_max_chars=3000,
        profile_memory_max_chars=6000,
        skip_cloud_workdir_staging=False,
    )
    workdir = tmp_path / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "repo"

    staged = store.stage_files_in_workdir(workdir, session_id_hint="iphone-app")

    assert staged == workdir.resolve() / ".mobaile" / "MEMORY.md"
    assert (workdir / ".mobaile" / "AGENTS.md").is_file()
    assert (workdir / ".mobaile" / "MEMORY.md").is_file()
