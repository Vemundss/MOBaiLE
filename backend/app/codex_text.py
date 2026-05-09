from __future__ import annotations

import json
import re


def filter_codex_assistant_message(message: str, user_prompt: str, leak_markers: list[str]) -> str | None:
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
        "phone ux feedback guidance:",
        "runtime:",
        "product intent:",
        "output style for phone ux:",
        "backend activity events are the source of truth for progress in the phone ui.",
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
        "backend activity events are the source of truth for progress in the phone ui",
        "if you add a short progress note, keep it aligned with the current stage: planning, executing, blocked, or summarizing",
        "keep that note concise and non-repetitive; let the final response carry the substance",
        "do not dump raw logs or long command output unless the user asks",
        "environment notes:",
        "for created images, include markdown image syntax",
        "do not repeat or summarize this runtime context",
        "planning, executing, blocked, or summarizing",
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

        cleaned = filter_codex_assistant_message(text, self.user_prompt, self.leak_markers)
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
