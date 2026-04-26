import Foundation

enum PreviewScenario: String {
    case configuredEmpty = "configured-empty"
    case conversation = "conversation"
    case liveActivity = "live-activity"
    case blocked = "blocked"
    case recording = "recording"
    case repair = "repair"
    case timeout = "timeout"
    case restoredRunning = "restored-running"
    case media = "media"

    static var current: PreviewScenario? {
        let processInfo = ProcessInfo.processInfo

        if let raw = processInfo.environment["MOBAILE_PREVIEW_SCENARIO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let scenario = PreviewScenario(rawValue: raw) {
            return scenario
        }

        for argument in processInfo.arguments {
            guard argument.hasPrefix("--mobaile-preview-scenario=") else { continue }
            let raw = String(argument.dropFirst("--mobaile-preview-scenario=".count)).lowercased()
            if let scenario = PreviewScenario(rawValue: raw) {
                return scenario
            }
        }

        return nil
    }
}

struct VoiceAgentPreviewData {
    let workspace: String
    let activeThreadID: UUID
    let threads: [ChatThread]
    let executors: [RuntimeExecutorDescriptor]
    let codexModelOptions: [String]
    let codexReasoningEffort: String
    let codexReasoningEffortOptions: [String]
    let claudeModelOptions: [String]
    let slashCommands: [ComposerSlashCommand]
    let events: [ExecutionEvent]
    let conversation: [ConversationMessage]
    let promptText: String
    let draftAttachments: [DraftAttachment]
    let runID: String
    let summaryText: String
    let transcriptText: String
    let statusText: String
    let runPhaseText: String
    let runStartedAt: Date?
    let runEndedAt: Date?
    let isLoading: Bool
    let isRecording: Bool
    let recordingStartedAt: Date?
    let didCompleteRun: Bool
    let voiceModeEnabled: Bool
    let voiceModeThreadID: UUID?
    let connectionRepairState: VoiceAgentViewModel.ConnectionRepairState?
    let autoSendAfterSilenceEnabled: Bool?
}

