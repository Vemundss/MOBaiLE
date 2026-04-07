# Contributing to MOBaiLE

Thanks for contributing.

## Before You Start

- Read the top-level [README](README.md) for the product overview and setup paths.
- Use the smallest safe change that solves the problem.
- Keep generated files, local pairing artifacts, logs, and secrets out of commits.

## Development Setup

Backend:

```bash
bash ./scripts/install_backend.sh --mode safe
cd backend
bash ./run_backend.sh
```

iOS:

```bash
cd ios
open VoiceAgentApp.xcodeproj
```

## Pull Requests

- Describe the user-visible behavior change.
- Call out backend, iOS, and docs impact separately when relevant.
- Include verification steps you actually ran.
- Add or update tests for behavior changes where practical.
- Keep App Store surfaces in sync when product behavior changes:
  `docs/privacy-policy.html`, `docs/support.html`, and release notes.

## Tests

Backend:

```bash
cd backend
uv run pytest -q
```

iOS:

```bash
cd ios
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Reporting Issues

- Use GitHub Issues for bugs, regressions, and feature requests.
- Include the environment, reproduction steps, expected behavior, and actual behavior.
- Remove tokens, private URLs, and local file paths you do not want to publish.
