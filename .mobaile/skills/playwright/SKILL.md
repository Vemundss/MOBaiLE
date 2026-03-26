---
name: "playwright"
description: "Use when the task requires operating a real browser for authenticated web flows, dynamic apps, screenshots, or structured browser debugging."
---

# Playwright MCP Skill

Use the Playwright MCP tools whenever the task lives inside a browser tab and a local CLI or API is not enough.

## When to use it

- logging into websites or web apps
- navigating SPAs and dynamic dashboards
- collecting screenshots, DOM snapshots, console logs, or network details
- handling browser-native dialogs, downloads, uploads, and multi-step web flows

## Operating rules

- Reuse the existing browser session and persistent profile whenever possible.
- Take a fresh snapshot after navigation or any substantial UI change before acting on element refs again.
- Prefer element-targeted actions and browser-native tools over brittle DOM-eval shortcuts.
- Use screenshots, snapshots, console logs, and network logs to debug failures before retrying.

## Remote autonomy guidance

- Prefer Playwright over shell scraping for authenticated or JavaScript-heavy sites.
- Preserve session state instead of restarting the browser from scratch when a flow fails.
- If a site requires a genuine CAPTCHA, WebAuthn key, or user-bound 2FA challenge, stop looping and ask the user for the exact unblock step while keeping the session intact.
