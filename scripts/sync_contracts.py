#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
BACKEND_ROOT = ROOT / "backend"
CONTRACTS_ROOT = ROOT / "contracts"


def _load_backend() -> tuple[Any, Any, Any]:
    sys.path.insert(0, str(BACKEND_ROOT))
    module = importlib.import_module("app.main")
    module = importlib.reload(module)
    schemas = importlib.import_module("app.models.schemas")
    return module.app, schemas.ActionPlan, schemas.ChatEnvelope


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    path.write_text(rendered, encoding="utf-8")


def _generated_contracts() -> dict[Path, Any]:
    app, action_plan_model, chat_envelope_model = _load_backend()
    return {
        CONTRACTS_ROOT / "openapi.json": app.openapi(),
        CONTRACTS_ROOT / "action_plan.schema.json": action_plan_model.model_json_schema(),
        CONTRACTS_ROOT / "chat_envelope.schema.json": chat_envelope_model.model_json_schema(),
    }


def _sync_contracts() -> dict[Path, Any]:
    artifacts = _generated_contracts()
    for path, payload in artifacts.items():
        _write_json(path, payload)
    return artifacts


def _check_contracts() -> int:
    artifacts = _generated_contracts()
    changed: list[Path] = []
    for path, payload in artifacts.items():
        expected = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        current = path.read_text(encoding="utf-8")
        if current != expected:
            changed.append(path)
    if changed:
        print("Contracts out of date. Re-run scripts/sync_contracts.py:")
        for path in changed:
            print(f"- {path.relative_to(ROOT)}")
        return 1
    print("Contracts are up to date.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync backend API contracts into contracts/")
    parser.add_argument("--check", action="store_true", help="fail if generated files are stale")
    args = parser.parse_args()

    if args.check:
        return _check_contracts()

    _sync_contracts()
    print("Contracts synchronized:")
    for rel in [
        "contracts/openapi.json",
        "contracts/action_plan.schema.json",
        "contracts/chat_envelope.schema.json",
    ]:
        print(f"- {rel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
