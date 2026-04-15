# MOBaiLE Voice And Thread Interaction Design

Date: 2026-04-15

## Summary

MOBaiLE should support both glanceable control-surface use and true hands-free use without splitting into two different products.

The chosen direction is:

- keep one-shot voice input as a lightweight action on the current thread
- define `Voice Mode` as a persistent loop bound to one specific thread
- end the voice loop when the user passively navigates to another thread
- rebind the loop only after an explicit voice action on the new thread
- let AirPods and shortcuts resume the last bound voice thread instead of guessing or creating a new one

This keeps the voice target stable while preserving the screen-first thread model.

## Problem

The app currently supports text threads, one-shot voice capture, persistent voice behavior, chat switching, and shortcut entrypoints. Without an explicit interaction contract, those features can pull against each other:

- one-shot voice and persistent voice can feel like the same thing when they are not
- switching threads can silently change where headset input goes
- hands-free entrypoints can accidentally create new chats when the user expected to resume an existing one
- voice controls can look global while their effects are actually thread-specific

The result is avoidable confusion in exactly the product area where MOBaiLE needs to feel most trustworthy: away-from-the-desk control.

## Goals

- Support both quick screen-first voice capture and persistent hands-free conversation.
- Keep the target thread explicit and predictable for every voice action.
- Avoid silent retargeting when the user browses between chats.
- Preserve thread continuity for AirPods, shortcuts, repeat, and retry.
- Keep thread navigation and run execution separate from the voice loop.
- Make the UI feedback strong enough that the current voice state is obvious at a glance.

## Non-Goals

- Add multi-click AirPods gestures in this phase.
- Turn voice mode into a background multi-thread queue manager.
- Redesign the full chat layout or top bar in this document.
- Define backend transport or speech-engine implementation details here.
- Change run cancellation semantics beyond voice-loop behavior.

## Terms

- `current thread`: the thread currently visible on screen
- `voice-mode thread`: the thread currently bound to persistent voice mode
- `last voice-mode thread`: the most recent thread that had persistent voice mode, even if voice mode is no longer active
- `one-shot voice`: a single recorded prompt that sends once and ends
- `voice mode`: the loop of record -> send -> wait -> speak reply -> reopen mic
- `voice loop`: the automatic continuation behavior associated with voice mode

Use these terms consistently in UI copy, tests, and implementation docs.

## Approaches Considered

### 1. Treat all voice capture as one-shot input

Voice is only an input method. The app never treats a thread as being in a persistent voice state.

Pros:

- simplest mental model on paper
- least persistent UI state to display

Cons:

- poor fit for real hands-free use
- headset and shortcut resume behavior becomes ambiguous
- hard to preserve a stable conversation target while away from the screen

### 2. Treat voice mode as global app state

Voice mode exists at the app level and follows whichever thread is currently visible.

Pros:

- simple to describe in UI
- easier to make the mic feel omnipresent

Cons:

- plain thread switches can silently retarget voice input
- too risky for AirPods and background resume
- weakens the thread model instead of respecting it

### 3. Use thread-bound persistent voice mode plus explicit one-shot voice

One-shot voice remains lightweight, but persistent voice mode belongs to a single thread until the user explicitly stops it or intentionally starts it elsewhere.

Pros:

- best fit for true hands-free use
- preserves a stable target for resume, repeat, and retry
- keeps thread navigation explicit instead of magical

Cons:

- requires clearer voice-state UI
- needs explicit interruption rules for thread switching

## Chosen Direction

Build approach 3.

MOBaiLE should expose two voice behaviors with distinct intent:

- `Send Voice Prompt`: one-shot voice input into the current thread
- `Start Voice Mode`: persistent thread-bound voice loop

The app should never silently transfer an active voice loop to another thread just because the user viewed that thread. Passive navigation ends the loop. Explicit voice actions start or resume it.

## Core Interaction Rules

### One-shot voice

- `Send Voice Prompt` records one turn into the current thread.
- After the prompt is sent, the one-shot action ends.
- Reply speech may still occur if spoken replies are enabled.
- The mic does not reopen automatically unless the user explicitly started `Voice Mode`.

### Voice mode

- `Start Voice Mode` binds the voice loop to the current thread.
- If no thread exists yet, the app creates a new thread and binds voice mode to it.
- While bound, automatic resume behavior targets that thread only.
- `Voice Mode` remains active until the user explicitly ends it or a navigation/interruption rule ends it.

### Resume behavior

- If voice mode is already active, headset and shortcut resume actions reopen the current voice-mode thread.
- If voice mode is inactive but a last voice-mode thread exists, resume actions reopen that thread and start voice mode there.
- If no last voice-mode thread exists, resume actions use the current thread if one is available.
- If there is no usable current thread, the app creates a new thread and starts voice mode there.

### Thread switching

- Switching from thread A to thread B ends the voice loop on thread A.
- Switching threads does not cancel any in-flight run on thread A.
- Voice mode is not transferred to thread B automatically.
- If the user explicitly taps `Start Voice Mode` or triggers an equivalent action on B, the loop binds to B.

## State Model

The interaction model should be understandable as these states:

- `Idle`
- `Recording one-shot`
- `Voice mode active on thread X`
- `Waiting for reply on thread X`
- `Speaking reply on thread X`
- `Voice mode ended, last thread = X`

The implementation may use more internal states, but the user-facing behavior should map cleanly to this set.

## Primary Flows

### Flow 1. One-shot voice from the current thread

1. User is viewing thread A.
2. User triggers `Send Voice Prompt`.
3. App records and sends a single prompt into A.
4. App waits for the run to complete.
5. App may speak the reply if spoken replies are enabled.
6. App returns to idle. No automatic mic reopen occurs.

