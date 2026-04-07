# MOBaiLE Repo Agents

This file is for agents working on the MOBaiLE repository itself.

## Scope

- Use this file for development guidance only.
- Runtime behavior for server-side MOBaiLE agent runs lives under `.mobaile/runtime/`.
- Per-user runtime state lives under `backend/data/` and is not repo-owned guidance.

## Repo Map

- `backend/`: FastAPI control plane, run orchestration, persistence, runtime policy.
- `ios/`: SwiftUI app, local thread/message state, pairing and client UX.
- `contracts/`: generated artifacts synced from backend schemas.
- `.mobaile/runtime/`: repo-owned runtime context injected into backend-launched agents.

## Working Style

- Choose the change shape that best fits the task. Small patches are fine, but broader refactors are also fine when they materially improve the touched area.
- Prefer clearer structure, simpler control flow, and better ownership boundaries over preserving incidental complexity.
- Update docs, tests, and contracts together when external behavior changes.
- Treat `backend/app/models/schemas.py` as the source of truth for API shapes.
- Keep chat output, diagnostic logs, and persistent runtime state as separate concerns.
- Do not add repo-local development skills by default; local agent skills are user-managed.

## Verification

- Run the narrowest relevant checks after making changes.
- Once the relevant checks pass, prefer staging, committing, and pushing the verified work unless the user asked you to keep it local.
- Backend Python changes:
  - `npm run backend:lint`
  - `cd backend && uvx ruff check app tests`
  - `cd backend && uv run pytest <targeted tests>`
- Shell script changes:
  - `npm run shell:lint` when `shellcheck` and `shfmt` are installed
  - if they are not installed locally, run `bash -n <touched script>` at minimum and say that CI will run the full shell checks
- Backend schema or contract changes:
  - `cd backend && uv run python ../scripts/sync_contracts.py --check`
- iOS SwiftUI or client behavior changes:
  - run the most relevant `xcodebuild ... test` target you can reasonably verify
- If you could not run a relevant check, say so explicitly in the final handoff.

## Completion

- Do not stop at local edits when the task is clearly ready to ship.
- Once the relevant checks pass, stage, commit, and push repo changes unless the user explicitly asks you to leave them unpushed.
- If some relevant verification could not be run, say that before pushing or ask whether to proceed with the known gap.

## Design Rules

- Prefer straightforward code over clever code.
- Prefer guard clauses over deep nesting.
- Extract helpers before a third level of nesting unless the inline flow is still clearly easier to read.
- Split modules by responsibility, not by arbitrary size alone.
- If a function or file is becoming hard to name, test, or scan, treat that as a refactor signal.

## Size Heuristics

These are review signals, not hard gates.

- Functions around 40-60 logical lines deserve a quick review for possible extraction.
- Functions above roughly 80 logical lines should usually be split unless there is a clear reason to keep them together.
- More than 2-3 nested control-flow levels is a strong signal to simplify.
- Files around 300-500 lines should be reviewed for mixed responsibilities.
- Large SwiftUI files are acceptable when the view is cohesive, but subviews and helper types should be extracted once sections stop being easy to scan.

## Cleanup Expectations

- If you touch an area and find clearly dead, duplicated, or legacy code, prefer pruning or simplifying it when the risk is low.
- Reuse and extraction are encouraged when they make future changes cheaper.
- Do not preserve compatibility layers that no longer serve a real user or migration path.
- If a useful cleanup is bigger than the task at hand, call it out as follow-up work instead of forcing it into the same patch.

## Known Hotspots

- `backend/app/runtime_session_service.py`: keep slash-command UX separate from session-context persistence and normalization.
- `backend/app/storage/run_store.py`: avoid adding more mixed storage logic without extracting helpers or focused modules.
- `backend/app/capability_probes.py`: prefer small probe helpers over expanding one large file.
- `backend/tests/test_api.py`: prefer new focused test modules over adding more unrelated coverage to the catch-all file.
- `ios/VoiceAgentApp/VoiceAgentViewModel.swift`: favor extracting domain-specific helpers/services when touching large behavior areas.
- `ios/VoiceAgentApp/ContentView.swift`, `ios/VoiceAgentApp/ChatRenderers.swift`, and `ios/VoiceAgentApp/ChatScaffoldViews.swift`: prefer subviews and focused view helpers when adding UI behavior.

## Runtime-Agent Edits

- Keep repo-owned runtime defaults under `.mobaile/runtime/`.
- Keep mutable profile state under `backend/data/profiles/<profile_id>/`.
- Preserve backward compatibility for existing installs when renaming env vars or file paths.
