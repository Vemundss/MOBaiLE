# Voice Thread Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the new voice/thread interaction model so one-shot voice stays lightweight, voice mode stays bound to one thread, passive thread switches end the loop without cancelling work, and AirPods/shortcuts resume the last valid voice thread instead of guessing.

**Architecture:** Keep the existing SwiftUI + `VoiceAgentViewModel` structure, but move the resume-target decision into a small pure helper so the thread-routing policy is testable without the recorder. Wire that helper back into `VoiceAgentViewModel` for persisted last-thread state, external resume entrypoints, and thread-switch interruption rules, then surface the distinction between one-shot voice and persistent voice mode in the UI and user-facing copy.

**Tech Stack:** Swift 5, SwiftUI, App Intents, `UserDefaults`, local SQLite thread persistence, XCTest, `xcodebuild`.

---

## File Map

- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceThreadResumeResolver.swift`
  Pure target-selection logic for external voice resume actions.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentViewModel.swift`
  Persist the last voice-mode thread, route AirPods/shortcut resume through the resolver, preserve the last voice thread on navigation, and publish a transient “voice mode ended” notice.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ContentView.swift`
  Make one-shot voice and persistent voice mode feel distinct in the composer and surface the transient voice notice.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/MOBaiLEShortcuts.swift`
  Clarify external shortcut semantics around resuming the last valid voice-mode thread.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/Models.swift`
  Keep slash-command/app-side copy aligned if any voice entry labels or descriptions need to change.
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceThreadResumeResolverTests.swift`
  Focused unit tests for target-selection priority and deleted-thread fallback.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceAgentModelTests.swift`
  Add regression coverage for persisted last-thread state, resume preparation, and the voice-ended notice.
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/README.md`
  Document the updated hands-free behavior in the iPhone app operator docs.

## Phase Order

1. Pure resume-target policy
2. View-model state and resume behavior
3. UI/copy polish, docs, and end-to-end iOS verification

### Task 1: Add A Pure Resume-Target Resolver

**Files:**
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceThreadResumeResolver.swift`
- Create: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceThreadResumeResolverTests.swift`

- [ ] **Step 1: Write the failing resolver tests**

```swift
import XCTest
@testable import VoiceAgentApp

final class VoiceThreadResumeResolverTests: XCTestCase {
    func testResolverPrefersActiveVoiceModeThread() {
        let active = UUID()
        let last = UUID()
        let current = UUID()

        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: active,
            lastVoiceModeThreadID: last,
            currentThreadID: current,
            existingThreadIDs: [active, last, current]
        )

        XCTAssertEqual(resolved, .existing(active))
    }

    func testResolverFallsBackToLastVoiceModeThreadBeforeCurrentThread() {
        let last = UUID()
        let current = UUID()

        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: nil,
            lastVoiceModeThreadID: last,
            currentThreadID: current,
            existingThreadIDs: [last, current]
        )

        XCTAssertEqual(resolved, .existing(last))
    }

    func testResolverIgnoresDeletedStoredThreads() {
        let deleted = UUID()
        let current = UUID()

        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: nil,
            lastVoiceModeThreadID: deleted,
            currentThreadID: current,
            existingThreadIDs: [current]
        )

        XCTAssertEqual(resolved, .existing(current))
    }

    func testResolverRequestsNewThreadWhenNothingReusableExists() {
        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: nil,
            lastVoiceModeThreadID: nil,
            currentThreadID: nil,
            existingThreadIDs: []
        )

        XCTAssertEqual(resolved, .createNewThread)
    }
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' \
-only-testing:VoiceAgentAppTests/VoiceThreadResumeResolverTests test
```

Expected: FAIL because `VoiceThreadResumeResolver` and `VoiceThreadResumeTarget` do not exist yet.

- [ ] **Step 3: Implement the minimal pure resolver**

```swift
import Foundation

enum VoiceThreadResumeTarget: Equatable {
    case existing(UUID)
    case createNewThread
}

enum VoiceThreadResumeResolver {
    static func resolve(
        activeVoiceModeThreadID: UUID?,
        lastVoiceModeThreadID: UUID?,
        currentThreadID: UUID?,
        existingThreadIDs: Set<UUID>
    ) -> VoiceThreadResumeTarget {
        if let activeVoiceModeThreadID, existingThreadIDs.contains(activeVoiceModeThreadID) {
            return .existing(activeVoiceModeThreadID)
        }
        if let lastVoiceModeThreadID, existingThreadIDs.contains(lastVoiceModeThreadID) {
            return .existing(lastVoiceModeThreadID)
        }
        if let currentThreadID, existingThreadIDs.contains(currentThreadID) {
            return .existing(currentThreadID)
        }
        return .createNewThread
    }
}
```

