# MOBaiLE Repo Agents

This file is the main repo contract for human contributors and coding agents working on MOBaiLE itself.

## Intent

MOBaiLE is a handheld control surface for your own Mac or Linux machine.
The phone app starts, follows, and manages work, but the paired host machine does the actual execution.

This repo contains both the phone app and the computer-side runtime.
Changes should preserve that split while keeping the overall experience legible, trustworthy, and production-ready.

## Scope

- Use this file for development guidance only.
- Read `README.md`, `docs/USAGE.md`, and `ARCHITECTURE.md` for product direction and current system shape.
- Runtime behavior for server-side MOBaiLE agent runs lives under `.mobaile/runtime/`.
- Per-user runtime state lives under `backend/data/` and is not repo-owned guidance.
- Keep repo guidance in this file. Do not add repo-local skills by default; local agent skills are user-managed.

## Repo Map

- `backend/`: FastAPI control plane, run orchestration, persistence, runtime policy.
- `ios/`: SwiftUI app, local thread/message state, pairing and client UX.
- `contracts/`: generated artifacts synced from backend schemas.
- `.mobaile/runtime/`: repo-owned runtime context injected into backend-launched agents.

## Product Rules

- The phone is the control surface. The paired host machine does the work.
- Preserve clear trust boundaries. Security mode, permissions, and host capabilities must stay explicit, not implicit.
- Pairing and connectivity flows should optimize for clarity and recoverability, not cleverness.
- Keep live thread UX, run diagnostics, and persistent runtime/profile state as separate concerns.
- Safe mode and full-access mode should remain understandable and intentionally different. Do not blur the distinction in code or UI.
- Prefer self-hosted transparency and inspectability over opaque automation.
- When designing new behavior, keep the product usable both at the desk and away from it.

## Domain Defaults

- `run`: a single execution attempt on the paired host
- `session`: the ongoing conversation/runtime context that new runs inherit from
- `thread`: the user-visible chronology of prompts, progress, summaries, and follow-up
- `executor`: the backend-selected execution path such as `local`, `codex`, or `claude`
- `runtime context`: repo-owned instructions and runtime defaults injected into server-side agent runs
- `profile state`: mutable per-profile `AGENTS.md` / `MEMORY.md` data stored under `backend/data/`
- `workspace` or `working directory`: the host-side directory a run operates in
- `capability`: a probed host/runtime ability such as an installed binary, MCP integration, or permission state
- `pairing`: the trust/bootstrap step that connects an iPhone app to a specific backend host

Use these terms consistently when naming code, APIs, docs, and UI copy.
Do not collapse `run`, `session`, `thread`, and `profile` into each other when they mean different things.

## Working Style

- Implement for quality, not mere adequacy.
- Choose the change shape that best fits the task. Small patches are fine, but broader refactors are also fine when they materially improve the touched area.
- Make the requested change well, then evaluate whether there are natural adjacent improvements needed for the result to feel coherent and production-quality.
- When those adjacent improvements are clearly beneficial, low-risk, and directly connected to the task, make them without waiting for extra prompting.
- Use judgment to avoid unrelated scope creep. Improve the touched area meaningfully, but do not silently turn one task into a broad rewrite.
- Prefer clearer structure, simpler control flow, and better ownership boundaries over preserving incidental complexity.
- Update docs, tests, and contracts together when external behavior changes.
- Treat `backend/app/models/schemas.py` as the source of truth for API shapes.
- Keep chat output, diagnostic logs, and persistent runtime state as separate concerns.
- Do not add repo-local development skills by default; local agent skills are user-managed.
- Keep business rules close to the domain layer instead of scattering them across UI, handlers, and helpers.
- Validate inputs and state transitions at boundaries. Fail loudly and early when invariants are broken.
- Do not add heavy abstractions before they are justified by the code that already exists.

## Verification

- Do not claim a change is complete without running the narrowest relevant verification you reasonably can.
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
- UI changes:
  - capture fresh screenshots of the relevant screens or states before handoff when the change is meaningfully visual
  - review spacing, hierarchy, clarity, responsiveness, and overall quality before calling the work done
  - if screenshots show obvious UI problems, iterate before handoff
- Local availability after verified changes:
  - iOS UI or client behavior changes: after relevant tests/screenshots pass, rebuild and install MOBaiLE on the connected development iPhone so the current app is ready for evaluation. Use the already-configured Xcode signing/device setup. If no physical device or signing target is available, say so explicitly in the final handoff.
  - Backend or host-runtime changes: after backend checks pass, update the installed host runtime from the current checkout and restart it. On macOS run `bash ./scripts/service_macos.sh sync` then `bash ./scripts/service_macos.sh restart`; on Linux run `bash ./scripts/service_linux.sh sync` then `bash ./scripts/service_linux.sh restart`. Then run `mobaile status`, the service `status` command, or `/health` to confirm the installed runtime is serving the latest change.
- When a behavior change is made, prefer at least one automated test unless the repo truly has no reasonable test path for that area.
- If tooling is missing for a touched area, say so clearly and update docs if needed.
- If you could not run a relevant check, say so explicitly in the final handoff.
- Before handoff, make a final judgment on whether the implementation is actually complete and good enough for this repo's quality bar, not just whether the original request was narrowly addressed.

## Completion

- Do not stop at local edits when the task is clearly ready to ship.
- Once the relevant checks pass, stage, commit, and push repo changes unless the user explicitly asks you to leave them unpushed.
- If some relevant verification could not be run, say that before pushing or ask whether to proceed with the known gap.

## Git Rules

- MOBaiLE uses `main` as the active development branch unless the user explicitly asks for a separate branch.
- Before starting new work on a clean tree, sync with `main`.
- If the tree is dirty, do not `git pull` blindly. Commit, stash, branch, or otherwise resolve intentionally first.
- Check `git status` before and after your work.
- Keep one change set focused on one concern when practical.
- Do not rewrite or discard other changes unless the user explicitly asks for that.
- If you find conflicting local edits in the same area, stop and resolve intentionally instead of force-overwriting.
- After completing verified work, commit it and push it to `main` unless the user explicitly asks to keep it local or to target another branch.

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

## Documentation

- Update `README.md` when product direction, setup flow, or major workflow assumptions change.
- Update `docs/USAGE.md`, `backend/README.md`, `ios/README.md`, `scripts/README.md`, or `ARCHITECTURE.md` when the touched area changes their assumptions.
- Keep repo docs consistent with runtime naming and trust-boundary terminology.

## When Unsure

- Choose clarity over magic.
- Choose reversible decisions over sticky accidental complexity.
- Choose explicit trust boundaries over hidden convenience.
- Choose naming that preserves the difference between runs, sessions, threads, executors, and profile state.
- Leave the touched area easier to understand than you found it.
