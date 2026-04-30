from __future__ import annotations

import json
import mimetypes
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

from app.models.schemas import (
    ChatArtifact,
    ChatCommandRun,
    ChatEnvelope,
    ChatFileChange,
    ChatNextAction,
    ChatSection,
    ChatTestRun,
    ChatWarning,
    HumanUnblockRequest,
)

TRUNCATION_SUFFIX = "\n...[truncated]"
_MESSAGE_KINDS = {"progress", "final", "notice"}
_GENERIC_SUMMARIES = {
    "completed",
    "done",
    "run completed successfully",
    "run failed",
}
_PROGRESS_MARKERS = (
    "checking ",
    "querying ",
    "pulling ",
    "reading ",
    "fetching ",
    "reformatting ",
    "processing ",
    "running ",
    "trying ",
    "retrying ",
    "i'll ",
    "i will ",
    "i'm ",
    "working on",
)
_FILE_SECTION_TITLES = {
    "artifacts",
    "changed files",
    "file changes",
    "files",
    "files changed",
    "output",
    "what i did",
}
_VERIFICATION_SECTION_TITLES = {
    "checks",
    "commands",
    "tests",
    "tests run",
    "verification",
}
_NEXT_ACTION_SECTION_TITLES = {"human unblock", "next action", "next actions", "next step", "next steps"}
_WARNING_SECTION_TITLES = {"blocked", "caveat", "caveats", "failure", "failed", "warnings"}
_COMMAND_MARKERS = (
    "bash ",
    "cd ",
    "npm ",
    "pnpm ",
    "python ",
    "python3 ",
    "pytest",
    "ruff ",
    "swift ",
    "uv ",
    "uvx ",
    "xcodebuild",
    "yarn ",
)
_TEST_COMMAND_MARKERS = ("pytest", "xcodebuild", "swift test", "npm test", "pnpm test", "yarn test")
_ABSOLUTE_FILE_REFERENCE_PATTERN = r"(/(?:[^`\n'\"<>)]|\\\)){1,240}?\.[A-Za-z0-9]{1,8})(?=$|[\s),.;:!?])"
_RELATIVE_FILE_REFERENCE_PATTERN = (
    r"(?<![\w/.~-])([A-Za-z0-9_.@~ -]+(?:/[A-Za-z0-9_.@~ -]+)+\.[A-Za-z0-9]{1,8})"
    r"(?=$|[\s),.;:!?])"
)


