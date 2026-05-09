from __future__ import annotations

import os
import time
from pathlib import Path

from .api_test_support import reload_module


def test_runtime_agent_prompt_injects_context(monkeypatch, tmp_path: Path):
    context_file = tmp_path / "ctx.md"
    context_file.write_text("You are in test context.", encoding="utf-8")
    monkeypatch.setenv("VOICE_AGENT_USE_RUNTIME_CONTEXT", "true")
    monkeypatch.setenv("VOICE_AGENT_RUNTIME_CONTEXT_FILE", str(context_file))
    module = reload_module("app.main")
    built = module.ENV.build_runtime_agent_prompt("create hello script", executor="codex")
    assert "MOBaiLE runtime context" in built
    assert "You are in test context." in built
    assert "create hello script" in built


def test_profile_memory_seed_and_prompt_block(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_PROFILE_STATE_ROOT", str(tmp_path / "profiles"))
    module = reload_module("app.main")
    agents, memory = module.PROFILE_STORE.load_context()
    assert "MOBaiLE AGENTS" in agents
    assert "MOBaiLE MEMORY" in memory

    built = module.ENV.build_runtime_agent_prompt(
        "check calendar today",
        executor="codex",
        profile_agents=agents,
        profile_memory=memory,
    )
    assert "Persistent AGENTS profile" in built
    assert "Persistent MEMORY" in built
    assert "~/.codex" in built
    assert "Prefer the least-fragile control surface" in built
    assert "Ask before installing packages user-wide or system-wide." in built
    assert "check calendar today" in built


def test_runtime_agent_prompt_can_skip_profile_agents_and_memory(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_PROFILE_STATE_ROOT", str(tmp_path / "profiles"))
    module = reload_module("app.main")
    agents, memory = module.PROFILE_STORE.load_context()

    built = module.ENV.build_runtime_agent_prompt(
        "check git status",
        executor="codex",
        profile_agents=agents,
        profile_memory=memory,
        include_profile_agents=False,
        include_profile_memory=False,
    )

    assert "Persistent AGENTS profile" not in built
    assert "Persistent MEMORY" not in built
    assert "Persistence guidance" not in built
    assert "MOBaiLE runtime context" in built
    assert "check git status" in built


def test_profile_memory_sync_accepts_memory_file_fallback(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_PROFILE_STATE_ROOT", str(tmp_path / "profiles"))
    monkeypatch.setenv("VOICE_AGENT_PROFILE_ID", "user-fallback")
    module = reload_module("app.main")

    workdir = tmp_path / "workspace"
    mobaile_dir = workdir / ".mobaile"
    mobaile_dir.mkdir(parents=True, exist_ok=True)
    primary = mobaile_dir / "MEMORY.md"
    fallback = workdir / "memory.md"

    primary.write_text("# stale\nold memory\n", encoding="utf-8")
    fallback.write_text("# fresh\nnew durable note\n", encoding="utf-8")
    now = time.time()
    os.utime(fallback, (now + 5, now + 5))

    module.PROFILE_STORE.sync_memory_from_workdir(primary)

    profile_memory = tmp_path / "profiles" / "user-fallback" / "MEMORY.md"
    assert profile_memory.exists()
    text = profile_memory.read_text(encoding="utf-8")
    assert "new durable note" in text
    assert "old memory" not in text
