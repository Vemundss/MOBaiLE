# `.mobaile`

Hidden repo-local assets for MOBaiLE-managed agent behavior.

This folder is not part of the normal human documentation surface.

Contents:

- `AGENT_CONTEXT.md`: repo-owned runtime guidance injected into backend-launched agents
- `skills/`: managed skill definitions copied into a Codex home during autonomy provisioning

Notes:

- Tool-specific global state belongs in user homes such as `~/.codex`, not here.
- Runtime-generated workdir files such as `.mobaile/AGENTS.md` and `.mobaile/MEMORY.md` may appear when the repo root itself is used as a working directory; those files are intentionally untracked.
