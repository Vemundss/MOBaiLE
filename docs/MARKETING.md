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
3. **Search-intent pages as demand capture.** Keep `docs/codex-from-iphone.html`, `docs/claude-code-from-iphone.html`, `docs/self-hosted-iphone-agent.html`, `docs/tailscale-iphone-agent.html`, and `docs/safe-vs-full-access.html` focused on specific high-intent queries.
4. **Crawl and AI-search files.** Keep `docs/robots.txt`, `docs/sitemap.xml`, and `docs/llms.txt` current when public pages change.
5. **Demo artifacts as proof.** Use `mobaile demo --out mobaile-demo.md` for a built-in sample, or `mobaile demo --run-id <run-id>` after a real run. These exports are designed to omit raw logs, stdout, stderr, prompts, file paths, and tokens.
6. **Launch kit as reusable copy.** Use `docs/LAUNCH_KIT.md` for release notes, community posts, founder posts, trust replies, and first-success commands.
7. **Releases as launch moments.** Every meaningful backend/runtime improvement should ship with a GitHub Release that includes a short "why it matters", an install/update command, and a demo artifact or screenshot.

## Backend Funnel

Optimize every public backend surface around one first-success loop:

1. Visitor understands the split: phone controls, host executes.
2. Visitor runs the installer on a Mac or Linux host.
3. Visitor pairs the iPhone with the QR.
4. Visitor runs `mobaile first-run`.
5. Visitor sees planning, execution, and result return to one live phone thread.
6. Visitor exports proof with `mobaile demo --out mobaile-demo.md`.

The backend should do the trust work before the App Store listing has to. The public repo can prove the install flow, the activity-event progress model, the access-mode boundary, the pairing model, and the sanitized demo exporter.

## Search Targets

Prioritize narrow developer/operator intent over broad "AI app" language:

- `run codex from iphone`
- `claude code iphone`
- `control local coding agent from phone`
- `self hosted iphone agent`
- `tailscale iphone agent`
- `safe mode vs full access agent`

Each page should answer the query directly in the first content block, then link to the install guide, trust model, and closest adjacent guide.

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

## 90-Minute Launch Sequence

Use this when a backend/runtime improvement is ready and verified:

1. Update the README or `docs/USAGE.md` only if the first-success path changed.
2. Run `mobaile first-run` on the host you are willing to show publicly.
3. Export a sanitized replay with `mobaile demo --out mobaile-demo.md`.
4. Create a GitHub Release using the template above and attach or link the replay.
5. Post one short founder note using `docs/LAUNCH_KIT.md`, then answer questions with specific trust-boundary details.
6. Feed repeated questions back into README, support, or trust docs.