- [ ] **Step 4: Re-run the resolver tests**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' \
-only-testing:VoiceAgentAppTests/VoiceThreadResumeResolverTests test
```

Expected: PASS.

- [ ] **Step 5: Commit the resolver slice**

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE" && \
git add ios/VoiceAgentApp/VoiceThreadResumeResolver.swift ios/VoiceAgentAppTests/VoiceThreadResumeResolverTests.swift && \
git commit -m "Add voice thread resume resolver"
```

### Task 2: Persist The Last Voice Thread And Route External Resume Through The View Model

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentViewModel.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceAgentModelTests.swift`

- [ ] **Step 1: Write failing regression tests for persisted last-thread state and resume preparation**

```swift
@MainActor
func testSwitchingThreadsKeepsLastVoiceModeThreadForExternalResume() {
    let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
    defer { cleanup() }

    let vm = VoiceAgentViewModel(
        threadStore: store,
        defaults: defaults,
        draftAttachmentDirectory: draftDirectory
    )
    let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
    vm.createNewThread()
    let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

    vm.switchToThread(firstThreadID)
    vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
    vm.switchToThread(secondThreadID)

    XCTAssertFalse(vm.voiceModeEnabled)
    XCTAssertEqual(vm._test_lastVoiceModeThreadID(), firstThreadID)
    XCTAssertEqual(vm._test_prepareExternalVoiceResumeTarget(), .existing(firstThreadID))
}

@MainActor
func testDeletingStoredVoiceThreadFallsBackToCurrentThread() {
    let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
    defer { cleanup() }

    let vm = VoiceAgentViewModel(
        threadStore: store,
        defaults: defaults,
        draftAttachmentDirectory: draftDirectory
    )
    let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
    vm.createNewThread()
    let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

    vm.switchToThread(firstThreadID)
    vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
    vm.switchToThread(secondThreadID)
    vm.deleteThread(firstThreadID)

    XCTAssertEqual(vm._test_prepareExternalVoiceResumeTarget(), .existing(secondThreadID))
}

