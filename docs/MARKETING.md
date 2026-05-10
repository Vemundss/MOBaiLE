# Marketing Plan

MOBaiLE should be marketed through proof surfaces first: the public backend repository, GitHub Pages, install flow, demo artifacts, and release notes. The strongest message is not "mobile AI app"; it is:

> Run local coding agents from iPhone without moving your repo, shell, files, credentials, or network access into a hosted workspace.

## Primary Audience

- Developers who already use Codex CLI or Claude Code locally.
- Operators and founders who need to start, follow, or unblock work away from the desk.
- Security-conscious users who want inspectable self-hosted control instead of opaque remote execution.

The first success is: install the backend, pair the phone, send one prompt, and watch planning, execution, and the final result return to the same live thread.

## Acquisition Surfaces

1. **README as landing page.** Keep the top of `README.md` optimized for value proposition, install, screenshots, trust boundaries, and first success.
2. **GitHub Pages as product site.** Keep `docs/index.html`, `docs/trust.html`, `docs/support.html`, and `docs/privacy-policy.html` aligned with the App Store and public install story.
3. **Demo artifacts as proof.** Use `mobaile demo --out mobaile-demo.md` for a built-in sample, or `mobaile demo --run-id <run-id>` after a real run. These exports are designed to omit raw logs, stdout, stderr, prompts, file paths, and tokens.
4. **Releases as launch moments.** Every meaningful backend/runtime improvement should ship with a GitHub Release that includes a short "why it matters", an install/update command, and a demo artifact or screenshot.

## Message Pillars

- **Your machine does the work.** The phone starts and follows runs; the paired Mac or Linux host keeps the repo, shell, credentials, files, and network.
- **Live progress beats final-only updates.** Planning, executing, blocked states, summaries, artifacts, tests, and next actions stay together in one thread.
- **Trust boundaries stay explicit.** Safe mode, full-access mode, QR pairing, one-time pair codes, and Tailscale/public URL choices are visible and documented.
- **Fast setup matters.** The recommended one-liner should stay the default path, with `mobaile first-run`, `mobaile check`, `mobaile repair`, and `mobaile demo` as obvious next steps.

## Content Backlog

- "I built an iPhone control surface for local coding agents"
- "Why MOBaiLE keeps execution on your own machine"
- "Using Tailscale to run local agents from iPhone"
- "Safe mode vs full-access mode in MOBaiLE"
- "What a MOBaiLE run looks like from prompt to final summary"
- "Codex CLI on your Mac, controlled from your phone"
- "How MOBaiLE exports sanitized demo replays from backend activity events"

## Channel Order

1. GitHub README and Releases
2. GitHub Pages product, trust, privacy, and support pages
3. Short founder-led walkthrough posts with real `mobaile demo` artifacts
4. Developer communities once setup and proof are polished: Hacker News, relevant Reddit communities, Tailscale/Codex/Claude-adjacent forums
5. App Store listing copy and screenshots after the public repo/site story is stable

## Release Note Template

````markdown
## Why It Matters

<One short paragraph about the user problem this release improves.>

## What Changed

- <User-visible change>
- <Setup, trust, or runtime improvement>
- <Docs/demo artifact if available>

## Try It

```bash
mobaile update
mobaile first-run
mobaile demo --out mobaile-demo.md
```

## Trust Notes

<Mention any execution, pairing, permissions, or data-flow implications.>
````
