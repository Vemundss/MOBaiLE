# MOBaiLE Onboarding Installer Design

Date: 2026-03-30

## Summary

MOBaiLE onboarding should feel like a product install, not a repo setup guide.

The chosen direction is:

- one public install command
- one short interactive terminal wizard
- one stable post-install control command
- simpler top-level README language that mirrors the wizard

This keeps setup lightweight while avoiding a separate host GUI in v1.

## Problem

Current onboarding still asks the user to mentally stitch together too many concepts:

- bootstrap vs install vs service scripts
- backend vs phone pairing vs runtime configuration
- security mode and network exposure expressed in operator language
- multiple docs repeating valid but differently framed setup paths

The result is that setup is possible, but the product does not feel obvious.

## Approaches Considered

### 1. Guided one-line installer plus terminal wizard

This adds a single user-facing entrypoint that explains the product, asks for a few choices, installs the service, and ends with QR pairing plus a stable control command.

Pros:

- lowest implementation cost
- highest immediate onboarding impact
- reuses existing install/service scripts instead of replacing them
- keeps security and reachability choices explicit at the right moment

Cons:

- still terminal-first
- quality depends on strong prompt wording and flow polish

### 2. Guided installer plus local web control page

This keeps the terminal wizard but opens a local control page for QR, status, and settings after install.

Pros:

- stronger sense that the backend is alive and visible
- clearer path to future desktop controls

Cons:

- introduces another runtime surface to maintain
- more moving parts before the simpler installer has proven itself

### 3. macOS menu bar controller

This adds a persistent host UI with daemon status and quick actions.

Pros:

- strongest “daemon is running and under control” feeling

Cons:

- substantially larger product surface
- macOS-specific
- too expensive for the first onboarding fix

## Chosen Direction

Build approach 1 now.

Design it so approach 2 remains possible later by reusing the same control primitives and status model.

## Goals

- Make first-time install feel like one obvious path.
- Use product language instead of operator language.
- Keep `Full Access` visible and selected by default, but still make the choice explicit.
- Make “where should your phone work?” understandable without networking knowledge.
- Give the user a durable way to inspect and control the running daemon after install.
- Simplify the top-level README so it matches the installer language and flow.

## Non-Goals

- Build a menu bar app in this phase.
- Replace the existing lower-level install/service scripts for developer use.
- Redesign the full backend configuration model.
- Add an in-app phone QR scanner in this phase.

## User Experience

### Public install command

The product should have one obvious command:

```bash
curl -fsSL https://raw.githubusercontent.com/vemundss/MOBaiLE/main/scripts/install.sh | bash
```

This command is the main entrypoint for human onboarding.

It should be the command shown in:

- top-level README
- in-app setup guide
- support docs

### Wizard flow

The installer should open an interactive terminal wizard by default.

Expected flow:

1. Explain the mental model in one screen.
   “MOBaiLE runs on this computer. Your iPhone connects to it.”
2. Ask for security mode.
3. Ask where the phone should work.
4. Ask whether to keep the backend running in the background.
5. Install and start the backend.
6. Generate pairing QR and give next steps.
7. End by introducing the `mobaile` control command.

### Wizard defaults

Security choice:

- `Full Access` selected by default
- `Safe`

Phone reachability:

- `Anywhere with Tailscale` selected by default
- `On this Wi-Fi`
- `Advanced...`

Background service:

- `Yes` selected by default

### Wizard copy

The wizard should avoid low-level terms like:

- backend
- expose network
- bind host
- public server URL

Preferred phrasing:

- runs on this computer
- your phone can use it anywhere with Tailscale
- keep it running in the background
- advanced connection setup

Example copy:

```text
MOBaiLE setup

Your iPhone will connect to this computer.

Choose security:
> Full Access
  Safe

Full Access uses your real tools and repo with fewer restrictions.
Safe keeps tighter defaults for a more cautious setup.

Where should your phone work?
> Anywhere with Tailscale
  On this Wi-Fi
  Advanced...
```

## Post-Install Control Surface

The installer should end with one stable control command:

```bash
mobaile status
```

This is the v1 answer to “I want to feel connected to the daemon running on my host.”

### `mobaile` command family

Initial commands:

