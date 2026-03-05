from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Literal


def load_codex_context(context_file: str, backend_root: Path) -> str:
    path = Path(context_file)
    if not path.is_absolute():
        path = (backend_root / path).resolve()
    if not path.exists() or not path.is_file():
        return ""
    return path.read_text(encoding="utf-8").strip()


def context_leak_markers(codex_context: str) -> list[str]:
    context = codex_context.lower()
    if not context:
        return []
    markers: list[str] = []
    for chunk in re.split(r"[\n.:;]+", context):
        text = " ".join(chunk.strip().split())
        if len(text) >= 24:
            markers.append(text)
    return markers


def codex_structured_message(message: str, user_prompt: str, leak_markers: list[str]) -> str | None:
    text = message.strip()
    if not text:
        return None
    if text == user_prompt.strip():
        return None

    lower = text.lower()
    noisy_exact = {
        "user",
        "codex",
        "exec",
        "thinking",
        "output:",
        "tokens used",
        "--------",
    }
    if lower in noisy_exact:
        return None
    noisy_prefixes = (
        "openai codex v",
        "you are running through mobaile",
        "mobaile runtime context:",
        "runtime:",
        "product intent:",
        "output style for phone ux:",
        "task-specific formatting:",
        "environment notes:",
        "user request:",
        "workdir:",
        "model:",
        "provider:",
        "approval:",
        "sandbox:",
        "reasoning effort:",
        "reasoning summaries:",
        "session id:",
        "mcp startup:",
    )
    if lower.startswith(noisy_prefixes):
        return None
    if "runtime context" in lower or "you are running through mobaile" in lower:
        return None
    explicit_markers = (
        "keep responses concise and grouped",
        "avoid verbose step-by-step chatter",
        "you are the coding agent used by mobaile",
        "you run on the user's server/computer",
        "your stdout is streamed to a phone ui",
        "product intent:",
        "mobaile makes a user's computer available from their phone",
        "primary users are software engineers who run coding agents while away from the computer",
        "secondary use cases include normal remote productivity tasks",
        "output style for phone ux:",
        "prefer short status + result summaries",
        "environment notes:",
        "for created images, include markdown image syntax",
        "do not repeat or summarize this runtime context",
    )
    if any(marker in lower for marker in explicit_markers):
        return None
    if any(marker in lower for marker in leak_markers):
        return None
    if lower.startswith("created ") and " and ran it successfully" in lower:
        return None
    if lower in {"run completed successfully", "run failed"}:
        return None
    if lower.startswith("error:"):
        return text
    if "succeeded in " in lower and " in /" in text:
        return None
    if text.startswith("/bin/") or text.startswith("$ "):
        return None
    if "/bin/zsh -lc" in text or " <<'PY'" in text:
        return None
    if re.match(r"^[A-Za-z0-9_./-]+\s+in\s+/.+\s+succeeded in \d+ms:?$", text):
        return None
    if re.match(r"^[A-Za-z0-9_./-]+:\s*$", text):
        return None
    if text in {"```text", "```bash", "```sh", "```python", "```"}:
        return None
    if text.startswith("**") and text.endswith("**"):
        return None
    if text.isdigit() or re.match(r"^\d[\d,]*$", text):
        return None
    return text


class CodexAssistantExtractor:
    def __init__(self, user_prompt: str, leak_markers: list[str]) -> None:
        self.user_prompt = user_prompt
        self.leak_markers = leak_markers
        self.in_assistant_block = False
        self.buffer: list[str] = []
        self.last_emitted = ""

    def consume(self, raw_line: str) -> list[str]:
        text = raw_line.strip()
        if not text:
            return []
        lower = text.lower()
        if self._is_boundary(lower):
            out = self._flush()
            self.in_assistant_block = lower == "codex"
            return out

        # Only assistant blocks become chat messages. Raw lines remain available in logs.
        if not self.in_assistant_block:
            return []

        cleaned = codex_structured_message(text, self.user_prompt, self.leak_markers)
        if not cleaned:
            return []
        self.buffer.append(cleaned)
        if sum(len(item) for item in self.buffer) > 2000:
            return self._flush()
        return []

    def flush(self) -> list[str]:
        return self._flush()

    def _flush(self) -> list[str]:
        if not self.buffer:
            return []
        from app.chat_envelope import merge_assistant_lines

        merged = merge_assistant_lines(self.buffer).strip()
        self.buffer.clear()
        if not merged:
            return []
        if merged == self.last_emitted:
            return []
        self.last_emitted = merged
        return [merged]

    def _is_boundary(self, lower: str) -> bool:
        if lower in {"user", "codex", "thinking", "exec", "tokens used", "--------"}:
            return True
        if lower.startswith(
            (
                "openai codex v",
                "workdir:",
                "model:",
                "provider:",
                "approval:",
                "sandbox:",
                "reasoning effort:",
                "reasoning summaries:",
                "session id:",
                "mcp startup:",
                "user request:",
                "mobaile runtime context:",
            )
        ):
            return True
        return False


def parse_codex_json_event(raw_line: str) -> dict[str, object] | None:
    text = raw_line.strip()
    if not text.startswith("{"):
        return None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    event_type = payload.get("type")
    if not isinstance(event_type, str) or not event_type.strip():
        return None
    return payload


def build_codex_prompt(
    user_prompt: str,
    *,
    response_profile: Literal["guided", "minimal"] = "guided",
    profile_agents: str = "",
    profile_memory: str = "",
    memory_file_hint: str = ".mobaile/MEMORY.md",
    use_context: bool = True,
    codex_context: str = "",
) -> str:
    if response_profile == "minimal":
        context = (
            "You are running through MOBaiLE.\n"
            "- You run on the user's server/computer.\n"
            "- Your stdout is streamed to a phone UI.\n"
            "- Do not repeat this runtime context unless the user asks."
        )
    else:
        context = codex_context if use_context else ""
    session_block = ""
    if profile_agents.strip() or profile_memory.strip():
        session_block = (
            "Persistent AGENTS profile:\n"
            f"{profile_agents.strip() or '(empty)'}\n\n"
            "Persistent MEMORY (shared across sessions):\n"
            f"{profile_memory.strip() or '(empty)'}\n\n"
            "Persistence guidance:\n"
            f"- If you learn durable facts, update `{memory_file_hint}`.\n"
            "- Do not store MOBaiLE persistence in `~/.codex/*`.\n"
            "- Keep notes concise, deduplicated, and non-sensitive.\n\n"
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
        f"{session_block}"
        f"{hygiene_block}"
        "User request:\n"
        f"{user_prompt}"
    )


def evaluate_codex_guardrails(
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