### Flow 2. Start voice mode on the current thread

1. User is viewing thread A.
2. User triggers `Start Voice Mode`.
3. App binds voice mode to A and begins recording.
4. Each completed reply is spoken if enabled.
5. After speech finishes, the mic reopens automatically for A.
6. This loop continues until ended by user intent or interruption rules.

### Flow 3. Resume voice mode from AirPods or shortcut

1. User triggers a resume action while the app is backgrounded or not actively focused on a thread.
2. App resolves the target in this order:
   1. active voice-mode thread
   2. last voice-mode thread
   3. current thread
   4. new thread
3. App visibly navigates to the resolved thread.
4. App starts voice mode there and begins recording.

### Flow 4. Navigate away from an active voice-mode thread

1. Voice mode is active on thread A.
2. User opens thread B through normal navigation.
3. App ends the voice loop on A.
4. Any run already executing on A keeps running.
5. Reply speech associated with the active voice loop stops.
6. Thread B becomes the normal current thread with no active voice mode.

### Flow 5. Intentionally move voice mode to another thread

1. Voice mode was previously active on thread A and has ended due to navigation or explicit stop.
2. User views thread B.
3. User explicitly triggers `Start Voice Mode`.
4. App binds voice mode to B.
5. B becomes both the current thread and the voice-mode thread.

## Edge Cases

### Switch threads while recording

- The app stops recording immediately.
- The unfinished capture is discarded.
- No partial prompt is sent.
- Voice mode ends as part of the thread switch.

### Switch threads while assistant speech is playing

- Speech stops immediately.
- Auto-resume is cancelled.
- The run on the old thread continues if it is still executing.

### Switch threads while waiting for a reply

- The voice loop ends.
- The pending run continues on the original thread.
- Completion on the old thread updates that thread’s history and status, but does not reopen the mic.

### Delete the voice-mode thread

- Voice mode ends immediately.
- The binding and last-bound reference are cleared unless another sensible voice thread is selected by the product in a later phase.
- If the deleted thread was current, normal thread deletion fallback rules apply.

### Resume after the last voice-mode thread was deleted

- Resume falls back to the current thread if one exists.
- Otherwise a new thread is created.
- The app should not fail silently or reference the deleted thread in UI copy.

### Backend needs repair

- Voice start or resume does not begin recording.
- The user receives clear repair messaging.
- No hidden fallback to another thread or offline placeholder behavior occurs.

## Event Table

| Event | Starting State | Result |
| --- | --- | --- |
| User taps `Send Voice Prompt` | idle on thread A | record one turn on A, send, wait for reply, do not auto-reopen mic |
| User taps `Start Voice Mode` | idle on thread A | bind voice mode to A and begin persistent voice loop |
| User switches from thread A to thread B | voice mode active on A | end voice loop on A, stop recording or reply speech if present, keep any run on A alive, show B with no active voice mode |
| User taps `Start Voice Mode` on thread B after leaving A | idle on B, last voice-mode thread = A | bind voice mode to B and start recording on B |
| AirPods or shortcut resume fires | idle, last voice-mode thread = A | navigate to A and start voice mode there |
| AirPods or shortcut resume fires after A was deleted | idle, no valid last voice-mode thread | fall back to current thread or create a new thread, then start voice mode |
| User manually ends voice mode while waiting for a reply | waiting for reply on A | keep run alive on A, cancel auto-resume, allow reply history to land normally |
| User manually ends voice mode while assistant speech is playing | speaking reply on A | stop speech, cancel auto-resume, keep thread and run state intact |

## UI Feedback

### Entry points

The UI should distinguish:

- `Send Voice Prompt`
- `Start Voice Mode`

These should not share copy that implies the same persistence semantics.

### Voice state visibility

When voice mode is active, the app should show a clear thread-scoped state such as:

- `Voice mode on`
- `Listening`
- `Replying`
- `Speaking`

When voice mode ends because of navigation, the user should briefly see a confirmation state such as:

- `Voice mode ended`

### Resume visibility

If an AirPods or shortcut action resumes a non-visible thread, the app should visibly navigate to that thread before recording starts. The user should not need to infer the target thread after the fact.

### Feedback cues

Audio and haptic cues should distinguish:

- recording started
- prompt sent
- reply speaking
- voice mode ended
- resume failed

The cues do not need to be dramatic, but they should be distinguishable enough for hands-free use.

## Data And State Expectations

- The app should persist enough local state to identify the last voice-mode thread across normal app lifecycle transitions.
- Ending voice mode must be separate from cancelling a run.
- The current thread and the last voice-mode thread may differ.
- The voice-mode thread and current thread may differ only briefly during resume/navigation transitions; the app should converge quickly to one visible target.

## Testing Guidance

The implementation plan should cover at least these scenarios:

- one-shot voice does not reopen the mic
- voice mode resumes on the same thread after a completed reply
- switching threads ends the loop without cancelling the run
- explicit voice start on another thread rebinds the loop
- AirPods or shortcut resume targets the last bound thread
- deleted-thread fallback does not produce broken resume behavior
- repair-state failures do not start recording

## Open Questions Deferred

These questions are intentionally deferred so they do not block the core interaction model:

- whether the top bar should show a persistent thread badge for the last voice-mode thread
- whether repeat-last-reply should be available outside voice mode
- whether multi-click AirPods gestures are worth the discoverability cost
- how much of the voice-state feedback should be visible from widgets or Live Activities

## Acceptance Criteria

This design is successful when:

- the user can always tell which thread voice input will target
- passive navigation never silently transfers the voice loop
- headset and shortcut resume behave predictably without spawning unexpected new threads
- thread switching does not cancel work already running
- one-shot voice and persistent voice mode feel clearly different in both UI and behavior
