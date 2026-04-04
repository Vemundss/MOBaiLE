from __future__ import annotations

import pytest
from fastapi import HTTPException

from app.models.schemas import RuntimeExecutorDescriptor
from app.models.schemas import RuntimeSettingDescriptor
from app.runtime_settings_catalog import RuntimeSettingsCatalog


class _FakeEnv:
    def runtime_executor_descriptors(self) -> list[RuntimeExecutorDescriptor]:
        return [
            RuntimeExecutorDescriptor(
                id="local",
                title="Local",
                kind="internal",
                available=True,
                internal_only=True,
            ),
            RuntimeExecutorDescriptor(
                id="codex",
                title="Codex",
                kind="agent",
                available=True,
                settings=[
                    RuntimeSettingDescriptor(
                        id="model",
                        title="Model",
                        kind="enum",
                        allow_custom=True,
                        options=["gpt-5.4-mini"],
                    ),
                    RuntimeSettingDescriptor(
                        id="reasoning_effort",
                        title="Reasoning Effort",
                        kind="enum",
                        allow_custom=False,
                        options=["medium", "high", "xhigh"],
                    ),
                ],
            ),
            RuntimeExecutorDescriptor(
                id="claude",
                title="Claude",
                kind="agent",
                available=True,
                settings=[
                    RuntimeSettingDescriptor(
                        id="verbosity_level",
                        title="Verbosity",
                        kind="enum",
                        allow_custom=False,
                        options=["brief", "detailed"],
                    )
                ],
            ),
        ]


def test_runtime_settings_catalog_builds_slash_commands_from_executor_settings() -> None:
    catalog = RuntimeSettingsCatalog(_FakeEnv())

    commands = {command.id: command for command in catalog.runtime_setting_slash_commands()}

    assert commands["model"].aliases == ["runtime-model"]
    assert commands["effort"].argument_options == ["backend-default", "medium", "high", "xhigh"]
    assert commands["verbosity-level"].title == "Verbosity"


def test_runtime_settings_catalog_maps_slash_command_ids_back_to_setting_ids() -> None:
    catalog = RuntimeSettingsCatalog(_FakeEnv())

    assert catalog.slash_command_runtime_setting_id("effort") == "reasoning_effort"
    assert catalog.slash_command_runtime_setting_id("verbosity-level") == "verbosity_level"


def test_runtime_settings_catalog_validates_codex_reasoning_effort_values() -> None:
    catalog = RuntimeSettingsCatalog(_FakeEnv())

    assert catalog.validated_runtime_setting_value("codex", "reasoning_effort", "XHIGH") == "xhigh"

    with pytest.raises(HTTPException, match="codex reasoning effort must be one of"):
        catalog.validated_runtime_setting_value("codex", "reasoning_effort", "turbo")
