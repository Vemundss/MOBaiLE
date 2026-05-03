from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from pydantic import ValidationError

from app.models.schemas import ChatArtifact, ChatResultManifest, ChatWarning

_MESSAGE_KINDS = {"progress", "final", "notice"}
_RESULT_MANIFEST_FENCE_PATTERN = re.compile(
    r"```(?P<label>[A-Za-z0-9_.-]+)?[ \t]*\n(?P<body>.*?)(?:\n```|```)",
    re.DOTALL,
)
_MANIFEST_FENCE_LABELS = {"mobaile_result", "mobaile-result", "mobaile.result", "mobaile"}
_MANIFEST_WRAPPER_KEYS = {"mobaile_result", "result_manifest", "chat_result"}


@dataclass(frozen=True)
class ExtractedResultManifest:
    text: str
    manifest: ChatResultManifest | None
    warnings: list[ChatWarning]


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


def extract_result_manifest(raw_text: str) -> ExtractedResultManifest:
    """Extract a machine-readable result manifest from mixed assistant text."""
    if "```" not in raw_text:
        return ExtractedResultManifest(text=raw_text, manifest=None, warnings=[])

    manifests: list[ChatResultManifest] = []
    warnings: list[ChatWarning] = []
    chunks: list[str] = []
    cursor = 0

    for match in _RESULT_MANIFEST_FENCE_PATTERN.finditer(raw_text):
        label = (match.group("label") or "").strip().lower()
        body = match.group("body").strip()
        parsed, should_strip, warning = _parse_manifest_fence(label, body)
        if parsed is not None:
            manifests.append(parsed)
        if warning is not None:
            warnings.append(warning)
        if should_strip:
            chunks.append(raw_text[cursor : match.start()])
            cursor = match.end()

    if cursor == 0:
        return ExtractedResultManifest(text=raw_text, manifest=None, warnings=warnings)

    chunks.append(raw_text[cursor:])
    cleaned_text = _collapse_blank_lines("".join(chunks)).strip()
    return ExtractedResultManifest(
        text=cleaned_text,
        manifest=_merge_result_manifests(manifests),
        warnings=warnings,
    )


def _parse_manifest_fence(
    label: str,
    body: str,
) -> tuple[ChatResultManifest | None, bool, ChatWarning | None]:
    is_manifest_label = label in _MANIFEST_FENCE_LABELS
    is_json_label = label in {"json", "jsonc"}
    if not is_manifest_label and not is_json_label:
        return None, False, None

    try:
        decoded = _loads_json_object(body)
    except json.JSONDecodeError:
        if not is_manifest_label:
            return None, False, None
        return (
            None,
            True,
            ChatWarning(
                message="The assistant included a structured result manifest, but it was not valid JSON.",
                level="warning",
            ),
        )

    manifest_payload = _manifest_payload_from_json(decoded, require_wrapper=not is_manifest_label)
    if manifest_payload is None:
        return None, False, None
    try:
        return ChatResultManifest.model_validate(manifest_payload), True, None
    except ValidationError:
        return (
            None,
            True,
            ChatWarning(
                message="The assistant included a structured result manifest, but one or more fields were invalid.",
                level="warning",
            ),
        )


def _loads_json_object(raw_json: str) -> dict[str, object]:
    candidate = raw_json.strip()
    for _ in range(2):
        parsed = json.loads(candidate)
        if isinstance(parsed, str):
            candidate = parsed.strip()
            continue
        if isinstance(parsed, dict):
            return parsed
        raise json.JSONDecodeError("manifest must be a JSON object", candidate, 0)
    raise json.JSONDecodeError("manifest must be a JSON object", candidate, 0)


def _manifest_payload_from_json(
    decoded: dict[str, object],
    *,
    require_wrapper: bool,
) -> dict[str, object] | None:
    for key in _MANIFEST_WRAPPER_KEYS:
        nested = decoded.get(key)
        if isinstance(nested, dict):
            return nested

    if decoded.get("type") == "mobaile_result":
        return {key: value for key, value in decoded.items() if key not in {"type", "version"}}

    if require_wrapper:
        return None
    return decoded


def _merge_result_manifests(manifests: list[ChatResultManifest]) -> ChatResultManifest | None:
    if not manifests:
        return None
    summary = next((manifest.summary for manifest in manifests if manifest.summary), None)
    return ChatResultManifest(
        summary=summary,
        artifacts=_dedupe_artifacts([artifact for manifest in manifests for artifact in manifest.artifacts]),
        file_changes=_dedupe_by_id([item for manifest in manifests for item in manifest.file_changes]),
        commands_run=_dedupe_by_id([item for manifest in manifests for item in manifest.commands_run]),
        tests_run=_dedupe_by_id([item for manifest in manifests for item in manifest.tests_run]),
        warnings=_dedupe_by_id([item for manifest in manifests for item in manifest.warnings]),
        next_actions=_dedupe_by_id([item for manifest in manifests for item in manifest.next_actions]),
    )


def _collapse_blank_lines(text: str) -> str:
    collapsed = re.sub(r"\n{3,}", "\n\n", text)
    return re.sub(r"[ \t]+\n", "\n", collapsed)


def _dedupe_by_id(items: list) -> list:
    deduped = []
    seen: set[str] = set()
    for item in items:
        key = item.model_dump_json() if hasattr(item, "model_dump_json") else repr(item)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(item)
    return deduped


def _dedupe_artifacts(items: list[ChatArtifact]) -> list[ChatArtifact]:
    deduped: list[ChatArtifact] = []
    seen: set[str] = set()
    for artifact in items:
        key = artifact.path or artifact.url or f"{artifact.type}:{artifact.title}"
        if key in seen:
            continue
        seen.add(key)
        deduped.append(artifact)
    return deduped
