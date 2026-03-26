---
name: "peekaboo"
description: "Use when the task requires controlling the native macOS desktop, permission dialogs, password sheets, menu bar items, or apps a browser tool cannot reach."
---

# Peekaboo MCP Skill

Use Peekaboo for native desktop automation on the host machine.

## When to use it

- System Settings, Finder, Mail, Calendar, and other native macOS apps
- OS permission prompts and security dialogs
- password sheets, save/open panels, and menu bar interactions
- apps or interfaces that browser automation cannot access
- visible UI states the agent must inspect directly

## Operating rules

- Start with visibility and state: list apps/windows, check permissions, or inspect the current UI before acting.
- Prefer structured tools such as app, window, dialog, menu, and see before falling back to raw coordinates.
- Use element-targeted actions when possible; use coordinates only when the UI surface is not addressable.
- Treat Accessibility and Screen Recording as hard prerequisites for unattended desktop control.

## Remote autonomy guidance

- Use Peekaboo to recover from permission prompts, hidden dialogs, and inaccessible interfaces instead of repeatedly retrying shell commands.
- Keep the user informed about the exact app, window, or dialog you are operating.
- If required macOS permissions are missing, report the precise missing permission and stop instead of guessing.
