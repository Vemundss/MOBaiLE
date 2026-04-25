from pathlib import Path

from app.executors.codex_executor import CodexExecutor


def test_build_command_places_search_before_exec(monkeypatch) -> None:
    monkeypatch.setenv("VOICE_AGENT_SECURITY_MODE", "safe")
    monkeypatch.delenv("VOICE_AGENT_CODEX_UNRESTRICTED", raising=False)
    monkeypatch.delenv("VOICE_AGENT_CODEX_MODEL", raising=False)
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
    monkeypatch.delenv("VOICE_AGENT_CODEX_REASONING_EFFORT", raising=False)
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


def test_build_command_allows_per_run_reasoning_effort_override(monkeypatch) -> None:
    monkeypatch.setenv("VOICE_AGENT_SECURITY_MODE", "safe")
    monkeypatch.delenv("VOICE_AGENT_CODEX_UNRESTRICTED", raising=False)
    monkeypatch.setenv("VOICE_AGENT_CODEX_MODEL", "gpt-5.4")
    monkeypatch.setenv("VOICE_AGENT_CODEX_REASONING_EFFORT", "medium")
    executor = CodexExecutor(Path.cwd(), binary="codex", enable_web_search=False)

    command = executor._build_command(
        "Use the higher setting",
        model_override="gpt-5.4",
        reasoning_effort_override="xhigh",
    )

    assert command == [
        "codex",
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--model",
        "gpt-5.4",
        "-c",
        'model_reasoning_effort="xhigh"',
        "Use the higher setting",
    ]


def test_classify_resume_failure_detects_stale_codex_sessions() -> None:
    assert (
        CodexExecutor.classify_resume_failure(
            "Error: thread/resume: thread/resume failed: no rollout found for thread id stale-thread"
        )
        == "stale_session"
    )
    assert CodexExecutor.classify_resume_failure("unrelated output") is None
