#!/usr/bin/env python3
"""Minimal smoke test for backend utterance -> plan -> execute flow."""

from pathlib import Path
import sys
import time

# Ensure `backend/app` is importable when this script is run via a relative path.
REPO_ROOT = Path(__file__).resolve().parents[1]
BACKEND_DIR = REPO_ROOT / "backend"
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app.main import create_utterance, get_run
from app.models.schemas import UtteranceRequest


def main() -> None:
    response = create_utterance(
        UtteranceRequest(
            session_id="smoke-session",
            utterance_text="create a hello python script and run it",
        )
    )
    print("POST /v1/utterances:", response.model_dump())

    run = get_run(response.run_id)
    deadline = time.time() + 10
    while run.status == "running" and time.time() < deadline:
        time.sleep(0.2)
        run = get_run(response.run_id)
    print("GET /v1/runs/{run_id} status:", run.status)
    for event in run.events:
        print(f"- {event.type}: {event.message}")


if __name__ == "__main__":
    main()
