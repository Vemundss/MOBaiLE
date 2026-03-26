from app.models.schemas import Action, ActionPlan


def plan_from_utterance(utterance_text: str) -> ActionPlan:
    text = utterance_text.lower()

    if "hello" in text and "python" in text:
        return ActionPlan(
            goal="Create and run a hello world python file",
            actions=[
                Action(
                    type="write_file",
                    path="hello.py",
                    content="print('hello from voice agent')\n",
                ),
                Action(
                    type="run_command",
                    command="python3 hello.py",
                ),
            ],
        )

    return ActionPlan(
        goal="Echo utterance for connectivity check",
        actions=[
            Action(
                type="run_command",
                command=f"python3 -c \"print('received:', {utterance_text!r})\"",
            )
        ],
    )
