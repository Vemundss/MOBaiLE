from __future__ import annotations

from functools import cached_property
from typing import TYPE_CHECKING

from fastapi import HTTPException

from app.models.schemas import RuntimeSettingDescriptor, SlashCommandDescriptor
from app.runtime_environment_loader import CODEX_REASONING_EFFORT_OPTIONS

if TYPE_CHECKING:
    from app.runtime_environment import RuntimeEnvironment

RuntimeSettingKey = tuple[str, str]
PROFILE_AGENTS_SETTING_ID = "profile_agents"
PROFILE_MEMORY_SETTING_ID = "profile_memory"
PROFILE_CONTEXT_OPTIONS = ("enabled", "disabled")


class RuntimeSettingsCatalog:
    def __init__(self, env: RuntimeEnvironment) -> None:
        self._env = env

    def normalized_runtime_setting_id(self, value: str | None) -> str | None:
        normalized = (value or "").strip()
        if not normalized:
            return None
        return normalized.lower().replace(" ", "_")

    @cached_property
    def runtime_setting_descriptor_map(self) -> dict[RuntimeSettingKey, RuntimeSettingDescriptor]:
        descriptors: dict[RuntimeSettingKey, RuntimeSettingDescriptor] = {}
        for executor in self._env.runtime_executor_descriptors():
            for setting in executor.settings or []:
                setting_id = self.normalized_runtime_setting_id(setting.id)
                if setting_id is None:
                    continue
                descriptors[(executor.id, setting_id)] = setting
        return descriptors

    @cached_property
    def runtime_executor_titles(self) -> dict[str, str]:
        return {executor.id: executor.title for executor in self._env.runtime_executor_descriptors()}

    @cached_property
    def available_runtime_setting_entries(self) -> list[tuple[str, list[tuple[str, RuntimeSettingDescriptor]]]]:
        entries: dict[str, list[tuple[str, RuntimeSettingDescriptor]]] = {}
        order: list[str] = []
        for executor in self._env.runtime_executor_descriptors():
            if executor.internal_only or not executor.available:
                continue
            for setting in executor.settings or []:
                setting_id = self.normalized_runtime_setting_id(setting.id)
                if setting_id is None:
                    continue
                if setting_id not in entries:
                    entries[setting_id] = []
                    order.append(setting_id)
                entries[setting_id].append((executor.id, setting))
        return [(setting_id, entries[setting_id]) for setting_id in order]

    def runtime_setting_supported_executors(self, setting_id: str) -> list[str]:
        normalized_setting_id = self.normalized_runtime_setting_id(setting_id)
        if normalized_setting_id is None:
            return []
        for candidate_setting_id, descriptors in self.available_runtime_setting_entries:
            if candidate_setting_id == normalized_setting_id:
                return [executor for executor, _ in descriptors]
        return []

    def runtime_setting_slash_command_id(self, setting_id: str) -> str:
        normalized_setting_id = self.normalized_runtime_setting_id(setting_id) or setting_id
        if normalized_setting_id == "reasoning_effort":
            return "effort"
        command_id = normalized_setting_id.replace("_", "-")
        if command_id in {"cwd", "executor"}:
            return f"runtime-{command_id}"
        return command_id

    def slash_command_runtime_setting_id(self, command_id: str) -> str | None:
        normalized_command = (command_id or "").strip()
        if not normalized_command:
            return None
        lowered_command = normalized_command.lower()
        for setting_id, _ in self.available_runtime_setting_entries:
            if self.runtime_setting_slash_command_id(setting_id) == lowered_command:
                return setting_id
        return None

    def runtime_setting_option_list(
        self,
        descriptors: list[tuple[str, RuntimeSettingDescriptor]],
    ) -> list[str]:
        options: list[str] = []
        seen: set[str] = set()
        for _, descriptor in descriptors:
            for option in descriptor.options:
                lowered = option.lower()
                if lowered in seen:
                    continue
                seen.add(lowered)
                options.append(option)
        return options

    def runtime_setting_allows_custom(
        self,
        descriptors: list[tuple[str, RuntimeSettingDescriptor]],
    ) -> bool:
        return any(descriptor.allow_custom for _, descriptor in descriptors)

    def runtime_setting_usage(
        self,
        command_id: str,
        options: list[str],
        *,
        allow_custom: bool,
        placeholder: str,
    ) -> str:
        if allow_custom:
            return f"/{command_id} [backend-default|{placeholder}]"
        usage_options = ["backend-default", *options] if options else ["backend-default"]
        return f"/{command_id} [{'|'.join(usage_options)}]"

    def runtime_setting_command_metadata(
        self,
        setting_id: str,
        descriptors: list[tuple[str, RuntimeSettingDescriptor]],
    ) -> tuple[str, str, list[str], str, str]:
        normalized_setting_id = self.normalized_runtime_setting_id(setting_id) or setting_id
        if normalized_setting_id == "model":
            return (
                "Model Override",
                "Show or override the active agent model for this session.",
                ["runtime-model"],
                "sparkles",
                "model-id",
            )
        if normalized_setting_id == "reasoning_effort":
            return (
                "Reasoning Effort",
                "Show or override the active executor reasoning effort for this session.",
                ["thinking", "reasoning", "reasoning-effort"],
                "brain.head.profile",
                "effort",
            )
        if normalized_setting_id == PROFILE_AGENTS_SETTING_ID:
            return (
                "Profile Instructions",
                "Include or skip the per-user AGENTS profile for new runs in this session.",
                [],
                "person.text.rectangle",
                "enabled|disabled",
            )
        if normalized_setting_id == PROFILE_MEMORY_SETTING_ID:
            return (
                "Profile Memory",
                "Allow or skip the per-user MEMORY profile for new runs in this session.",
                [],
                "brain",
                "enabled|disabled",
            )

        primary_descriptor = descriptors[0][1]
        title = primary_descriptor.title.strip() or normalized_setting_id.replace("_", " ").title()
        description = f"Show or override the active {title.lower()} for this session."
        return (title, description, [], "slider.horizontal.3", normalized_setting_id.replace("_", "-"))

    def runtime_setting_title_text(
        self,
        setting_id: str,
        descriptor: RuntimeSettingDescriptor | None = None,
    ) -> str:
        if descriptor is not None and descriptor.title.strip():
            return descriptor.title.strip().lower()
        normalized_setting_id = self.normalized_runtime_setting_id(setting_id) or setting_id
        for candidate_setting_id, descriptors in self.available_runtime_setting_entries:
            if candidate_setting_id == normalized_setting_id and descriptors:
                candidate_title = descriptors[0][1].title.strip()
                if candidate_title:
                    return candidate_title.lower()
                break
        return normalized_setting_id.replace("_", " ")

    def runtime_setting_slash_commands(self) -> list[SlashCommandDescriptor]:
        commands: list[SlashCommandDescriptor] = []
        for setting_id, descriptors in self.available_runtime_setting_entries:
            command_id = self.runtime_setting_slash_command_id(setting_id)
            title, description, aliases, symbol, placeholder = self.runtime_setting_command_metadata(
                setting_id,
                descriptors,
            )
            options = self.runtime_setting_option_list(descriptors)
            allow_custom = self.runtime_setting_allows_custom(descriptors)
            commands.append(
                SlashCommandDescriptor(
                    id=command_id,
                    title=title,
                    description=description,
                    usage=self.runtime_setting_usage(
                        command_id,
                        options,
                        allow_custom=allow_custom,
                        placeholder=placeholder,
                    ),
                    group="Runtime",
                    aliases=aliases,
                    symbol=symbol,
                    argument_kind="text" if allow_custom or not options else "enum",
                    argument_options=[] if allow_custom else ["backend-default", *options],
                    argument_placeholder=placeholder,
                )
            )
        return commands

    def canonical_runtime_setting_option(self, value: str, options: list[str]) -> str | None:
        normalized = value.strip()
        if not normalized:
            return None
        lowered = normalized.lower()
        for option in options:
            if option.lower() == lowered:
                return option
        return None

    def validated_runtime_setting_value(
        self,
        executor: str,
        setting_id: str,
        value: str | None,
    ) -> str | None:
        normalized_setting_id = self.normalized_runtime_setting_id(setting_id)
        if normalized_setting_id is None:
            raise HTTPException(status_code=400, detail="runtime setting id is required")

        descriptor = self.runtime_setting_descriptor_map.get((executor, normalized_setting_id))
        if descriptor is None:
            raise HTTPException(
                status_code=400,
                detail=f"runtime setting {executor}.{normalized_setting_id} is not supported by this backend",
            )

        normalized_value = (value or "").strip() or None
        if normalized_value is None:
            return None

        if executor == "codex" and normalized_setting_id == "reasoning_effort":
            return self.validated_optional_codex_reasoning_effort(normalized_value)

        canonical_option = self.canonical_runtime_setting_option(normalized_value, descriptor.options)
        if canonical_option is not None:
            return canonical_option
        if descriptor.allow_custom:
            return normalized_value

        allowed = ", ".join(descriptor.options)
        raise HTTPException(
            status_code=400,
            detail=f"runtime setting {executor}.{normalized_setting_id} must be one of: {allowed}",
        )

    def validated_optional_codex_reasoning_effort(self, value: str | None) -> str | None:
        normalized = (value or "").strip().lower()
        if not normalized:
            return None
        if normalized not in CODEX_REASONING_EFFORT_OPTIONS:
            allowed = ", ".join(CODEX_REASONING_EFFORT_OPTIONS)
            raise HTTPException(status_code=400, detail=f"codex reasoning effort must be one of: {allowed}")
        return normalized
