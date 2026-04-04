# Stability And Product Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move MOBaiLE from a strong beta into a stable, trustworthy product by hardening the run lifecycle, making progress updates protocol-driven, improving recovery flows, expanding regression coverage, and adding a real release gate.

**Architecture:** Keep the current backend SSE and iOS conversation model, but make progress a first-class typed event stream instead of inferred assistant phrasing. Build the work in ordered slices: backend activity contract first, iOS consumption and recovery second, diagnostics and observability third, then release-hardening and real-device verification. Preserve compatibility with the current `/v1/runs/{run_id}/events` endpoint and existing stored data while incrementally upgrading both sides.

**Tech Stack:** FastAPI, Pydantic, Python 3.11+, SQLite-backed run/session state, SwiftUI, XCTest/XCUITest, GitHub Actions, existing `uv` and `xcodebuild` workflows.

---

## File Map

- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/models/schemas.py`
  Add additive typed activity metadata to execution events and diagnostics summaries.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/run_state.py`
  Centralize typed activity emission, activity summarization, and richer diagnostics.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/agent_run_service.py`
  Emit stable planning/executing/blocked/summarizing activity events instead of relying on prompt-shaped messages alone.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/execution_service.py`
  Align local and calendar execution paths with the same activity event taxonomy.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/main.py`
  Keep the SSE contract stable, expose richer diagnostics, and add a run-health summary endpoint if needed.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/agent_runtime.py`
  Keep guided prompt copy aligned with the typed event model rather than making it the source of truth.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/codex_text.py`
  Keep context-leak filtering aligned with prompt/runtime changes.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_run_state.py`
  Add backend contract coverage for typed progress events, diagnostics, and event-stream ordering.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_api.py`
  Cover SSE payloads, diagnostics responses, blocked/reconnect behavior, and compatibility.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_runtime_environment.py`
  Keep guided/minimal prompt coverage aligned with the new backend-driven activity model.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/Models.swift`
  Decode additive activity metadata on `ExecutionEvent` and any new diagnostics payload shape.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/APIClient.swift`
  Preserve SSE compatibility while decoding richer event payloads.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentViewModel.swift`
  Replace most heuristic progress projection with typed activity projection, improve blocked/reconnect/timeout recovery, and restore in-flight runs cleanly.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ChatThreadStore.swift`
  Persist richer run/lifecycle state needed for relaunch and recovery.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ContentView.swift`
  Promote guided recovery actions, tighten active-run chrome, and keep the main task path calm.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ChatScaffoldViews.swift`
  Keep Run Logs diagnostic-first, render blocked/reconnect affordances more clearly, and add release-safe operator surfaces.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentPreviewFixtures.swift`
  Add preview states for blocked, reconnect, timeout, and restored-in-flight runs.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceAgentModelTests.swift`
  Add coverage for typed activity decoding, recovery, and run restoration.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppUITests/VoiceAgentAppUITests.swift`
  Add UI coverage for blocked/reconnect states, logs view modes, and restored active runs.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/docs/IOS_RELEASE_AUTOMATION.md`
  Add a release gate and manual real-device validation checklist.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/.github/workflows/ios-tests.yml`
  Ensure simulator tests, xcresult artifacts, and failure artifacts are preserved.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/.github/workflows/backend-tests.yml`
  Keep backend contract tests mandatory for merge.

## Phase Order

1. Backend typed activity contract
2. iOS typed live activity and recovery
3. Relaunch/resume hardening
4. Diagnostics, observability, and CI gates
5. Real-device release gate and ship checklist

### Task 1: Introduce A Typed Backend Activity Event Contract

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/models/schemas.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/run_state.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_run_state.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_api.py`

- [ ] **Step 1: Write failing backend contract tests**

```python
def test_append_activity_event_emits_typed_metadata(run_state, stored_run_id):
    run_state.append_activity_event(
        stored_run_id,
        stage="planning",
        title="Planning",
        display_message="Reviewing the request and planning the next steps.",
    )

    run = run_state.get_run(stored_run_id)
    event = run.events[-1]
    assert event.type == "activity.updated"
    assert event.stage == "planning"
    assert event.title == "Planning"
    assert event.display_message == "Reviewing the request and planning the next steps."
    assert event.level == "info"