enum VoiceAgentPreviewFactory {
    static func make(
        scenario: PreviewScenario,
        draftAttachmentDirectory: URL,
        codexReasoningEffortOptions: [String]
    ) -> VoiceAgentPreviewData {
        let previewPresentation = ProcessInfo.processInfo.environment["MOBAILE_PREVIEW_PRESENTATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let workspace = "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE"
        let now = Date()
        let primaryThreadID = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
        let captureThreadID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        let draftThreadID = UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID()

        var previewThreads = [
            ChatThread(
                id: primaryThreadID,
                title: "Run smoke test",
                updatedAt: now,
                conversation: [],
                runID: "pvw-2048",
                summaryText: "Summarized the current repo status and the next release step from the phone.",
                transcriptText: "",
                statusText: "Completed",
                resolvedWorkingDirectory: workspace,
                activeRunExecutor: "codex"
            ),
            ChatThread(
                id: captureThreadID,
                title: "Review repo changes",
                updatedAt: now.addingTimeInterval(-4200),
                conversation: [],
                runID: "pvw-1987",
                summaryText: "Compared the latest workspace changes and kept the release context in one thread.",
                transcriptText: "",
                statusText: "Completed",
                resolvedWorkingDirectory: workspace,
                activeRunExecutor: "codex"
            ),
            ChatThread(
                id: draftThreadID,
                title: "Dictate the next task",
                updatedAt: now.addingTimeInterval(-8600),
                conversation: [],
                runID: "",
                summaryText: "",
                transcriptText: "",
                statusText: "Draft",
                resolvedWorkingDirectory: workspace,
                activeRunExecutor: "codex",
                draftText: "open the workspace browser and switch to ios/VoiceAgentApp",
                draftAttachments: []
            ),
            ChatThread(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID(),
                title: "Summarize backend logs",
                updatedAt: now.addingTimeInterval(-12400),
                conversation: [],
                runID: "pvw-1820",
                summaryText: "Collected the recent backend output and condensed it into a quick status summary.",
                transcriptText: "",
                statusText: "Completed",
                resolvedWorkingDirectory: workspace,
                activeRunExecutor: "codex"
            ),
            ChatThread(
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555") ?? UUID(),
                title: "Voice follow-up",
                updatedAt: now.addingTimeInterval(-18800),
                conversation: [],
                runID: "pvw-1742",
                summaryText: "Captured a hands-free task and kept the repo thread ready for the next run.",
                transcriptText: "",
                statusText: "Completed",
                resolvedWorkingDirectory: workspace,
                activeRunExecutor: "codex"
            ),
        ]

        if scenario == .configuredEmpty,
           let primaryIndex = previewThreads.firstIndex(where: { $0.id == primaryThreadID }) {
            previewThreads[primaryIndex].title = "New Chat"
            previewThreads[primaryIndex].runID = ""
            previewThreads[primaryIndex].summaryText = ""
            previewThreads[primaryIndex].statusText = "Ready"
        }

        let codexModelOptions = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.1"]
        let claudeModelOptions = ["claude-sonnet-4-5"]
        let profileContextSettings = [
            RuntimeSettingDescriptor(
                id: "profile_agents",
                title: "Profile Instructions",
                kind: "enum",
                allowCustom: false,
                value: "enabled",
                options: ["enabled", "disabled"]
            ),
            RuntimeSettingDescriptor(
                id: "profile_memory",
                title: "Profile Memory",
                kind: "enum",
                allowCustom: false,
                value: "disabled",
                options: ["enabled", "disabled"]
            ),
        ]
        let codexPreviewSettings: [RuntimeSettingDescriptor]
        if previewPresentation == "settings-runtime" {
            codexPreviewSettings = profileContextSettings
        } else {
            codexPreviewSettings = [
                RuntimeSettingDescriptor(
                    id: "model",
                    title: "Model",
                    kind: "enum",
                    allowCustom: true,
                    value: codexModelOptions[0],
                    options: codexModelOptions
                ),
                RuntimeSettingDescriptor(
                    id: "reasoning_effort",
                    title: "Reasoning Effort",
                    kind: "enum",
                    allowCustom: false,
                    value: "high",
                    options: codexReasoningEffortOptions
                ),
            ] + profileContextSettings
        }
        let previewExecutors = [
            RuntimeExecutorDescriptor(
                id: "codex",
                title: "Codex",
                kind: "agent",
                available: true,
                isDefault: true,
                internalOnly: false,
                model: codexModelOptions[0],
                settings: codexPreviewSettings
            ),
            RuntimeExecutorDescriptor(
                id: "claude",
                title: "Claude Code",
                kind: "agent",
                available: true,
                isDefault: false,
                internalOnly: false,
                model: claudeModelOptions[0],
                settings: [
                    RuntimeSettingDescriptor(
                        id: "model",
                        title: "Model",
                        kind: "enum",
                        allowCustom: true,
                        value: claudeModelOptions[0],
                        options: claudeModelOptions
                    )
                ]
            ),
        ]

        let slashCommands = [
            ComposerSlashCommand(
                descriptor: SlashCommandDescriptor(
                    id: "cwd",
                    title: "Working Directory",
                    description: "Show or change the working directory used for new runs.",
                    usage: "/cwd [path]",
                    group: "Runtime",
                    aliases: ["pwd", "workdir"],
                    symbol: "arrow.triangle.branch",
                    argumentKind: "path",
                    argumentOptions: [],
                    argumentPlaceholder: "path"
                )
            ),
            ComposerSlashCommand(
                descriptor: SlashCommandDescriptor(
                    id: "executor",
                    title: "Executor",
                    description: "Show or switch the active executor.",
                    usage: "/executor [codex|claude|local]",
                    group: "Runtime",
                    aliases: ["exec", "agent"],
                    symbol: "bolt.horizontal.circle",
                    argumentKind: "enum",
                    argumentOptions: ["codex", "claude", "local"],
                    argumentPlaceholder: "executor"
                )
            ),
        ]

        let mediaDraftAttachments = Self.previewDraftAttachments(in: draftAttachmentDirectory)

        let previewConversation = [
            ConversationMessage(
                role: "user",
                text: "Run the smoke test for this repo and summarize the result."
            ),
            ConversationMessage(
                role: "assistant",
                text: """
{
  "type": "assistant_response",
  "version": "1.0",
  "summary": "Smoke test finished.",
  "sections": [
    {
      "title": "Result",
      "body": "Backend tests passed, pairing is stable, and the current workspace thread is ready for the release archive."
    }
  ],
  "agenda_items": [],
  "artifacts": []
}
"""
            ),
            ConversationMessage(
                role: "user",
                text: "What should I tackle next?"
            ),
            ConversationMessage(
                role: "assistant",
                text: """
{
  "type": "assistant_response",
  "version": "1.0",
  "summary": "Recommended next step.",
  "sections": [
    {
      "title": "Next step",
      "body": "Keep this workspace thread, capture the App Store assets, and then archive the release build."
    }
  ],
  "agenda_items": [],
  "artifacts": []
}
"""
            ),
        ]

        let previewLiveActivityConversation = [
            ConversationMessage(
                role: "user",
                text: "Inspect the repo, run the smoke test, and tell me what changed."
            ),
            ConversationMessage(
                role: "assistant",
                text: "Running the smoke test and comparing the latest changes…",
                presentation: .liveActivity,
                sourceRunID: "pvw-live-2048"
            ),
        ]

        let previewMediaConversation = [
            ConversationMessage(
                role: "user",
                text: "Review the generated media and attached notes before I send the next task."
            ),
            ConversationMessage(
                role: "assistant",
                text: """
{
  "type": "assistant_response",
  "version": "1.0",
  "summary": "Generated media is ready to inspect.",
  "sections": [
    {
      "title": "Result",
      "body": "Created a markdown note and PDF-style artifact. File cards should stay readable, keep the original extension, and open in the in-app preview."
    }
  ],
  "agenda_items": [],
  "artifacts": [
    {
      "type": "code",
      "title": "rendering-notes.md",
      "path": "/Users/test/Mobile Documents/MOBaiLE/rendering-notes.md",
      "mime": "text/markdown"
    },
    {
      "type": "file",
      "title": "sample-output.pdf",
      "url": "http://old-host.example/v1/files?path=/Users/test/Mobile%20Documents/MOBaiLE/sample-output.pdf",
      "mime": "application/pdf"
    }
  ]
}
"""
            ),
        ]

        let previewBlockedConversation = [
            ConversationMessage(
                role: "user",
                text: "Check the production deploy status and continue the release plan."
            ),
            ConversationMessage(
                role: "assistant",
                text: """
{
  "type": "assistant_response",
  "version": "1.0",
  "summary": "The run is paused until you confirm the deploy gate.",
  "sections": [
    {
      "title": "Status",
      "body": "I reached the production gate and need your confirmation from the phone before continuing."
    }
  ],
  "agenda_items": [],
  "artifacts": []
}
"""
            ),
        ]

        let previewTimeoutConversation = [
            ConversationMessage(
                role: "user",
                text: "Run the full backend smoke suite and summarize the failure if anything times out."
            ),
            ConversationMessage(
                role: "assistant",
                text: """
{
  "type": "assistant_response",
  "version": "1.0",
  "summary": "The previous run stopped before the summary was ready.",
  "sections": [
    {
      "title": "Status",
      "body": "The backend connection dropped while the smoke suite was still running."
    }
  ],
  "agenda_items": [],
  "artifacts": []
}
"""
            ),
        ]

        var blockedThreads = previewThreads
        if let primaryIndex = blockedThreads.firstIndex(where: { $0.id == primaryThreadID }) {
            blockedThreads[primaryIndex].title = "Confirm deploy gate"
            blockedThreads[primaryIndex].runID = "pvw-block-2048"
            blockedThreads[primaryIndex].summaryText = "Waiting for confirmation before the release can continue."
            blockedThreads[primaryIndex].statusText = "Blocked on human input"
            blockedThreads[primaryIndex].pendingHumanUnblock = HumanUnblockRequest(
                instructions: "Approve the production gate in GitHub, then continue the run from the phone.",
                suggestedReply: "I approved the production gate. Continue from the preserved state."
            )
        }

        var timeoutThreads = previewThreads
        if let primaryIndex = timeoutThreads.firstIndex(where: { $0.id == primaryThreadID }) {
            timeoutThreads[primaryIndex].title = "Backend smoke retry"
            timeoutThreads[primaryIndex].runID = "pvw-timeout-2048"
            timeoutThreads[primaryIndex].summaryText = "The previous run timed out before the backend summary was ready."
            timeoutThreads[primaryIndex].statusText = "Timed out"
        }

        var restoredRunningThreads = previewThreads
        if let primaryIndex = restoredRunningThreads.firstIndex(where: { $0.id == primaryThreadID }) {
            restoredRunningThreads[primaryIndex].title = "Resume active run"
            restoredRunningThreads[primaryIndex].runID = "pvw-restore-2048"
            restoredRunningThreads[primaryIndex].summaryText = ""
            restoredRunningThreads[primaryIndex].statusText = "Running..."
        }

        let standardPreviewEvents = [
            ExecutionEvent(
                type: "activity.started",
                message: "Reviewing the repo and planning the smoke test.",
                stage: "planning",
                title: "Planning",
                displayMessage: "Reviewing the repo and planning the smoke test.",
                level: "info",
                eventID: "preview-activity-planning",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "activity.updated",
                message: "Running the smoke test and collecting the repo changes.",
                stage: "executing",
                title: "Executing",
                displayMessage: "Running the smoke test and collecting the repo changes.",
                level: "info",
                eventID: "preview-activity-executing",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "activity.completed",
                message: "Preparing the release summary.",
                stage: "summarizing",
                title: "Summarizing",
                displayMessage: "Preparing the release summary.",
                level: "info",
                eventID: "preview-activity-summarizing",
                createdAt: nil
            ),
        ]

        let blockedPreviewEvents = [
            ExecutionEvent(
                type: "activity.started",
                message: "Reviewing the deploy gate request.",
                stage: "planning",
                title: "Planning",
                displayMessage: "Reviewing the deploy gate request.",
                level: "info",
                eventID: "preview-blocked-planning",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "activity.updated",
                message: "Checking the release state and waiting at the production gate.",
                stage: "executing",
                title: "Executing",
                displayMessage: "Checking the release state and waiting at the production gate.",
                level: "info",
                eventID: "preview-blocked-executing",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "activity.updated",
                message: "Approve the production gate to continue.",
                stage: "blocked",
                title: "Needs Input",
                displayMessage: "Approve the production gate to continue.",
                level: "warning",
                eventID: "preview-blocked-warning",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "run.blocked",
                message: "Complete the gate approval and continue from the phone.",
                eventID: "preview-blocked-run",
                createdAt: nil
            ),
        ]

        let timeoutPreviewEvents = [
            ExecutionEvent(
                type: "activity.started",
                message: "Reviewing the full backend smoke suite.",
                stage: "planning",
                title: "Planning",
                displayMessage: "Reviewing the full backend smoke suite.",
                level: "info",
                eventID: "preview-timeout-planning",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "activity.updated",
                message: "Running the backend smoke suite.",
                stage: "executing",
                title: "Executing",
                displayMessage: "Running the backend smoke suite.",
                level: "info",
                eventID: "preview-timeout-executing",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "activity.updated",
                message: "The smoke suite timed out before the summary was ready.",
                stage: "executing",
                title: "Executing",
                displayMessage: "The smoke suite timed out before the summary was ready.",
                level: "error",
                eventID: "preview-timeout-error",
                createdAt: nil
            ),
            ExecutionEvent(
                type: "run.failed",
                message: "Timed out waiting for run completion.",
                eventID: "preview-timeout-run",
                createdAt: nil
            ),
        ]

        switch scenario {
        case .configuredEmpty:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: previewThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: [],
                conversation: [],
                promptText: "",
                draftAttachments: [],
                runID: "",
                summaryText: "",
                transcriptText: "",
                statusText: "Ready for prompts",
                runPhaseText: "Idle",
                runStartedAt: nil,
                runEndedAt: nil,
                isLoading: false,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: false,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: nil
            )
        case .conversation:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: previewThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: standardPreviewEvents,
                conversation: previewConversation,
                promptText: "",
                draftAttachments: [],
                runID: "pvw-2048",
                summaryText: "Ran the repo smoke test and captured the next release step from the same workspace thread.",
                transcriptText: "",
                statusText: "Completed",
                runPhaseText: "Completed",
                runStartedAt: now.addingTimeInterval(-160),
                runEndedAt: now.addingTimeInterval(-55),
                isLoading: false,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: true,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: nil
            )
        case .media:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: previewThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: standardPreviewEvents,
                conversation: previewMediaConversation,
                promptText: "Compare these files with the current renderer.",
                draftAttachments: mediaDraftAttachments,
                runID: "pvw-media-2048",
                summaryText: "Prepared media artifacts and local draft attachments for review.",
                transcriptText: "",
                statusText: "Ready",
                runPhaseText: "Idle",
                runStartedAt: now.addingTimeInterval(-180),
                runEndedAt: now.addingTimeInterval(-90),
                isLoading: false,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: true,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: nil
            )
        case .liveActivity:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: previewThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: [
                    ExecutionEvent(
                        type: "action.started",
                        actionIndex: 0,
                        message: "starting codex exec (cwd=\(workspace))",
                        eventID: "preview-live-start",
                        createdAt: nil
                    ),
                    ExecutionEvent(
                        type: "chat.message",
                        actionIndex: 0,
                        message: #"{"type":"assistant_response","version":"1.0","summary":"Running the smoke test and comparing the latest changes…","sections":[],"agenda_items":[],"artifacts":[]}"#,
                        eventID: "preview-live-progress",
                        createdAt: nil
                    ),
                ],
                conversation: previewLiveActivityConversation,
                promptText: "",
                draftAttachments: [],
                runID: "pvw-live-2048",
                summaryText: "",
                transcriptText: "",
                statusText: "Running...",
                runPhaseText: "Executing",
                runStartedAt: now.addingTimeInterval(-22),
                runEndedAt: nil,
                isLoading: true,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: false,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: nil
            )
        case .blocked:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: blockedThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: blockedPreviewEvents,
                conversation: previewBlockedConversation,
                promptText: "",
                draftAttachments: [],
                runID: "pvw-block-2048",
                summaryText: "Waiting for confirmation before the release can continue.",
                transcriptText: "",
                statusText: "Blocked on human input",
                runPhaseText: "Needs Input",
                runStartedAt: now.addingTimeInterval(-190),
                runEndedAt: now.addingTimeInterval(-55),
                isLoading: false,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: true,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: nil
            )
        case .recording:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: previewThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: standardPreviewEvents,
                conversation: previewConversation,
                promptText: "Run the smoke test again and tell me what changed since the last pass.",
                draftAttachments: Self.previewDraftAttachments(in: draftAttachmentDirectory),
                runID: "",
                summaryText: "",
                transcriptText: "",
                statusText: "Recording...",
                runPhaseText: "Recording",
                runStartedAt: nil,
                runEndedAt: nil,
                isLoading: false,
                isRecording: true,
                recordingStartedAt: now.addingTimeInterval(-38),
                didCompleteRun: false,
                voiceModeEnabled: true,
                voiceModeThreadID: primaryThreadID,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: true
            )
        case .repair:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: previewThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: standardPreviewEvents,
                conversation: previewConversation,
                promptText: "",
                draftAttachments: [],
                runID: "",
                summaryText: "",
                transcriptText: "",
                statusText: "Connection needs repair",
                runPhaseText: "Reconnect",
                runStartedAt: nil,
                runEndedAt: nil,
                isLoading: false,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: false,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: VoiceAgentViewModel.ConnectionRepairState(
                    title: "Reconnect this phone",
                    message: "This phone is no longer paired with demo.mobaile.app. Open the latest pairing QR on that computer and scan it again here."
                ),
                autoSendAfterSilenceEnabled: nil
            )
        case .timeout:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: timeoutThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: timeoutPreviewEvents,
                conversation: previewTimeoutConversation,
                promptText: "",
                draftAttachments: [],
                runID: "pvw-timeout-2048",
                summaryText: "The previous run timed out before the backend summary was ready.",
                transcriptText: "",
                statusText: "Timed out",
                runPhaseText: "Timed Out",
                runStartedAt: now.addingTimeInterval(-210),
                runEndedAt: now.addingTimeInterval(-80),
                isLoading: false,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: true,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: nil
            )
        case .restoredRunning:
            return VoiceAgentPreviewData(
                workspace: workspace,
                activeThreadID: primaryThreadID,
                threads: restoredRunningThreads,
                executors: previewExecutors,
                codexModelOptions: codexModelOptions,
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: codexReasoningEffortOptions,
                claudeModelOptions: claudeModelOptions,
                slashCommands: slashCommands,
                events: [],
                conversation: previewLiveActivityConversation,
                promptText: "",
                draftAttachments: [],
                runID: "pvw-restore-2048",
                summaryText: "",
                transcriptText: "",
                statusText: "Running...",
                runPhaseText: "Executing",
                runStartedAt: now.addingTimeInterval(-48),
                runEndedAt: nil,
                isLoading: true,
                isRecording: false,
                recordingStartedAt: nil,
                didCompleteRun: false,
                voiceModeEnabled: false,
                voiceModeThreadID: nil,
                connectionRepairState: nil,
                autoSendAfterSilenceEnabled: nil
            )
        }
    }

    private static func previewDraftAttachments(in directory: URL) -> [DraftAttachment] {
        [
            makePreviewAttachment(
                in: directory,
                fileName: "ReleaseNotes.md",
                contents: """
                1. Capture the App Store screenshots.
                2. Archive the release build.
                3. Submit the reviewer backend notes.
                """
            ),
            makePreviewAttachment(
                in: directory,
                fileName: "SmokeTest.sh",
                contents: """
                #!/usr/bin/env bash
                set -euo pipefail
                echo "Run backend smoke test"
                echo "Summarize the result"
                """
            ),
        ]
    }

    private static func makePreviewAttachment(
        in directory: URL,
        fileName: String,
        contents: String
    ) -> DraftAttachment {
        let fileURL = directory.appendingPathComponent("preview-\(fileName)")
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let data = contents.data(using: .utf8) {
            try? data.write(to: fileURL, options: .atomic)
        }

        let mimeType = inferAttachmentMimeType(fileName: fileName, fallback: "text/plain")
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
            ?? Int64(contents.utf8.count)

        return DraftAttachment(
            id: UUID(),
            localFileURL: fileURL,
            fileName: fileName,
            mimeType: mimeType,
            kind: inferAttachmentKind(fileName: fileName, mimeType: mimeType),
            sizeBytes: size
        )
    }
}