@MainActor
func testLastVoiceModeThreadPersistsAcrossReload() {
    let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
    defer { cleanup() }

    let vm = VoiceAgentViewModel(
        threadStore: store,
        defaults: defaults,
        draftAttachmentDirectory: draftDirectory
    )
    let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
    vm.createNewThread()
    let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

    vm.switchToThread(firstThreadID)
    vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
    vm.switchToThread(secondThreadID)

    let reloaded = VoiceAgentViewModel(
        threadStore: store,
        defaults: defaults,
        draftAttachmentDirectory: draftDirectory
    )

    XCTAssertEqual(reloaded._test_lastVoiceModeThreadID(), firstThreadID)
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testSwitchingThreadsKeepsLastVoiceModeThreadForExternalResume \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testDeletingStoredVoiceThreadFallsBackToCurrentThread \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testLastVoiceModeThreadPersistsAcrossReload test
```

Expected: FAIL because the view model does not persist `lastVoiceModeThreadID`, does not expose resume-target preparation, and clears too much voice state on navigation.

- [ ] **Step 3: Add persisted last-thread state and pure resume preparation**

```swift
private var lastVoiceModeThreadID: UUID?

private enum DefaultsKey {
    ...
    static let lastVoiceModeThreadID = "mobaile.last_voice_mode_thread_id"
}

private func rememberLastVoiceModeThread(_ threadID: UUID?) {
    lastVoiceModeThreadID = threadID
    if let threadID {
        defaults.set(threadID.uuidString, forKey: DefaultsKey.lastVoiceModeThreadID)
    } else {
        defaults.removeObject(forKey: DefaultsKey.lastVoiceModeThreadID)
    }
}

private func restoreLastVoiceModeThreadIfPossible() {
    let raw = defaults.string(forKey: DefaultsKey.lastVoiceModeThreadID)?.trimmingCharacters(
        in: .whitespacesAndNewlines
    ) ?? ""
    guard let threadID = UUID(uuidString: raw), threads.contains(where: { $0.id == threadID }) else {
        rememberLastVoiceModeThread(nil)
        return
    }
    lastVoiceModeThreadID = threadID
}

private func loadThreads() {
    ...
    restoreLastVoiceModeThreadIfPossible()
}

@discardableResult
private func prepareExternalVoiceResumeTarget() -> VoiceThreadResumeTarget {
    let resolved = VoiceThreadResumeResolver.resolve(
        activeVoiceModeThreadID: voiceModeThreadID,
        lastVoiceModeThreadID: lastVoiceModeThreadID,
        currentThreadID: activeThreadID,
        existingThreadIDs: Set(threads.map(\.id))
    )
    switch resolved {
    case let .existing(threadID):
        if activeThreadID != threadID {
            switchToThread(threadID)
        }
        return .existing(threadID)
    case .createNewThread:
        startNewChat()
        guard let activeThreadID else { return .createNewThread }
        return .existing(activeThreadID)
    }
}
```

```swift
private func beginVoiceMode() async {
    ...
    voiceModeEnabled = true
    voiceModeThreadID = activeThreadID
    rememberLastVoiceModeThread(activeThreadID)
    ...
}

private func deactivateVoiceMode(stopSpeaking: Bool) {
    if let voiceModeThreadID {
        rememberLastVoiceModeThread(voiceModeThreadID)
    }
    voiceModeEnabled = false
    voiceModeThreadID = nil
    shouldResumeVoiceModeAfterSpeech = false
    isSpeakingReply = false
    if stopSpeaking, speaker.isSpeaking {
        speaker.stopSpeaking(at: .immediate)
    }
}

func handleStartVoiceTaskShortcut() async {
    guard !isRecording && !isLoading else { return }
    _ = prepareExternalVoiceResumeTarget()
    await startVoiceModeIfNeeded()
}

func toggleRecordingFromHeadsetControl() async {
    guard airPodsClickToRecordEnabled else { return }
    ...
    if isRecording {
        await stopRecordingAndSend()
    } else if !isLoading {
        _ = prepareExternalVoiceResumeTarget()
        await startVoiceModeIfNeeded()
    }
}

func deleteThread(_ threadID: UUID) {
    if lastVoiceModeThreadID == threadID {
        rememberLastVoiceModeThread(nil)
    }
    ...
}
```

```swift
func _test_lastVoiceModeThreadID() -> UUID? {
    lastVoiceModeThreadID
}

func _test_prepareExternalVoiceResumeTarget() -> VoiceThreadResumeTarget {
    prepareExternalVoiceResumeTarget()
}
```

- [ ] **Step 4: Re-run the targeted regression tests**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testSwitchingThreadsKeepsLastVoiceModeThreadForExternalResume \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testDeletingStoredVoiceThreadFallsBackToCurrentThread \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testLastVoiceModeThreadPersistsAcrossReload test
```

Expected: PASS.

- [ ] **Step 5: Commit the view-model behavior slice**

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE" && \
git add ios/VoiceAgentApp/VoiceAgentViewModel.swift ios/VoiceAgentAppTests/VoiceAgentModelTests.swift && \
git commit -m "Persist and resume the last voice thread"
```

### Task 3: Surface Explicit One-Shot Versus Voice-Mode UI, Update Docs, And Verify The iOS Flow

**Files:**
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/VoiceAgentViewModel.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/ContentView.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/MOBaiLEShortcuts.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentApp/Models.swift`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/README.md`
- Modify: `/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios/VoiceAgentAppTests/VoiceAgentModelTests.swift`

- [ ] **Step 1: Write the failing notice regression test**

```swift
@MainActor
func testSwitchingThreadsPublishesVoiceModeEndedNotice() {
    let vm = VoiceAgentViewModel()
    let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
    vm.createNewThread()
    let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

    vm.switchToThread(firstThreadID)
    vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
    vm.switchToThread(secondThreadID)

    XCTAssertEqual(vm._test_voiceInteractionNoticeText(), "Voice mode ended")
}
```

- [ ] **Step 2: Run the targeted notice test to verify it fails**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testSwitchingThreadsPublishesVoiceModeEndedNotice test
```

Expected: FAIL because there is no transient notice state yet.

- [ ] **Step 3: Add the transient notice plus explicit copy updates**

```swift
@Published private(set) var voiceInteractionNoticeText: String?
private var voiceInteractionNoticeTask: Task<Void, Never>?

private func showVoiceInteractionNotice(_ text: String) {
    voiceInteractionNoticeTask?.cancel()
    voiceInteractionNoticeText = text
    voiceInteractionNoticeTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        self.voiceInteractionNoticeText = nil
    }
}

func _test_voiceInteractionNoticeText() -> String? {
    voiceInteractionNoticeText
}
```

```swift
func switchToThread(_ threadID: UUID) {
    guard let idx = threadIndex(for: threadID) else { return }
    if voiceModeEnabled, voiceModeThreadID != threadID {
        deactivateVoiceMode(stopSpeaking: true)
        showVoiceInteractionNotice("Voice mode ended")
    }
    ...
}
```

```swift
if let notice = vm.voiceInteractionNoticeText, !notice.isEmpty {
    ComposerMetaPill(
        text: notice,
        systemImage: "waveform.badge.exclamationmark",
        tint: .secondary
    )
}
```

```swift
Button("Record Voice Prompt") {
    composerFocused = false
    handleRecordingButtonTap()
}

private var recordingSubtitle: String {
    if vm.isVoiceModeActiveForCurrentThread {
        return "Pause to send automatically. Voice mode resumes on this thread after the reply."
    }
    if vm.usesAutoSendForCurrentTurn {
        return "Pause to send this prompt automatically."
    }
    return "Tap send to send this prompt once."
}
```

```swift
struct StartVoiceTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Voice Mode"
    static var description = IntentDescription(
        "Open MOBaiLE and resume voice mode on the active or last voice thread."
    )
    ...
}
```

```swift
        .local(
            .voiceNew,
            title: "Start New Voice Thread",
            description: "Create a fresh thread and start voice mode there.",
            symbol: "waveform.badge.plus",
            usage: "/voice-new",
            group: "Session",
            aliases: ["newvoice", "voice-thread"]
        ),
        .local(
            .voice,
            title: "Start Voice Mode",
            description: "Start voice mode on the current thread and keep listening after each reply.",
            symbol: "mic",
            usage: "/voice",
            group: "Input",
            aliases: ["record", "mic"]
        ),
```

```swift
## Features Worth Turning On

- **Voice mode:** starts a hands-free loop on one thread at a time. If you switch chats, the loop ends, but any run already in progress keeps going.
- **Siri and Shortcuts:** `Resume Voice Mode` reopens the active or last voice thread; `Start New Voice Thread` always creates a fresh thread first.
```

- [ ] **Step 4: Re-run the targeted notice test**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testSwitchingThreadsPublishesVoiceModeEndedNotice test
```

Expected: PASS.

- [ ] **Step 5: Run the focused voice interaction test set**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' \
-only-testing:VoiceAgentAppTests/VoiceThreadResumeResolverTests \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testSwitchingThreadsDisablesVoiceModeLoop \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testSwitchingThreadsKeepsLastVoiceModeThreadForExternalResume \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testDeletingStoredVoiceThreadFallsBackToCurrentThread \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testLastVoiceModeThreadPersistsAcrossReload \
-only-testing:VoiceAgentAppTests/VoiceAgentModelTests/testSwitchingThreadsPublishesVoiceModeEndedNotice test
```

Expected: PASS.

- [ ] **Step 6: Run the full iOS unit and UI test suite**

Run:

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE/ios" && \
xcodebuild -project VoiceAgentApp.xcodeproj -scheme VoiceAgentApp -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Perform simulator UI verification and capture fresh screenshots**

Open the project in Xcode or launch the app in Simulator, then verify these exact states before handoff:

- active voice mode on an existing thread
- thread switch that shows the `Voice mode ended` notice
- shortcut or AirPods resume returning to the last valid voice thread

Capture fresh screenshots of the active voice-mode state and the post-navigation notice state.

- [ ] **Step 8: Commit the UI, shortcut, and docs slice**

```bash
cd "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE" && \
git add ios/VoiceAgentApp/VoiceAgentViewModel.swift ios/VoiceAgentApp/ContentView.swift ios/VoiceAgentApp/MOBaiLEShortcuts.swift ios/VoiceAgentApp/Models.swift ios/README.md ios/VoiceAgentAppTests/VoiceAgentModelTests.swift && \
git commit -m "Clarify voice mode resume behavior"
```

## Self-Review

### Spec Coverage

- One-shot voice stays separate from persistent voice mode: covered in Task 3 copy and UI changes.
- Voice mode binds to a single thread: covered in Task 2 persistence and resume wiring.
- Passive thread switches end the loop without cancelling runs: covered in Task 2 regression tests and Task 3 notice behavior.
- AirPods and shortcuts resume the last valid voice thread: covered in Task 1 resolver and Task 2 external resume wiring.
- Deleted-thread fallback and repair-safe behavior: covered in Task 1 fallback rules and Task 2 deletion regression test.

### Placeholder Scan

- No `TODO`, `TBD`, or “implement later” markers remain.
- Each code-writing step contains concrete code and each verification step contains an exact command or explicit manual check.

### Type Consistency

- `VoiceThreadResumeTarget` and `VoiceThreadResumeResolver` are introduced in Task 1 and reused with the same names in Tasks 2 and 3.
- `lastVoiceModeThreadID`, `prepareExternalVoiceResumeTarget()`, and `voiceInteractionNoticeText` are introduced once and referenced consistently afterward.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-15-voice-thread-interaction-implementation.md`. Two execution options:

1. Subagent-Driven (recommended) - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