def test_stream_run_events_includes_typed_activity_payload(client, seeded_run_id):
    response = client.get(f"/v1/runs/{seeded_run_id}/events")
    assert response.status_code == 200
    assert '"type": "activity.updated"' in response.text
    assert '"stage": "executing"' in response.text
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_run_state.py tests/test_api.py -q`

Expected: FAIL because `ExecutionEvent` does not yet expose `stage`, `title`, `display_message`, `level`, or `activity.updated`.

- [ ] **Step 3: Add additive typed activity fields without breaking existing SSE consumers**

```python
class ExecutionEvent(BaseModel):
    seq: int | None = None
    type: Literal[
        "chat.message",
        "log.message",
        "action.started",
        "action.stdout",
        "action.stderr",
        "action.completed",
        "assistant.message",
        "activity.started",
        "activity.updated",
        "activity.completed",
        "run.completed",
        "run.failed",
        "run.blocked",
        "run.cancelled",
    ]
    action_index: int | None = None
    message: str
    stage: str | None = None
    title: str | None = None
    display_message: str | None = None
    level: Literal["info", "warning", "error"] | None = None
    event_id: str | None = None
    created_at: str | None = None
```

```python
def append_activity_event(
    self,
    run_id: str,
    *,
    stage: str,
    title: str,
    display_message: str,
    level: Literal["info", "warning", "error"] = "info",
    event_type: Literal["activity.started", "activity.updated", "activity.completed"] = "activity.updated",
) -> None:
    self.append_event(
        run_id,
        ExecutionEvent(
            type=event_type,
            message=display_message,
            stage=stage,
            title=title,
            display_message=display_message,
            level=level,
        ),
    )
```

- [ ] **Step 4: Extend diagnostics to summarize activity-stage coverage**

```python
class RunDiagnostics(BaseModel):
    ...
    activity_stage_counts: dict[str, int]
    latest_activity: str | None = None
```

```python
for event in run.events:
    if event.stage:
        activity_stage_counts[event.stage] = activity_stage_counts.get(event.stage, 0) + 1
        latest_activity = event.display_message or event.message
```

- [ ] **Step 5: Re-run the targeted backend contract tests**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_run_state.py tests/test_api.py -q`

Expected: PASS.

### Task 2: Make Agent And Local Execution Emit Stable Activity Stages

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/agent_run_service.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/execution_service.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/agent_runtime.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/codex_text.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_api.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_runtime_environment.py`

- [ ] **Step 1: Write failing tests for stage progression**

```python
def test_codex_run_emits_planning_executing_and_summarizing_activity_events(...):
    ...
    assert [event.stage for event in run.events if event.type.startswith("activity.")] == [
        "planning",
        "executing",
        "summarizing",
    ]


def test_blocked_run_emits_warning_activity_before_run_blocked(...):
    ...
    assert any(
        event.type == "activity.updated"
        and event.stage == "blocked"
        and event.level == "warning"
        for event in run.events
    )
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_api.py::test_codex_run_emits_planning_executing_and_summarizing_activity_events tests/test_api.py::test_blocked_run_emits_warning_activity_before_run_blocked tests/test_runtime_environment.py -q`

Expected: FAIL because the backend still relies on raw `action.started` / prompt-shaped assistant output.

- [ ] **Step 3: Emit activity stages from the backend runtime, not just prompt guidance**

```python
self.run_state.append_activity_event(
    run_id,
    stage="planning",
    title="Planning",
    display_message="Reviewing your request and planning the next steps.",
    event_type="activity.started",
)
```

```python
if event_type == "item.completed":
    self.run_state.append_activity_event(
        run_id,
        stage="executing",
        title="Executing",
        display_message="Running commands and applying changes.",
    )
```

```python
self.run_state.append_activity_event(
    run_id,
    stage="summarizing",
    title="Summarizing",
    display_message="Preparing the final result.",
)
```

```python
self.run_state.append_activity_event(
    run_id,
    stage="blocked",
    title="Needs Input",
    display_message=details,
    level="warning",
)
```

- [ ] **Step 4: Downgrade prompt guidance from source-of-truth to fallback polish**

Keep guided prompt instructions, but make them explicitly consistent with the typed activity contract. Preserve the context-leak filters in `codex_text.py`.

- [ ] **Step 5: Re-run the targeted tests**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_api.py tests/test_runtime_environment.py -q`

Expected: PASS.