def parse_chat_envelope_payload(raw_text: str) -> dict[str, object] | None:
    candidate = raw_text.strip()
    if not candidate:
        return None
    if candidate.startswith("```") and candidate.endswith("```"):
        parts = candidate.split("\n")
        if len(parts) >= 3:
            candidate = "\n".join(parts[1:-1]).strip()

    parsed = None
    for _ in range(2):
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            parsed = None
            break
        if isinstance(parsed, str):
            candidate = parsed.strip()
            continue
        break
    if not isinstance(parsed, dict):
        return None
    if parsed.get("type") != "assistant_response":
        return None
    parsed.setdefault("version", "1.0")
    parsed.setdefault("message_id", str(uuid.uuid4()))
    parsed.setdefault("created_at", datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
    parsed.setdefault("summary", "")
    parsed.setdefault("sections", [])
    parsed.setdefault("agenda_items", [])
    parsed.setdefault("artifacts", [])
    parsed.setdefault("file_changes", [])
    parsed.setdefault("commands_run", [])
    parsed.setdefault("tests_run", [])
    parsed.setdefault("warnings", [])
    parsed.setdefault("next_actions", [])
    if "message_kind" in parsed and str(parsed.get("message_kind", "")).strip() not in _MESSAGE_KINDS:
        parsed["message_kind"] = "final"
    return parsed


def merge_assistant_lines(lines: list[str]) -> str:
    merged_parts: list[str] = []
    section_labels = {"what i did", "result", "next step", "output"}
    for line in lines:
        text = line.strip()
        if not text:
            continue
        if not merged_parts:
            merged_parts.append(text)
            continue

        prev = merged_parts[-1]
        if prev.strip().lower().rstrip(":") in section_labels:
            merged_parts.append("\n" + text)
            continue
        if text.lower().rstrip(":") in section_labels:
            merged_parts.append("\n\n## " + text.rstrip(":"))
            continue
        if prev.endswith((":", ";")):
            merged_parts.append("\n" + text)
            continue
        if text.startswith(("-", "*", "##", "###", "```")):
            merged_parts.append("\n" + text)
            continue
        if text.startswith(("1.", "2.", "3.", "4.", "5.")):
            merged_parts.append("\n" + text)
            continue
        if prev.endswith((".", "!", "?", "`")):
            merged_parts.append("\n\n" + text)
            continue
        merged_parts.append("\n" + text)
    return "".join(merged_parts)


def split_sections_from_text(text: str) -> list[ChatSection]:
    cleaned = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not cleaned:
        return []
    if "## " in cleaned:
        sections: list[ChatSection] = []
        for block in re.split(r"(?m)^##\s+", cleaned):
            chunk = block.strip()
            if not chunk:
                continue
            lines = chunk.splitlines()
            title = lines[0].strip().rstrip(":")
            body = "\n".join(lines[1:]).strip() if len(lines) > 1 else ""
            if not body:
                continue
            sections.append(ChatSection(title=title[:64], body=body))
        if sections:
            return sections
    paragraphs = [p.strip() for p in re.split(r"\n{2,}", cleaned) if p.strip()]
    if len(paragraphs) <= 1:
        return [ChatSection(title="Result", body=cleaned)]
    sections = [ChatSection(title="What I Did", body=paragraphs[0])]
    sections.append(ChatSection(title="Result", body="\n\n".join(paragraphs[1:])))
    return sections


def extract_artifacts_from_text(text: str) -> list[ChatArtifact]:
    artifacts: list[ChatArtifact] = []
    seen: set[str] = set()

    def append_reference(raw_reference: str, *, title: str | None = None, force_image: bool = False) -> None:
        path = _clean_artifact_reference(raw_reference)
        if not path or path in seen:
            return
        seen.add(path)
        mime, _ = mimetypes.guess_type(path)
        artifact_type = "image" if force_image or (mime or "").startswith("image/") else "file"
        artifacts.append(
            ChatArtifact(
                type=artifact_type,
                title=(title or Path(path).name or path).strip(),
                path=path,
                mime=mime or ("image/png" if artifact_type == "image" else None),
            )
        )

    image_pattern = r"!\[[^\]]*\]\(([^)]+)\)"
    for match in re.finditer(image_pattern, text):
        append_reference(match.group(1), force_image=True)

    link_pattern = r"(?<!!)\[([^\]]+)\]\(([^)]+)\)"
    for match in re.finditer(link_pattern, text):
        title = match.group(1).strip() or None
        append_reference(match.group(2), title=title)

    for match in re.finditer(_ABSOLUTE_FILE_REFERENCE_PATTERN, text):
        append_reference(match.group(1))
    return artifacts


def chat_envelope_transport_json(envelope: ChatEnvelope, max_chars: int) -> str:
    """Serialize an envelope without letting generic event truncation corrupt JSON."""
    rendered = envelope.model_dump_json()
    if max_chars <= 0 or len(rendered) <= max_chars:
        return rendered

    fitted = fit_chat_envelope_for_transport(envelope, max_chars=max_chars)
    rendered = fitted.model_dump_json()
    if len(rendered) <= max_chars:
        return rendered

    minimal = ChatEnvelope(
        message_id=envelope.message_id,
        created_at=envelope.created_at,
        summary="Response was too long to send completely.",
        sections=[
            ChatSection(
                title="Result",
                body=(
                    "The assistant response exceeded the phone transport limit. "
                    "Open Run Logs on the phone for the raw output."
                ),
            )
        ],
        warnings=[
            ChatWarning(
                message="The full assistant response exceeded the phone transport limit.",
                level="warning",
            )
        ],
        next_actions=[
            ChatNextAction(
                title="Open Run Logs",
                detail="The raw output is still available in the diagnostic event stream.",
                kind="open_logs",
            )
        ],
    )
    return minimal.model_dump_json()


def fit_chat_envelope_for_transport(envelope: ChatEnvelope, *, max_chars: int) -> ChatEnvelope:
    if max_chars <= 0:
        return envelope
    if len(envelope.model_dump_json()) <= max_chars:
        return envelope

    section_counts = [8, 5, 3, 1, 0]
    body_budgets = [
        max(240, max_chars // 2),
        max(220, max_chars // 3),
        1200,
        700,
        360,
        180,
    ]
    item_counts = [24, 12, 6, 3, 0]
    agenda_counts = [50, 20, 8, 0]

    for max_sections in section_counts:
        for max_items in item_counts:
            for max_agenda in agenda_counts:
                for body_budget in body_budgets:
                    candidate = _compact_envelope(
                        envelope,
                        max_sections=max_sections,
                        max_items=max_items,
                        max_agenda=max_agenda,
                        max_body_chars=body_budget,
                    )
                    if len(candidate.model_dump_json()) <= max_chars:
                        return candidate

    return _compact_envelope(
        envelope,
        max_sections=0,
        max_items=0,
        max_agenda=0,
        max_body_chars=120,
    )


def concise_chat_summary(envelope: ChatEnvelope) -> str | None:
    if envelope.message_kind == "progress":
        return None

    candidates: list[str] = []
    result_sections = [
        section.body
        for section in envelope.sections
        if section.title.strip().lower() in {"result", "output", "next step"}
    ]
    candidates.append(envelope.summary)
    candidates.extend(result_sections)
    candidates.extend(section.body for section in envelope.sections)

    for candidate in candidates:
        summary = _clean_summary(candidate)
        if summary is not None:
            return summary
    return None


def enhance_chat_envelope(envelope: ChatEnvelope, *, infer_message_kind: bool = False) -> ChatEnvelope:
    text = _envelope_text(envelope)
    artifacts = envelope.artifacts or extract_artifacts_from_text(text)
    file_changes = envelope.file_changes or extract_file_changes_from_text(text, artifacts)
    commands_run = envelope.commands_run or extract_command_runs_from_text(text)
    tests_run = envelope.tests_run or extract_test_runs_from_text(text, commands_run)
    warnings = envelope.warnings or extract_warnings_from_text(envelope.sections, text)
    next_actions = envelope.next_actions or extract_next_actions_from_text(envelope.sections)

    message_kind = envelope.message_kind
    if infer_message_kind:
        probe = envelope.model_copy(
            update={
                "artifacts": artifacts,
                "file_changes": file_changes,
                "commands_run": commands_run,
                "tests_run": tests_run,
                "warnings": warnings,
                "next_actions": next_actions,
            }
        )
        message_kind = infer_chat_message_kind(probe)

    return envelope.model_copy(
        update={
            "message_kind": message_kind,
            "artifacts": artifacts,
            "file_changes": file_changes,
            "commands_run": commands_run,
            "tests_run": tests_run,
            "warnings": warnings,
            "next_actions": next_actions,
        }
    )


def infer_chat_message_kind(envelope: ChatEnvelope) -> str:
    if envelope.message_kind == "notice":
        return "notice"
    if envelope.agenda_items or envelope.artifacts or envelope.file_changes:
        return "final"
    if envelope.commands_run or envelope.tests_run or envelope.warnings or envelope.next_actions:
        return "final"
    if len(envelope.sections) > 1:
        return "final"
    if envelope.sections:
        section = envelope.sections[0]
        title = section.title.strip().lower()
        if title not in {"result", "status", "summary"}:
            return "final"
        return "progress" if _looks_like_progress_text(section.body) else "final"
    return "progress" if _looks_like_progress_text(envelope.summary) else "final"


def extract_file_changes_from_text(text: str, artifacts: list[ChatArtifact]) -> list[ChatFileChange]:
    changes: list[ChatFileChange] = []
    seen: set[str] = set()
    artifacts_by_reference = _artifacts_by_reference(artifacts)
    current_heading = ""

    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        heading = _markdown_heading(stripped)
        if heading is not None:
            current_heading = heading
            continue
        if not stripped:
            continue
        status = _file_status_from_text(stripped)
        in_file_section = current_heading in _FILE_SECTION_TITLES
        if status == "unknown" and not in_file_section:
            continue
        for path in _extract_file_references_from_line(stripped):
            if path in seen:
                continue
            seen.add(path)
            artifact = artifacts_by_reference.get(path)
            changes.append(
                ChatFileChange(
                    path=path,
                    status=status,
                    summary=_truncate_text(_clean_list_item(stripped), 180),
                    artifact=artifact,
                )
            )

    for artifact in artifacts:
        reference = artifact.path or artifact.url
        if not reference or reference in seen:
            continue
        seen.add(reference)
        changes.append(
            ChatFileChange(
                path=reference,
                status="generated" if artifact.type == "image" else "unknown",
                summary=artifact.title,
                artifact=artifact,
            )
        )

    return changes[:30]


def extract_command_runs_from_text(text: str) -> list[ChatCommandRun]:
    commands: list[ChatCommandRun] = []
    seen: set[str] = set()
    current_heading = ""

    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        heading = _markdown_heading(stripped)
        if heading is not None:
            current_heading = heading
            continue
        command = _command_from_line(stripped, in_verification_section=current_heading in _VERIFICATION_SECTION_TITLES)
        if command is None or command in seen:
            continue
        seen.add(command)
        commands.append(
            ChatCommandRun(
                command=command,
                status=_run_status_from_text(stripped),
                summary=_truncate_text(_clean_list_item(stripped), 180),
            )
        )
    return commands[:12]


def extract_test_runs_from_text(text: str, commands_run: list[ChatCommandRun]) -> list[ChatTestRun]:
    tests: list[ChatTestRun] = []
    seen: set[str] = set()

    for command in commands_run:
        if _looks_like_test_command(command.command):
            seen.add(command.command)
            tests.append(
                ChatTestRun(
                    name=command.command,
                    status=command.status,
                    summary=command.summary,
                )
            )

    current_heading = ""
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        heading = _markdown_heading(stripped)
        if heading is not None:
            current_heading = heading
            continue
        if current_heading not in _VERIFICATION_SECTION_TITLES:
            continue
        status = _run_status_from_text(stripped)
        if status == "unknown":
            continue
        name = _clean_list_item(stripped)
        if not name or name in seen or _command_from_line(stripped, in_verification_section=True):
            continue
        seen.add(name)
        tests.append(ChatTestRun(name=_truncate_text(name, 120), status=status, summary=_truncate_text(name, 180)))

    return tests[:12]


def extract_warnings_from_text(sections: list[ChatSection], text: str) -> list[ChatWarning]:
    warnings: list[ChatWarning] = []
    seen: set[str] = set()

    def append_warning(message: str, level: str = "warning") -> None:
        cleaned = _truncate_text(_clean_list_item(message), 240)
        if not cleaned or cleaned.lower() in seen:
            return
        seen.add(cleaned.lower())
        warnings.append(ChatWarning(message=cleaned, level=level if level in {"info", "warning", "error"} else "warning"))

    for section in sections:
        title = section.title.strip().lower()
        if title not in _WARNING_SECTION_TITLES and title != "human unblock":
            continue
        level = "error" if title in {"blocked", "failure", "failed", "human unblock"} else "warning"
        for line in _content_lines(section.body):
            append_warning(line, level=level)

    for line in text.splitlines():
        lower = line.lower()
        if "0 failures" in lower or "no failures" in lower:
            continue
        if any(marker in lower for marker in ("could not", "failed", "timed out", "unable to", "not run", "skipped")):
            level = "error" if any(marker in lower for marker in ("failed", "timed out", "unable to")) else "warning"
            append_warning(line, level=level)

    return warnings[:8]


def extract_next_actions_from_text(sections: list[ChatSection]) -> list[ChatNextAction]:
    actions: list[ChatNextAction] = []
    seen: set[str] = set()

    for section in sections:
        title = section.title.strip().lower()
        if title not in _NEXT_ACTION_SECTION_TITLES:
            continue
        for line in _content_lines(section.body):
            cleaned = _truncate_text(_clean_list_item(line), 220)
            if not cleaned or cleaned.lower() in seen:
                continue
            seen.add(cleaned.lower())
            actions.append(
                ChatNextAction(
                    title=_truncate_text(_first_sentence(cleaned), 96),
                    detail=cleaned if len(cleaned) > 96 else None,
                    kind=_next_action_kind(cleaned),
                )
            )
    return actions[:6]


def coerce_assistant_text_to_envelope(raw_text: str) -> ChatEnvelope:
    text = raw_text.strip()
    message_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    if not text:
        return ChatEnvelope(
            message_id=message_id,
            created_at=created_at,
            summary="",
            sections=[],
            agenda_items=[],
            artifacts=[],
        )
    sections = split_sections_from_text(text)
    artifacts = extract_artifacts_from_text(text)
    summary = sections[0].body if sections else text.split("\n", 1)[0]
    summary = summary.strip()
    if not summary:
        summary = "Completed"
    envelope = ChatEnvelope(
        message_id=message_id,
        created_at=created_at,
        summary=summary[:280],
        sections=sections,
        artifacts=artifacts,
    )
    return enhance_chat_envelope(envelope, infer_message_kind=True)


def find_human_unblock_section(envelope: ChatEnvelope) -> ChatSection | None:
    for section in envelope.sections:
        if section.title.strip().lower() == "human unblock":
            return section
    return None


def human_unblock_request_from_envelope(envelope: ChatEnvelope) -> HumanUnblockRequest | None:
    section = find_human_unblock_section(envelope)
    if section is None:
        return None
    instructions = section.body.strip()
    if not instructions:
        return None
    return HumanUnblockRequest(instructions=instructions)


def _compact_envelope(
    envelope: ChatEnvelope,
    *,
    max_sections: int,
    max_items: int,
    max_agenda: int,
    max_body_chars: int,
) -> ChatEnvelope:
    sections = [
        ChatSection(
            title=_truncate_text(section.title.strip() or "Result", 64),
            body=_truncate_text(section.body.strip(), max_body_chars),
        )
        for section in envelope.sections[:max_sections]
        if section.body.strip()
    ]
    return ChatEnvelope(
        message_id=envelope.message_id,
        created_at=envelope.created_at,
        message_kind=envelope.message_kind,
        summary=_truncate_text(envelope.summary.strip(), min(280, max(80, max_body_chars // 2))),
        sections=sections,
        agenda_items=envelope.agenda_items[:max_agenda],
        artifacts=envelope.artifacts[:max_items],
        file_changes=[
            ChatFileChange(
                path=_truncate_text(change.path, 220),
                status=change.status,
                summary=_truncate_text(change.summary or "", 140) or None,
                artifact=change.artifact,
            )
            for change in envelope.file_changes[:max_items]
        ],
        commands_run=[
            ChatCommandRun(
                command=_truncate_text(command.command, 180),
                status=command.status,
                exit_code=command.exit_code,
                summary=_truncate_text(command.summary or "", 140) or None,
            )
            for command in envelope.commands_run[:max_items]
        ],
        tests_run=[
            ChatTestRun(
                name=_truncate_text(test.name, 180),
                status=test.status,
                summary=_truncate_text(test.summary or "", 140) or None,
            )
            for test in envelope.tests_run[:max_items]
        ],
        warnings=[
            ChatWarning(message=_truncate_text(warning.message, 180), level=warning.level)
            for warning in envelope.warnings[:max_items]
        ],
        next_actions=[
            ChatNextAction(
                title=_truncate_text(action.title, 96),
                detail=_truncate_text(action.detail or "", 140) or None,
                kind=action.kind,
            )
            for action in envelope.next_actions[:max_items]
        ],
    )


def _truncate_text(value: str, max_chars: int) -> str:
    if len(value) <= max_chars:
        return value
    if max_chars <= len(TRUNCATION_SUFFIX):
        return TRUNCATION_SUFFIX[-max_chars:]
    return value[: max_chars - len(TRUNCATION_SUFFIX)].rstrip() + TRUNCATION_SUFFIX


def _clean_summary(raw_text: str) -> str | None:
    first_paragraph = raw_text.strip().split("\n\n", 1)[0]
    single_line = " ".join(first_paragraph.split())
    if not single_line:
        return None
    lower = single_line.lower()
    if lower in _GENERIC_SUMMARIES:
        return None
    if "run completed successfully" in lower or "run failed" in lower:
        return None
    if _looks_like_progress_text(single_line):
        return None
    return _truncate_text(single_line, 280)


def _clean_artifact_reference(raw_reference: str) -> str:
    path = raw_reference.strip().strip("'\"")
    if path.startswith("<") and path.endswith(">"):
        path = path[1:-1].strip()
    path = path.replace("file://", "")
    path = path.rstrip(".,;:")
    if path.startswith(("http://", "https://")):
        return path
    if not path.startswith("/") and not path.startswith("~") and "/" not in path:
        return path if _looks_like_file_reference(path) else ""
    if "/path/to/" in path.lower() or "absolute/path" in path.lower():
        return ""
    return path


def _looks_like_progress_text(text: str) -> bool:
    lower = text.strip().lower()
    if not lower:
        return False
    if any(marker in lower for marker in ("run completed successfully", "run failed", "```")):
        return False
    return any(marker in lower for marker in _PROGRESS_MARKERS)


def _envelope_text(envelope: ChatEnvelope) -> str:
    parts = [envelope.summary]
    for section in envelope.sections:
        parts.append(f"## {section.title}\n{section.body}")
    return "\n\n".join(part for part in parts if part.strip())


def _markdown_heading(line: str) -> str | None:
    match = re.match(r"^#{1,6}\s+(.+?)\s*:?\s*$", line)
    if match is None:
        return None
    return match.group(1).strip().lower()


def _extract_file_references_from_line(line: str) -> list[str]:
    references: list[str] = []

    def append(raw: str) -> None:
        value = _clean_artifact_reference(raw)
        if value and _looks_like_file_reference(value) and value not in references:
            references.append(value)

    for match in re.finditer(r"!\[[^\]]*\]\(([^)]+)\)", line):
        append(match.group(1))
    for match in re.finditer(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", line):
        append(match.group(1))
    for match in re.finditer(r"`([^`\n]+)`", line):
        append(match.group(1))
    for match in re.finditer(_ABSOLUTE_FILE_REFERENCE_PATTERN, line):
        append(match.group(1))
    for match in re.finditer(_RELATIVE_FILE_REFERENCE_PATTERN, line):
        append(match.group(1))
    return references


def _looks_like_file_reference(value: str) -> bool:
    if value.startswith(("http://", "https://")):
        return True
    if any(value.startswith(prefix) for prefix in ("/", "~", "./", "../")):
        return bool(Path(value).suffix)
    return "/" in value and bool(Path(value).suffix)


def _file_status_from_text(text: str) -> str:
    lower = text.lower()
    if any(marker in lower for marker in ("deleted", "removed")):
        return "deleted"
    if any(marker in lower for marker in ("renamed", "moved")):
        return "renamed"
    if any(marker in lower for marker in ("created", "added", "generated", "saved", "wrote")):
        return "generated" if any(marker in lower for marker in ("generated", "saved")) else "created"
    if any(marker in lower for marker in ("changed", "edited", "modified", "patched", "refined", "updated")):
        return "modified"
    return "unknown"


def _run_status_from_text(text: str) -> str:
    lower = text.lower()
    if any(marker in lower for marker in ("not run", "skipped", "could not run")):
        return "skipped"
    if any(marker in lower for marker in ("failed", "failing", "error", "interrupted")):
        return "failed"
    if any(marker in lower for marker in ("passed", "pass", "succeeded", "success", "clean", "ok")):
        return "passed"
    return "unknown"


def _command_from_line(line: str, *, in_verification_section: bool) -> str | None:
    cleaned = _clean_list_item(line)
    if cleaned.startswith("$ "):
        return cleaned[2:].strip() or None
    for match in re.finditer(r"`([^`\n]+)`", cleaned):
        candidate = match.group(1).strip()
        if _looks_like_command(candidate):
            return candidate
    if in_verification_section and _looks_like_command(cleaned):
        return cleaned
    return None


def _looks_like_command(value: str) -> bool:
    stripped = value.strip()
    if not stripped or "\n" in stripped:
        return False
    lower = stripped.lower()
    return any(lower.startswith(marker) for marker in _COMMAND_MARKERS)


def _looks_like_test_command(value: str) -> bool:
    lower = value.lower()
    return any(marker in lower for marker in _TEST_COMMAND_MARKERS)


def _content_lines(text: str) -> list[str]:
    lines = [_clean_list_item(line) for line in text.splitlines()]
    return [line for line in lines if line]


def _clean_list_item(text: str) -> str:
    cleaned = text.strip()
    cleaned = re.sub(r"^\s*[-*]\s+", "", cleaned)
    cleaned = re.sub(r"^\s*\d+\.\s+", "", cleaned)
    return cleaned.strip()


def _first_sentence(text: str) -> str:
    match = re.search(r"(?<=[.!?])\s+", text)
    if match is None:
        return text.strip()
    return text[: match.start()].strip()


def _next_action_kind(text: str) -> str:
    lower = text.lower()
    if "log" in lower:
        return "open_logs"
    if "retry" in lower or "try again" in lower:
        return "retry"
    if "continue" in lower or "resume" in lower:
        return "continue"
    if "open" in lower or "artifact" in lower or "file" in lower:
        return "inspect_artifact"
    return "custom"


def _artifacts_by_reference(artifacts: list[ChatArtifact]) -> dict[str, ChatArtifact]:
    refs: dict[str, ChatArtifact] = {}
    for artifact in artifacts:
        for reference in (artifact.path, artifact.url, artifact.title):
            if reference:
                refs[reference] = artifact
    return refs
