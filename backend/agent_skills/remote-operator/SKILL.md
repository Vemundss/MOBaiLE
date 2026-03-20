---
name: "remote-operator"
description: "Use for remote-control tasks that may span shell, browser, and desktop automation and risk stalling on auth gates, hidden UI, or missing privileges."
---

# Remote Operator Skill

This skill defines the default strategy for unattended MOBaiLE runs.

## Control-surface order

1. Prefer local CLI or API access when it is deterministic.
2. Use Playwright for browser tasks and authenticated web apps.
3. Use Peekaboo for native UI, permission sheets, password dialogs, and anything the browser cannot reach.
4. Request a human unblock only for genuine user-bound challenges.

## Anti-stall rules

- Reuse persistent sessions and profiles instead of restarting from zero.
- If a task crosses tools, choose the least fragile surface at each step rather than forcing everything through one interface.
- Do not brute-force auth, bypass CAPTCHAs, or loop on the same failing action.
- When blocked, preserve state and ask only for the exact unblock action needed.

## Human-bound blockers

These generally need a human:

- CAPTCHA that requires human completion
- 2FA push, SMS code, or hardware security key
- password or secret that is not already available on the host
- first-run macOS privacy permission that the OS requires the user to grant manually

When one of these appears, say exactly what is blocking progress and what state has already been preserved.