### Task 3: Replace iOS Heuristic Progress Projection With Typed Activity Projection

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/Models.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/APIClient.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentViewModel.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceAgentModelTests.swift`

- [ ] **Step 1: Write failing iOS model and behavior tests**

```swift
func testExecutionEventDecodingSupportsTypedActivityFields() throws {
    let json = #"{"type":"activity.updated","message":"Running commands.","stage":"executing","title":"Executing","display_message":"Running commands.","level":"info"}"#
    let decoded = try JSONDecoder().decode(ExecutionEvent.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.type, "activity.updated")
    XCTAssertEqual(decoded.stage, "executing")
    XCTAssertEqual(decoded.title, "Executing")
    XCTAssertEqual(decoded.displayMessage, "Running commands.")
}

@MainActor
func testTypedActivityEventUpdatesLiveActivityCardWithoutAssistantBubble() {
    let vm = VoiceAgentViewModel()
    vm.createNewThread()
    let threadID = try! XCTUnwrap(vm.activeThreadID)
    vm._test_bindObservedRun(runID: "run-typed", threadID: threadID)

    vm._test_ingestRunEvents(
        [ExecutionEvent(type: "activity.updated", message: "Running commands.", stage: "executing", title: "Executing", displayMessage: "Running commands.", level: "info")],
        runID: "run-typed",
        threadID: threadID
    )

    XCTAssertEqual(vm.conversation.count, 1)
    XCTAssertEqual(vm.conversation.first?.presentation, .liveActivity)
    XCTAssertEqual(vm.conversation.first?.text, "Running commands.")
}
```

- [ ] **Step 2: Run the targeted iOS tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE && xcodebuild -project ios/VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:VoiceAgentAppTests/VoiceAgentModelTests`

Expected: FAIL because `ExecutionEvent` does not yet decode the additive activity fields and the view model still relies mostly on message heuristics.

- [ ] **Step 3: Make iOS consume typed activity fields first**

```swift
struct ExecutionEvent: Decodable, Identifiable {
    let seq: Int?
    let type: String
    let actionIndex: Int?
    let message: String
    let stage: String?
    let title: String?
    let displayMessage: String?
    let level: String?
    let eventID: String?
    let createdAt: String?
}
```

```swift
private func liveActivityText(for event: ExecutionEvent, threadID: UUID) -> String? {
    if event.type == "activity.started" || event.type == "activity.updated" || event.type == "activity.completed" {
        let text = event.displayMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : compactLiveActivityText(text)
    }
    switch event.type {
    case "chat.message", "assistant.message":
        return liveActivitySummary(from: event.message)
    case "action.started":
        return activityText(forActionEvent: event, threadID: threadID)
    default:
        return nil
    }
}
```

- [ ] **Step 4: Keep the heuristic path as a backward-compatible fallback**

Only use `liveActivitySummary(from:)` and `activityText(forActionEvent:)` when typed activity metadata is missing. Do not remove existing compatibility behavior in the same change.

- [ ] **Step 5: Re-run the targeted iOS tests**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE && xcodebuild -project ios/VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:VoiceAgentAppTests/VoiceAgentModelTests`

Expected: PASS.

### Task 4: Harden Blocked, Reconnect, Timeout, And Relaunch Recovery

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ChatThreadStore.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentViewModel.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ContentView.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ChatScaffoldViews.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentPreviewFixtures.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceAgentModelTests.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppUITests/VoiceAgentAppUITests.swift`

- [ ] **Step 1: Write failing recovery tests**

```swift
@MainActor
func testBlockedRunRestoresSuggestedReplyAfterRelaunch() {
    ...
    XCTAssertEqual(restored.pendingHumanUnblockRequest?.suggestedReply, "I completed the unblock step.")
}

@MainActor
func testInFlightRunRestoresLiveActivityAfterThreadReload() {
    ...
    XCTAssertEqual(restored.conversation.last?.presentation, .liveActivity)
}
```

```swift
func testReconnectPreviewShowsPrimaryRepairAction() {
    let app = launchApp(previewScenario: "repair")
    XCTAssertTrue(app.buttons["Scan QR Again"].waitForExistence(timeout: 5))
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE && xcodebuild -project ios/VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:VoiceAgentAppTests/VoiceAgentModelTests -only-testing:VoiceAgentAppUITests`

