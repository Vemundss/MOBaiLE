from __future__ import annotations

import importlib
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _canonical_json(payload: object) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def test_contract_artifacts_are_synced(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("VOICE_AGENT_DB_PATH", str(tmp_path / "runs.db"))
    monkeypatch.setenv("VOICE_AGENT_CAPABILITIES_REPORT_PATH", str(tmp_path / "capabilities.json"))
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    schemas = importlib.import_module("app.models.schemas")

    expected = {
        "contracts/openapi.json": module.app.openapi(),
        "contracts/action_plan.schema.json": schemas.ActionPlan.model_json_schema(),
        "contracts/chat_envelope.schema.json": schemas.ChatEnvelope.model_json_schema(),
    }

    for relative_path, generated in expected.items():
        contract_path = REPO_ROOT / relative_path
        assert contract_path.exists(), f"missing contract file: {relative_path}"
        checked_in = json.loads(contract_path.read_text(encoding="utf-8"))
        assert _canonical_json(checked_in) == _canonical_json(generated), (
            "contract drift detected for "
            f"{relative_path}. Re-run `cd backend && uv run python ../scripts/sync_contracts.py`."
        )
