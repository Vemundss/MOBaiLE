# `.mobaile`

Hidden repo-local runtime assets for MOBaiLE.

This folder is not part of the normal human documentation surface.

Contents:

- `runtime/RUNTIME_CONTEXT.md`: repo-owned runtime guidance injected into backend-launched agents

Notes:

- Repo-development guidance belongs in the repo root `AGENTS.md`, not here.
- Tool-specific global state belongs in user homes such as `~/.codex`, not here.
- Runtime-generated workdir files such as `.mobaile/AGENTS.md` and `.mobaile/MEMORY.md` may appear when the repo root itself is used as a working directory; those files are intentionally untracked.