- `mobaile status`
- `mobaile pair`
- `mobaile logs`
- `mobaile restart`
- `mobaile stop`
- `mobaile start`
- `mobaile config`

### `mobaile status`

This should show:

- running or stopped
- selected security mode
- selected phone reachability mode
- resolved URL
- pairing QR readiness
- quick next commands

Example output:

```text
Backend: Running
Security: Full Access
Phone access: Anywhere with Tailscale
URL: https://my-mac.tail123.ts.net
Pairing QR: Ready

Actions:
  mobaile pair
  mobaile restart
  mobaile logs
  mobaile config
```

## Technical Design

### New onboarding entrypoint

Add a new top-level script:

- `scripts/install.sh`

Responsibilities:

- user-facing interactive wizard
- defaults and wording
- mapping wizard choices to existing lower-level scripts
- final success summary and next steps

This script should call existing implementation scripts rather than absorb their logic.

### Existing scripts stay as lower-level building blocks

Keep these as internal/operator-facing primitives:

- `scripts/install_backend.sh`
- `scripts/bootstrap_server.sh`
- `scripts/service_macos.sh`
- `scripts/service_linux.sh`
- `scripts/pairing_qr.sh`
- `scripts/set_security_mode.sh`

The wizard should orchestrate them.

### New stable control entrypoint

Add a new user-facing command wrapper:

- `scripts/mobaile`

Installation should place or symlink a `mobaile` executable into a user-visible path, preferably:

- `~/.local/bin/mobaile`

This wrapper should:

- detect repo/runtime install location
- delegate to macOS or Linux service helpers
- surface pairing QR and config state in a simpler way

### Config mapping

Wizard choices map to current config like this:

- `Full Access` -> `VOICE_AGENT_SECURITY_MODE=full-access`
- `Safe` -> `VOICE_AGENT_SECURITY_MODE=safe`
- `Anywhere with Tailscale` -> install with phone-reachable mode and prefer Tailscale URL
- `On this Wi-Fi` -> install with LAN-reachable mode and no Tailscale expectation
- `Advanced...` -> expand to manual options like public URL or local-only mode

The installer should no longer require the user to understand `--expose-network` directly.

### Pairing refresh resilience

`backend/pairing.json` should follow the current mode and explicit overrides, but backend startup should not destructively rewrite a previously working remote pairing URL to loopback just because one refresh pass cannot currently see the network.

Rules:

- explicit current `public_server_url` stays first when provided
- `local` still resolves to loopback only
- `wifi` and `tailscale` use current detection results first
- if `wifi` or `tailscale` detection collapses to loopback-only during startup refresh, preserve a previously stored same-mode remote URL instead of overwriting the pairing file with `127.0.0.1`

This keeps the pairing file aligned with intentional mode changes while avoiding avoidable breakage during transient host-network issues.

## README Simplification

The top-level README should match the installer language.

Changes required:

- lead with one install command
- explain the product in plain language
- replace “setup options” framing with “recommended path first”
- move advanced or operator-facing flows lower
- keep Tailscale language simple:
  - “Anywhere with Tailscale”
  - not “pair over Tailscale” as the main heading

The README should describe:

1. paste one command on the computer
2. scan the QR with the phone
3. run `mobaile status` later if needed

## Error Handling

The wizard must explain failure states in product terms.

Examples:

- Tailscale missing:
  “Tailscale is not installed yet. MOBaiLE can still work on this Wi-Fi, or you can install Tailscale now for anywhere access.”
- Service install fails:
  “MOBaiLE is installed, but background startup was not configured. You can still run it manually now.”
- QR generation fails:
  “Pairing details were created, but the QR image could not be generated. MOBaiLE can still connect manually.”

## Testing

Verification should cover:

- macOS install path
- Linux install path
- interactive wizard prompt flow
- each default choice path
- degraded refresh behavior when a previously working remote URL exists
- `mobaile status`, `pair`, `restart`, `logs`, `config`
- README coherence with the new installer flow
- in-app setup guide alignment with the wizard wording

## Deferred Work

Explicitly defer:

- macOS menu bar UI
- local web control page
- phone-side QR scanner inside the app

Those can be revisited after the terminal wizard and `mobaile` command prove the simpler onboarding model.