Expected: FAIL because blocked/reconnect/timeout recovery is only partially persisted and not fully surfaced as guided recovery states.

- [ ] **Step 3: Persist enough run lifecycle state to survive relaunch**

Keep the write scope limited to `ChatThreadStore.swift` and `VoiceAgentViewModel.swift`. Store:
- last active run ID
- latest activity text
- pending unblock request
- terminal failure/reconnect cause
- whether the live activity was still in-flight

- [ ] **Step 4: Make the UI present each failure class as one guided next step**

Implement the following iOS behavior:
- blocked: focused “Continue Run” flow with suggested reply
- reconnect: primary “Scan QR Again” action with quiet secondary details
- timeout: primary “Retry” action with diagnostics link
- restored in-flight run: revive the live activity card and resume polling/streaming if possible

- [ ] **Step 5: Re-run unit, UI, and preview-driven tests**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE && xcodebuild -project ios/VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test`

Expected: PASS with new blocked/reconnect/relaunch coverage.

### Task 5: Turn Run Logs Into A Stable Diagnostic Surface And Add Health Metrics

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/main.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/app/run_state.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ChatScaffoldViews.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend/tests/test_api.py`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppUITests/VoiceAgentAppUITests.swift`

- [ ] **Step 1: Add failing diagnostics tests**

```python
def test_run_diagnostics_includes_activity_stage_counts(client, seeded_run_id):
    response = client.get(f"/v1/runs/{seeded_run_id}/diagnostics")
    body = response.json()
    assert "activity_stage_counts" in body
    assert "latest_activity" in body
```

- [ ] **Step 2: Run the targeted diagnostics tests to verify they fail**

Run: `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_api.py::test_run_diagnostics_includes_activity_stage_counts -q`

Expected: FAIL because the diagnostics payload does not yet expose activity summaries.

- [ ] **Step 3: Expose health summaries that support the iOS diagnostics surface**

Additive backend output only:

```python
return RunDiagnostics(
    ...,
    activity_stage_counts=activity_stage_counts,
    latest_activity=latest_activity,
)
```

Then update the iOS logs sheet to show:
- current scope (`All` / `Highlights`)
- latest activity summary
- raw event count and last error when present

- [ ] **Step 4: Re-run diagnostics and iOS UI tests**

Run:
- `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest tests/test_api.py -q`
- `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE && xcodebuild -project ios/VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:VoiceAgentAppUITests`

Expected: PASS.

### Task 6: Add Release Gates, Real-Device Checks, And CI Artifact Preservation

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/docs/IOS_RELEASE_AUTOMATION.md`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/.github/workflows/ios-tests.yml`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/.github/workflows/backend-tests.yml`

- [ ] **Step 1: Document a concrete release gate**

Add a release section with this checklist:

```markdown
## Stable Release Gate

- backend tests green on `main`
- iOS unit and UI tests green on the release commit
- latest `xcresult` artifact attached and reviewed
- manual iPhone validation complete for:
  - fresh pairing
  - reconnect after expired pairing
  - first text run
  - first voice run
  - blocked run requiring user reply
  - network transition during active run
  - background/foreground during active run
- release notes updated with known limitations
```

- [ ] **Step 2: Preserve CI artifacts needed for debugging**

Update GitHub Actions so failures keep:
- backend pytest output
- `xcresult`
- simulator screenshots or logs where feasible

- [ ] **Step 3: Re-run CI-equivalent commands locally**

Run:
- `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/backend && uv run pytest -q`
- `cd /Users/vemundss/Library/Mobile\ Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE && xcodebuild -project ios/VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test`

Expected: PASS with no workflow drift.

## Release Criteria

Do not call the app “stable” until all of the following are true:

- typed backend activity events are shipped and consumed by iOS
- blocked/reconnect/timeout states have one obvious recovery action each
- active runs survive relaunch without losing thread context
- Run Logs is clearly diagnostic, not required for normal use
- backend and iOS suites are green on the release commit
- a manual real-device matrix is completed on at least one current iPhone

## Suggested Commit Boundaries

1. `feat: add typed backend activity events`
2. `feat: project typed activity into iOS live feedback`
3. `feat: harden blocked reconnect and relaunch recovery`
4. `feat: enrich diagnostics and logs surface`
5. `chore: add stable release gate and CI artifacts`
