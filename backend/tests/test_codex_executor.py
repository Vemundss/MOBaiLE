from pathlib import Path

from app.executors.codex_executor import CodexExecutor


def test_build_command_places_search_before_exec(monkeypatch) -> None:
    monkeypatch.setenv("VOICE_AGENT_SECURITY_MODE", "safe")
    monkeypatch.delenv("VOICE_AGENT_CODEX_UNRESTRICTED", raising=False)
    executor = CodexExecutor(Path.cwd(), binary="codex", enable_web_search=True)

    command = executor._build_command("Test prompt")

    assert command == [
        "codex",
        "--search",
        "exec",
        "--json",
        "--skip-git-repo-check",
        "Test prompt",
    ]


def test_build_command_resume_keeps_exec_subcommand_flags(monkeypatch) -> None:
    monkeypatch.setenv("VOICE_AGENT_SECURITY_MODE", "full-access")
    monkeypatch.delenv("VOICE_AGENT_CODEX_UNRESTRICTED", raising=False)
    monkeypatch.setenv("VOICE_AGENT_CODEX_MODEL", "gpt-5.4")
    executor = CodexExecutor(Path.cwd(), binary="codex", enable_web_search=False)

    command = executor._build_command("Continue", resume_session_id="session-123")

    assert command == [
        "codex",
        "exec",
        "resume",
        "session-123",
        "--json",
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        "--model",
        "gpt-5.4",
        "Continue",
    ]
