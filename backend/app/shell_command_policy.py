from __future__ import annotations

import shlex
from pathlib import Path


def persistent_cd_target(command: str, current_workdir: Path, *, workdir_root: Path | None = None) -> Path | None:
    """Return the target directory for shell commands that should persist cwd.

    MOBaiLE shell mode keeps a session working directory even though each
    command runs in its own host process. Persist simple `cd path` commands and
    the common `cd path && command` prefix, which is how users usually move into
    a project directory before running the next command.
    """
    try:
        tokens = _shell_tokens(command.strip())
    except ValueError:
        return None
    target = _persistent_cd_argument(tokens)
    if target is None:
        return None

    requested = Path(target).expanduser()
    if not requested.is_absolute():
        requested = current_workdir / requested
    resolved = requested.resolve(strict=False)

    if workdir_root is not None and not _is_relative_to(resolved, workdir_root):
        raise ValueError(f"working_directory must stay inside {workdir_root}")
    if not resolved.exists() or not resolved.is_dir():
        return None
    return resolved


def _shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def _persistent_cd_argument(tokens: list[str]) -> str | None:
    if len(tokens) == 2 and tokens[0] == "cd" and tokens[1] != "-":
        return tokens[1]
    if len(tokens) >= 4 and tokens[0] == "cd" and tokens[1] != "-" and tokens[2] == "&&":
        return tokens[1]
    return None


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False
