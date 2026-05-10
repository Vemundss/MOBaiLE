# MOBaiLE Launch Kit

This is the reusable backend-owned kit for launching MOBaiLE in public channels. Keep it grounded in things the public repo can prove: install flow, host/runtime architecture, screenshots, activity events, sanitized demo artifacts, and release notes.

## Positioning

One-line:

> Run local coding agents from iPhone without moving your repo, shell, files, credentials, or network into a hosted workspace.

Short version:

> MOBaiLE pairs an iPhone with a Mac or Linux host you control. The phone captures prompts, voice, attachments, and follow-up. The host keeps the repo, shell, credentials, files, network, agent CLI, pairing, policy, and run history.

Use this when space is tight:

> Your phone starts and follows the run. Your machine does the work.

Avoid these claims:

- "No data leaves your devices." Prompts can still go to the backend and to agent providers through the configured local CLI.
- "The iPhone runs code." The paired host runs code.
- "Fully autonomous by default." Safe mode and full-access mode are intentionally different.
- "Private because it is mobile." The trust model comes from the backend boundary, not the device category.

## First-Success Funnel

The public backend funnel should move a technical user through one concrete success:

1. Understand the split: phone controls, host executes.
2. Install the backend on the Mac or Linux host.
3. Pair the iPhone with the QR.
4. Run `mobaile first-run`.
5. See planning, execution, and result return to the same live thread.
6. Export proof with `mobaile demo --out mobaile-demo.md`.

Use this command block in posts and releases:

```bash
curl -fsSL https://raw.githubusercontent.com/Vemundss/mobaile/main/scripts/install.sh | bash -s -- --yes
mobaile first-run
mobaile demo --out mobaile-demo.md
```

## Proof Assets

Use these backend-owned assets before asking anyone to trust a broad claim:

- README hero image: `docs/readme-hero.png`
- Phone screenshots: `docs/readme-screens/`
- Trust page: `docs/trust.html`
- Install guide: `docs/USAGE.md`
- Search-intent pages: `docs/codex-from-iphone.html`, `docs/claude-code-from-iphone.html`, `docs/self-hosted-iphone-agent.html`, `docs/tailscale-iphone-agent.html`, and `docs/safe-vs-full-access.html`
- Sanitized replay: `mobaile demo --out mobaile-demo.md`
- Real-run replay, when safe: `mobaile demo --run-id <run-id> --out mobaile-demo.md`

Demo exports are useful because they follow the same backend activity events the phone UI uses, while omitting raw logs, stdout, stderr, prompts, file paths, and tokens by default.

## GitHub Release Template

````markdown
## Why it matters

MOBaiLE is useful when the work belongs on your own machine but the next prompt, check, or follow-up needs to happen from your phone. This release makes that path easier to try and easier to inspect.

## What changed

- <User-visible setup, pairing, runtime, or phone-thread improvement.>
- <Trust, safety, or diagnostics improvement.>
- <Docs, screenshot, or demo artifact improvement.>

## Try it

```bash
mobaile update
mobaile first-run
mobaile demo --out mobaile-demo.md
```

## Trust notes

The iPhone starts and follows runs. The paired Mac or Linux host still owns execution, files, credentials, network access, pairing, and policy. Mention any access-mode, pairing, or data-flow changes here.
````

## Founder Post Draft

Title:

> I built an iPhone control surface for local coding agents

Body:

> I wanted to start and follow Codex/Claude work from my phone without moving my repo, shell, credentials, files, or network access into a hosted workspace.
>
> MOBaiLE pairs an iPhone with a Mac or Linux host. The phone is for text, voice, attachments, progress, and follow-up. The host does the execution.
>
> The public backend includes the installer, pairing flow, trust model, and a sanitized demo exporter. The first success path is: install, scan the QR, run `mobaile first-run`, and watch planning/execution/result come back in one live phone thread.
>
> Repo: https://github.com/Vemundss/mobaile
>
> Trust model: https://vemundss.github.io/MOBaiLE/trust.html

## Hacker News / Reddit Draft

Title options:

- Show HN: MOBaiLE - run local coding agents from iPhone
- I built a phone control surface for Codex/Claude running on my own machine
- Run your own Mac or Linux coding agents from iPhone

Short post:

> MOBaiLE is a self-hosted backend plus iPhone app for controlling local coding agents from a phone.
>
> The split is the important part: the iPhone captures prompts/voice and follows progress, while the paired Mac or Linux host keeps the repo, shell, credentials, files, network, and agent CLI.
>
> The backend repo includes the installer, QR pairing, safe/full-access modes, Tailscale-friendly setup, readiness checks, and `mobaile demo`, which exports sanitized activity-event replays for sharing without raw logs, prompts, paths, or tokens.
>
> I am looking for feedback on the setup path, trust model, and what a phone-native control surface should show during long-running agent work.

## Community Reply Cheatsheet

If someone asks why not use a hosted IDE:

> MOBaiLE is for people who already have the right repo, shell, credentials, and network on a local machine. It keeps that execution environment in place and makes the phone the control surface.

If someone asks whether the phone runs code:

> No. The iPhone starts and follows runs. The paired Mac or Linux host does the execution.

If someone asks about security:

> The backend enforces pairing, auth, access mode, host policy, and file/runtime boundaries. Safe mode and full-access mode are explicit, and the trust model is public.

If someone asks what to try first:

> Install on the host, pair the iPhone with the QR, run `mobaile first-run`, then export a sanitized replay with `mobaile demo --out mobaile-demo.md`.

## Launch Checklist

- README top section shows the one-line value, install command, screenshot, and trust boundary.
- `docs/index.html`, `docs/trust.html`, `docs/support.html`, and `docs/privacy-policy.html` match the same public story.
- `docs/robots.txt`, `docs/sitemap.xml`, and `docs/llms.txt` are current.
- Search-intent pages link back to the install guide, trust model, and related guides.
- `mobaile first-run` succeeds on a representative host before posting.
- `mobaile demo --out mobaile-demo.md` produces a shareable artifact.
- Release notes include a "why it matters" section, not only a changelog.
- Community posts link the install guide and trust model, not only the App Store listing.
