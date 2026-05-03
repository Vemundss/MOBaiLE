from __future__ import annotations

import re
from pathlib import Path
from typing import Literal

ResponseProfile = Literal["guided", "minimal"]


def load_runtime_context(context_file: str, backend_root: Path) -> str:
    raw_path = Path(context_file)
    candidates: list[Path] = []
    if raw_path.is_absolute():
        candidates.append(raw_path)
    else:
        candidates.append((backend_root / raw_path).resolve())
        runtime_root = (backend_root.parent / ".mobaile" / "runtime").resolve()
        if raw_path.name == "RUNTIME_CONTEXT.md":
            candidates.append((runtime_root / "RUNTIME_CONTEXT.md").resolve())
        # Compatibility fallbacks for older installs that still point at AGENT_CONTEXT.md.
        if raw_path.name == "AGENT_CONTEXT.md":
            candidates.append((backend_root.parent / ".mobaile" / "AGENT_CONTEXT.md").resolve())
            candidates.append((runtime_root / "RUNTIME_CONTEXT.md").resolve())
    for path in candidates:
        if path.exists() and path.is_file():
            return path.read_text(encoding="utf-8").strip()
    return ""


def context_leak_markers(runtime_context: str) -> list[str]:
    context = runtime_context.lower()
    if not context:
        return []
    markers: list[str] = []
    for chunk in re.split(r"[\n.:;]+", context):
        text = " ".join(chunk.strip().split())
        if len(text) >= 24:
            markers.append(text)
    return markers


def build_agent_prompt(
    user_prompt: str,
    *,
    response_profile: ResponseProfile = "guided",
    profile_agents: str = "",
    profile_memory: str = "",
    include_profile_agents: bool = True,
    include_profile_memory: bool = True,
    memory_file_hint: str = ".mobaile/MEMORY.md",
    use_context: bool = True,
    runtime_context: str = "",
    global_agent_home: str = "~/.codex/*",
) -> str:
    if response_profile == "minimal":
        context = (
            "You are running through MOBaiLE.\n"
            "- You run on the user's server/computer.\n"
            "- Your stdout is streamed to a phone UI.\n"
            "- Do not repeat this runtime context unless the user asks."
        )
        phone_feedback_block = ""
    else:
        context = runtime_context if use_context else ""
        phone_feedback_block = (
            "Phone UX feedback guidance:\n"
            "- Backend activity events are the source of truth for progress in the phone UI.\n"
            "- If you add a short progress note, keep it aligned with the current stage: planning, executing, blocked, or summarizing.\n"
            "- Keep that note concise and non-repetitive; let the final response carry the substance.\n"
            "- Do not dump raw logs or long command output unless the user asks.\n\n"
        )
    session_sections: list[str] = []
    if include_profile_agents and profile_agents.strip():
        session_sections.append(
            "Persistent AGENTS profile:\n"
            f"{profile_agents.strip() or '(empty)'}"
        )
    if include_profile_memory and profile_memory.strip():
        session_sections.append(
            "Persistent MEMORY (shared across sessions):\n"
            f"{profile_memory.strip() or '(empty)'}"
        )

    session_block = ""
    if session_sections:
        session_block = "\n\n".join(session_sections) + "\n\n"
        if include_profile_memory:
            memory_hint = memory_file_hint.strip()
            session_block += "Persistence guidance:\n"
            if memory_hint:
                session_block += f"- If you learn durable facts, update `{memory_hint}`.\n"
            else:
                session_block += (
                    "- This workspace has no staged MEMORY file for this run; treat the memory above as read-only.\n"
                )
            session_block += (
                f"- Do not store MOBaiLE persistence in `{global_agent_home}`.\n"
                "- Keep notes concise, deduplicated, and non-sensitive.\n\n"
            )
    autonomy_block = (
        "Remote-control guidance:\n"
        "- Prefer the least-fragile control surface: local CLI/API first, browser automation second, desktop UI automation third.\n"
        "- Reuse persistent browser or app sessions when available to avoid repeated logins and anti-bot friction.\n"
        "- If blocked by CAPTCHAs, 2FA, OS permissions, or secrets you do not have, preserve state and ask for the exact unblock step instead of retrying blindly.\n"
        "- When a human unblock is required, include a `## Human Unblock` section with the precise action and what the user should send back after completing it.\n\n"
    )
    hygiene_block = (
        "Execution hygiene:\n"
        "- Keep generated files/images inside the current working directory.\n"
        "- Prefer project-local environments (for example `.mobaile/.venv`) for extra packages.\n"
        "- Ask before installing packages user-wide or system-wide.\n\n"
    )
    if not context and not session_block and not hygiene_block:
        return user_prompt
    runtime_block = ""
    if context:
        runtime_block = (
            "MOBaiLE runtime context:\n"
            f"{context}\n\n"
        )
    return (
        "You are running through MOBaiLE.\n\n"
        f"{runtime_block}"
        f"{phone_feedback_block}"
        f"{session_block}"
        f"{autonomy_block}"
        f"{hygiene_block}"
        "User request:\n"
        f"{user_prompt}"
    )


def evaluate_agent_guardrails(
    user_prompt: str,
    *,
    guardrails_mode: str,
    dangerous_confirm_token: str,
) -> tuple[str, str]:
    mode = guardrails_mode if guardrails_mode in {"off", "warn", "enforce"} else "warn"
    if mode == "off":
        return ("off", "")
    lowered = user_prompt.lower()
    dangerous_patterns = (
        r"\brm\s+-rf\b",
        r"\bmkfs\b",
        r"\bdd\s+if=",
        r"\bshutdown\b",
        r"\breboot\b",
        r"\bcurl\b.+\|\s*(sh|bash|zsh)\b",
        r"\bchmod\s+777\b",
        r"\bchown\s+-r\b",
        r"\bdrop\s+database\b",
    )
    is_dangerous = any(re.search(pattern, lowered) for pattern in dangerous_patterns)
    if not is_dangerous:
        return ("ok", "")
    if dangerous_confirm_token and dangerous_confirm_token.lower() in lowered:
        return ("ok", "")
    message = (
        "Potentially destructive request detected. "
        f"Add {dangerous_confirm_token} to confirm intentionally."
    )
    if mode == "enforce":
        return ("reject", message)
    return ("warn", message)


def is_calendar_request(user_prompt: str) -> bool:
    lowered = user_prompt.lower()
    calendar_terms = ("calendar", "agenda", "events")
    time_terms = ("today", "tomorrow", "this week", "next week")
    return any(term in lowered for term in calendar_terms) and any(
        term in lowered for term in time_terms
    )
