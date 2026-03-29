import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

private enum PreviewScenario: String {
    case configuredEmpty = "configured-empty"
    case conversation = "conversation"
    case recording = "recording"

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

private enum PairingHostRules {
    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host.isEmpty { return false }
        return isLoopbackOrBonjourHost(host) || isRFC1918LANHost(host) || isTailscaleHost(host)
    }

    static func isLoopbackOrBonjourHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "localhost" || lower == "::1" || lower.hasSuffix(".local") || lower.hasPrefix("127.")
    }

    static func isRFC1918LANHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("10.") || lower.hasPrefix("192.168.") {
            return true
        }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    static func isTailscaleHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix(".ts.net") {
            return true
        }
        if lower.hasPrefix("100.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                return true
            }
        }
        return false
    }
}

@MainActor
final class VoiceAgentViewModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    struct PendingPairing: Identifiable, Equatable {
        let id = UUID()
        let serverURL: String
        let serverURLs: [String]
        let sessionID: String?
        let pairCode: String?
        let legacyToken: String?

        var serverHost: String {
            URL(string: serverURL)?.host?.lowercased() ?? ""
        }

        var localNetworkWarning: String? {
            guard serverURL.lowercased().hasPrefix("http://"),
                  PairingHostRules.isRFC1918LANHost(serverHost) else {
                return nil
            }
            return "This pairing link uses plain HTTP over your local network. It keeps setup simple, but anyone who can observe this Wi-Fi could capture the pairing exchange. Prefer Tailscale or HTTPS when possible."
        }

        var badgeText: String {
            if serverURL.lowercased().hasPrefix("https://") {
                return "HTTPS"
            }
            if PairingHostRules.isLocalOrPrivateHost(serverHost) {
                return "LOCAL"
            }
            return "HTTP"
        }
    }

    struct DirectoryBreadcrumb: Identifiable, Equatable {
        let id: String
        let title: String
        let path: String
    }

    private struct ObservedRunContext {
        let runID: String
        let threadID: UUID
        var lastEventSeq: Int = -1
        var seenEventIDs: Set<String> = []
        var seenEventFingerprints: Set<String> = []
        var events: [ExecutionEvent] = []
    }

    @Published var serverURL: String = ""
    @Published var apiToken: String = ""
    @Published var sessionID: String = "iphone-app"
    @Published var workingDirectory: String = "~"
    @Published var runTimeoutSeconds: String = "0"
    @Published var executor: String = "codex"
    @Published var responseMode: String = "concise"
    @Published var agentGuidanceMode: String = "guided"
    @Published var developerMode: Bool = false
    @Published var promptText: String = "" {
        didSet {
            persistDraftStateIfNeeded()
        }
    }
    @Published var draftAttachments: [DraftAttachment] = [] {
        didSet {
            persistDraftStateIfNeeded()
        }
    }
    @Published private(set) var draftAttachmentTransferStates: [UUID: DraftAttachmentTransferState] = [:]
    @Published var isLoading: Bool = false
    @Published var statusText: String = "Idle"
    @Published var runID: String = ""
    @Published var summaryText: String = ""
    @Published var transcriptText: String = ""
    @Published var errorText: String = ""
    @Published var events: [ExecutionEvent] = []
    @Published var conversation: [ConversationMessage] = []
    @Published var resolvedWorkingDirectory: String = ""
    @Published var isRecording: Bool = false
    @Published var recordingStartedAt: Date?
    @Published var didCompleteRun: Bool = false
    @Published var voiceModeEnabled: Bool = false
    @Published var isSpeakingReply: Bool = false
    @Published var activeRunExecutor: String = "codex"
    @Published var threads: [ChatThread] = []
    @Published var activeThreadID: UUID?
    @Published var backendSecurityMode: String = "unknown"
    @Published var backendExecutorDescriptors: [RuntimeExecutorDescriptor] = []
    @Published var backendDefaultExecutor: String = "codex"
    @Published var backendAvailableExecutors: [String] = ["codex"]
    @Published var backendSlashCommands: [ComposerSlashCommand] = []
    @Published var backendWorkdirRoot: String = ""
    @Published var showDirectoryBrowser: Bool = false
    @Published var isLoadingDirectoryBrowser: Bool = false
    @Published var directoryBrowserEntries: [DirectoryEntry] = []
    @Published var directoryBrowserTruncated: Bool = false
    @Published var directoryBrowserError: String = ""
    @Published var directoryBrowserMissingPath: String = ""
    @Published var pendingPairing: PendingPairing?
    @Published var runPhaseText: String = "Idle"
    @Published var runStartedAt: Date?
    @Published var runEndedAt: Date?
    @Published var directoryBrowserPath: String = ""
    @Published var airPodsClickToRecordEnabled: Bool = true
    @Published var hideDotFoldersInBrowser: Bool = true
    @Published var hapticCuesEnabled: Bool = true
    @Published var audioCuesEnabled: Bool = true
    @Published var autoSendAfterSilenceEnabled: Bool = false
    @Published var autoSendAfterSilenceSeconds: String = "1.2"

    private let client = APIClient()
    private let speaker = AVSpeechSynthesizer()
    private let recorder = AudioRecorderService()
    private let speechTranscriber = SpeechTranscriptionService()
    private let threadStore = ChatThreadStore()
    private let defaults = UserDefaults.standard
    private let draftAttachmentDirectory: URL
    private var lastSubmittedUserMessage: ConversationMessage?
    private var hasSeenMicrophonePrimer = false
    private var didBootstrapSession = false
    private var trustedPairHosts: Set<String> = []
    private var connectionCandidateServerURLs: [String] = []
    private var didConfigureRemoteCommands = false
    private var isRestoringThreadState = false
    private var activeAttachmentUploadCancellation: (() -> Void)?
    private var backendTranscribeProvider: String = "unknown"
    private var backendTranscribeReady = false
    private var observedRunContexts: [String: ObservedRunContext] = [:]
    private var lastHydratedSessionContextID: String?
    private var lastHydratedSessionContextServerURL: String?
    private var voiceModeThreadID: UUID?
    private var shouldResumeVoiceModeAfterSpeech = false

    private enum DefaultsKey {
        static let serverURL = "mobaile.server_url"
        static let serverURLCandidates = "mobaile.server_url_candidates"
        static let apiToken = "mobaile.api_token_legacy"
        static let sessionID = "mobaile.session_id"
        static let workingDirectory = "mobaile.working_directory"
        static let runTimeoutSeconds = "mobaile.run_timeout_seconds"
        static let runTimeoutMigratedToZeroDefault = "mobaile.run_timeout_migrated_to_zero_default"
        static let executor = "mobaile.executor"
        static let responseMode = "mobaile.response_mode"
        static let agentGuidanceMode = "mobaile.agent_guidance_mode"
        static let developerMode = "mobaile.developer_mode"
        static let threads = "mobaile.threads"
        static let activeThreadID = "mobaile.active_thread_id"
        static let trustedPairHosts = "mobaile.trusted_pair_hosts"
        static let airPodsClickToRecordEnabled = "mobaile.airpods_click_to_record"
        static let hideDotFoldersInBrowser = "mobaile.hide_dot_folders"
        static let hapticCuesEnabled = "mobaile.haptic_cues_enabled"
        static let audioCuesEnabled = "mobaile.audio_cues_enabled"
        static let autoSendAfterSilenceEnabled = "mobaile.auto_send_after_silence_enabled"
        static let autoSendAfterSilenceSeconds = "mobaile.auto_send_after_silence_seconds"
        static let microphonePrimerSeen = "mobaile.microphone_primer_seen"
        static let pendingShortcutAction = "mobaile.pending_shortcut_action"
    }

    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        draftAttachmentDirectory = appSupport
            .appendingPathComponent("MOBaiLE", isDirectory: true)
            .appendingPathComponent("draft-attachments", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(
            at: draftAttachmentDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        speaker.delegate = self
        client.onResolvedServerURL = { [weak self] resolvedURL in
            Task { @MainActor in
                self?.promoteResolvedServerURL(resolvedURL)
            }
        }
        loadSettings()
        loadThreads()
        if let previewScenario = PreviewScenario.current {
            applyPreviewScenario(previewScenario)
        }
        configureRemoteCommandsIfNeeded()
    }

    private func applyPreviewScenario(_ scenario: PreviewScenario) {
        let workspace = "/Users/vemundss/Library/Mobile Documents/com~apple~CloudDocs/jobb/EV-GROUP/MOBaiLE"
        let primaryThreadID = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
        let captureThreadID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        let draftThreadID = UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID()

        let previewThreads = [
            ChatThread(
                id: primaryThreadID,
                title: "Run smoke test",
                updatedAt: Date(),
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
                updatedAt: Date().addingTimeInterval(-4200),
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
                updatedAt: Date().addingTimeInterval(-8600),
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
                updatedAt: Date().addingTimeInterval(-12400),
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
                updatedAt: Date().addingTimeInterval(-18800),
                conversation: [],
                runID: "pvw-1742",
                summaryText: "Captured a hands-free task and kept the repo thread ready for the next run.",
                transcriptText: "",
                statusText: "Completed",
                resolvedWorkingDirectory: workspace,
                activeRunExecutor: "codex"
            ),
        ]

        let previewExecutors = [
            RuntimeExecutorDescriptor(
                id: "codex",
                title: "Codex",
                kind: "agent",
                available: true,
                isDefault: true,
                internalOnly: false,
                model: "gpt-5.4"
            ),
            RuntimeExecutorDescriptor(
                id: "claude",
                title: "Claude",
                kind: "agent",
                available: true,
                isDefault: false,
                internalOnly: false,
                model: "claude-sonnet-4.5"
            ),
        ]

        serverURL = "https://demo.mobaile.app"
        connectionCandidateServerURLs = ["https://demo.mobaile.app"]
        apiToken = "preview-token"
        sessionID = "app-preview"
        workingDirectory = workspace
        resolvedWorkingDirectory = workspace
        backendWorkdirRoot = workspace
        backendSecurityMode = "workspace-write"
        executor = "codex"
        activeRunExecutor = "codex"
        backendDefaultExecutor = "codex"
        backendAvailableExecutors = previewExecutors.map(\.id)
        backendExecutorDescriptors = previewExecutors
        backendSlashCommands = previewSlashCommands()
        directoryBrowserPath = workspace
        directoryBrowserEntries = []
        directoryBrowserError = ""
        directoryBrowserMissingPath = ""
        directoryBrowserTruncated = false
        showDirectoryBrowser = false
        events = [
            ExecutionEvent(type: "summary", actionIndex: 1, message: "Ran the repo smoke test and packaged the summary for the current workspace.", eventID: "preview-summary", createdAt: nil),
            ExecutionEvent(type: "tool", actionIndex: 2, message: "Prepared the screenshot set and release notes for the next step.", eventID: "preview-tool", createdAt: nil),
        ]
        errorText = ""
        pendingPairing = nil
        didBootstrapSession = true
        draftAttachmentTransferStates = [:]
        voiceModeEnabled = false
        voiceModeThreadID = nil
        isSpeakingReply = false
        shouldResumeVoiceModeAfterSpeech = false
        refreshClientConnectionCandidates()

        performThreadStateRestore {
            threads = previewThreads
            activeThreadID = primaryThreadID

            switch scenario {
            case .configuredEmpty:
                conversation = []
                promptText = ""
                draftAttachments = []
                runID = ""
                summaryText = ""
                transcriptText = ""
                statusText = "Ready for prompts"
                runPhaseText = "Idle"
                runStartedAt = nil
                runEndedAt = nil
                isLoading = false
                isRecording = false
                recordingStartedAt = nil
                didCompleteRun = false
                voiceModeEnabled = false
                voiceModeThreadID = nil

            case .conversation:
                conversation = previewConversation()
                promptText = ""
                draftAttachments = []
                runID = "pvw-2048"
                summaryText = "Ran the repo smoke test and captured the next release step from the same workspace thread."
                transcriptText = ""
                statusText = "Completed"
                runPhaseText = "Completed"
                runStartedAt = Date().addingTimeInterval(-160)
                runEndedAt = Date().addingTimeInterval(-55)
                isLoading = false
                isRecording = false
                recordingStartedAt = nil
                didCompleteRun = true
                voiceModeEnabled = false
                voiceModeThreadID = nil

            case .recording:
                conversation = previewConversation()
                promptText = "Run the smoke test again and tell me what changed since the last pass."
                draftAttachments = previewDraftAttachments()
                runID = ""
                summaryText = ""
                transcriptText = ""
                statusText = "Recording..."
                runPhaseText = "Recording"
                runStartedAt = nil
                runEndedAt = nil
                isLoading = false
                isRecording = true
                recordingStartedAt = Date().addingTimeInterval(-38)
                autoSendAfterSilenceEnabled = true
                didCompleteRun = false
                voiceModeEnabled = true
                voiceModeThreadID = primaryThreadID
            }
        }
    }

    private func previewConversation() -> [ConversationMessage] {
        [
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
    }

    private func previewSlashCommands() -> [ComposerSlashCommand] {
        [
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
    }

    private func previewDraftAttachments() -> [DraftAttachment] {
        [
            makePreviewAttachment(
                fileName: "ReleaseNotes.md",
                contents: """
                1. Capture the App Store screenshots.
                2. Archive the release build.
                3. Submit the reviewer backend notes.
                """
            ),
            makePreviewAttachment(
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

    private func makePreviewAttachment(fileName: String, contents: String) -> DraftAttachment {
        let fileURL = draftAttachmentDirectory.appendingPathComponent("preview-\(fileName)")
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

    func sendPrompt() async {
        await submitPrompt(
            text: promptText,
            stagedAttachments: draftAttachments,
            existingAttachments: []
        )
    }

    func startRecording() async {
        guard !isLoading else {
            statusText = "A run is already in progress."
            return
        }
        guard hasConfiguredConnection else {
            statusText = "Set server URL and token first."
            return
        }
        errorText = ""
        recordingStartedAt = nil
        do {
            let silenceConfig: AudioRecorderService.SilenceConfig?
            if usesAutoSendForCurrentTurn {
                silenceConfig = AudioRecorderService.SilenceConfig(
                    requiredSilenceDuration: normalizedAutoSendAfterSilenceSeconds
                )
            } else {
                silenceConfig = nil
            }

            shouldResumeVoiceModeAfterSpeech = false
            if speaker.isSpeaking {
                speaker.stopSpeaking(at: .immediate)
            }
            try await recorder.start(silenceConfig: silenceConfig) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isRecording else { return }
                    self.statusText = "Silence detected. Sending..."
                    await self.stopRecordingAndSend()
                }
            }
            isRecording = true
            recordingStartedAt = Date()
            statusText = "Recording..."
            updateRemoteCommandState()
            emitRecordingStartedFeedback()
            Task { [speechTranscriber] in
                await speechTranscriber.warmupAuthorization()
            }
        } catch let recorderError as RecorderError {
            recordingStartedAt = nil
            switch recorderError {
            case .permissionDenied:
                errorText = "Microphone access is off. Enable it in Settings and try again."
                statusText = "Microphone access needed"
            case .recorderUnavailable:
                errorText = recorderError.localizedDescription
                statusText = "Recorder unavailable"
            }
            emitFailureFeedback()
        } catch {
            recordingStartedAt = nil
            errorText = error.localizedDescription
            statusText = "Failed to start recording"
            emitFailureFeedback()
        }
    }

    func cancelCurrentRun() async {
        let activeRun = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activeRun.isEmpty else {
            cancelActiveAttachmentUploadIfNeeded()
            return
        }
        errorText = ""
        runPhaseText = "Cancelling"
        do {
            _ = try await client.cancelRun(
                serverURL: normalizedServerURL,
                token: apiToken,
                runID: activeRun
            )
            statusText = "Cancelling run..."
        } catch let apiError as APIError {
            switch apiError {
            case let .httpError(code, _):
                if code == 409 {
                    do {
                        let run = try await client.fetchRun(
                            serverURL: normalizedServerURL,
                            token: apiToken,
                            runID: activeRun
                        )
                        if let activeThreadID {
                            applyTerminalRunStateIfNeeded(run, threadID: activeThreadID)
                        }
                        return
                    } catch {
                        errorText = error.localizedDescription
                        return
                    }
                }
                errorText = apiError.localizedDescription
            default:
                errorText = apiError.localizedDescription
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func cancelActiveOperation() {
        if isUploadingAttachments {
            cancelActiveAttachmentUploadIfNeeded()
            return
        }
        guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await cancelCurrentRun() }
    }

    func stopRecordingAndSend() async {
        guard isRecording else { return }
        let originThreadID = activeThreadID
        let stagedDraftText = promptText
        let stagedDraftAttachments = draftAttachments
        didCompleteRun = false
        isRecording = false
        recordingStartedAt = nil
        updateRemoteCommandState()
        statusText = "Preparing voice input..."
        errorText = ""
        summaryText = ""
        transcriptText = ""
        events = []
        clearObservedRunContext(for: originThreadID)
        resolvedWorkingDirectory = normalizedWorkingDirectory ?? ""
        isLoading = true
        runPhaseText = "Planning"
        runStartedAt = Date()
        runEndedAt = nil

        guard let audioFile = recorder.stop() else {
            isLoading = false
            errorText = "No recorded audio file found."
            statusText = "Failed"
            runPhaseText = "Failed"
            runEndedAt = Date()
            return
        }

        do {
            let localTranscription: SpeechTranscriptionResult?
            var startedRunID = ""
            do {
                runPhaseText = "Transcribing"
                statusText = "Transcribing on iPhone..."
                localTranscription = try await speechTranscriber.transcribeFile(at: audioFile)
            } catch {
                if await backendAudioUploadAvailable(forceRefresh: true) {
                    localTranscription = nil
                } else {
                    throw voiceInputUnavailableError(from: error)
                }
            }

            if let localTranscription {
                let utteranceText = composeVoiceUtteranceText(
                    draftText: stagedDraftText,
                    transcriptText: localTranscription.text
                )
                let uploadedAttachments = try await uploadDraftAttachmentsIfNeeded(stagedDraftAttachments)
                let explicitAttachments = uploadedAttachments.map(\.artifact)
                if let originThreadID {
                    updateThreadMetadata(
                        threadID: originThreadID,
                        transcriptText: localTranscription.text,
                        persist: false
                    )
                } else {
                    transcriptText = localTranscription.text
                }
                appendConversation(
                    ConversationMessage(role: "user", text: utteranceText, attachments: explicitAttachments),
                    to: originThreadID
                )
                clearDraftState(for: originThreadID, removing: stagedDraftAttachments)
                if activeThreadID == originThreadID {
                    runPhaseText = "Planning"
                }
                if let originThreadID {
                    updateThreadMetadata(
                        threadID: originThreadID,
                        statusText: "Starting run...",
                        activeRunExecutor: effectiveExecutor,
                        persist: false
                    )
                } else {
                    statusText = "Starting run..."
                }
                let response = try await createUtteranceRun(
                    threadID: originThreadID,
                    utteranceText: utteranceText,
                    attachments: explicitAttachments
                )
                startedRunID = response.runId
                if let originThreadID {
                    ensureObservedRunContext(runID: response.runId, threadID: originThreadID)
                    updateThreadMetadata(
                        threadID: originThreadID,
                        runID: response.runId,
                        statusText: "Voice run started (\(response.runId))",
                        activeRunExecutor: effectiveExecutor,
                        persist: true
                    )
                } else {
                    runID = response.runId
                    activeRunExecutor = effectiveExecutor
                    statusText = "Voice run started (\(response.runId))"
                }
            } else {
                if activeThreadID == originThreadID {
                    runPhaseText = "Uploading"
                }
                if let originThreadID {
                    updateThreadMetadata(
                        threadID: originThreadID,
                        statusText: "Uploading audio to backend...",
                        activeRunExecutor: effectiveExecutor,
                        persist: false
                    )
                } else {
                    statusText = "Uploading audio to backend..."
                }
                let uploadedAttachments = try await uploadDraftAttachmentsIfNeeded(stagedDraftAttachments)
                let explicitAttachments = uploadedAttachments.map(\.artifact)
                let response = try await client.createAudioRun(
                    serverURL: normalizedServerURL,
                    token: apiToken,
                    sessionID: sessionID,
                    threadID: originThreadID?.uuidString,
                    executor: nil,
                    workingDirectory: nil,
                    responseMode: effectiveResponseMode,
                    responseProfile: effectiveAgentGuidanceMode,
                    draftText: stagedDraftText,
                    attachments: explicitAttachments,
                    audioFileURL: audioFile
                )
                let utteranceText = composeVoiceUtteranceText(
                    draftText: stagedDraftText,
                    transcriptText: response.transcriptText
                )
                startedRunID = response.runId
                if let originThreadID {
                    ensureObservedRunContext(runID: response.runId, threadID: originThreadID)
                    updateThreadMetadata(
                        threadID: originThreadID,
                        runID: response.runId,
                        transcriptText: response.transcriptText,
                        statusText: "Audio run started (\(response.runId))",
                        activeRunExecutor: effectiveExecutor,
                        persist: false
                    )
                } else {
                    runID = response.runId
                    transcriptText = response.transcriptText
                    activeRunExecutor = effectiveExecutor
                    statusText = "Audio run started (\(response.runId))"
                }
                appendConversation(
                    ConversationMessage(role: "user", text: utteranceText, attachments: explicitAttachments),
                    to: originThreadID
                )
                clearDraftState(for: originThreadID, removing: stagedDraftAttachments)
            }
            emitRecordingSentFeedback()
            if let originThreadID {
                persistThreadSnapshot(threadID: originThreadID)
            } else {
                persistActiveThreadSnapshot()
            }
            try await observeRun(runID: startedRunID, threadID: originThreadID)
        } catch {
            activeAttachmentUploadCancellation = nil
            if error is CancellationError || isAttachmentTransferCancellation(error) {
                if activeThreadID == originThreadID {
                    errorText = ""
                    statusText = "Cancelled"
                    isLoading = false
                    runPhaseText = "Cancelled"
                    runEndedAt = Date()
                } else if let originThreadID {
                    updateThreadMetadata(threadID: originThreadID, statusText: "Cancelled")
                }
                if let originThreadID {
                    persistThreadSnapshot(threadID: originThreadID)
                } else {
                    persistActiveThreadSnapshot()
                }
                return
            }
            maybeAutoFixWorkingDirectory(from: error)
            if activeThreadID == originThreadID {
                errorText = error.localizedDescription
                statusText = hasFailedDraftAttachments ? "Upload failed" : "Failed"
                isLoading = false
                runPhaseText = "Failed"
                runEndedAt = Date()
            } else if let originThreadID {
                updateThreadMetadata(
                    threadID: originThreadID,
                    statusText: hasFailedDraftAttachments ? "Upload failed" : "Failed"
                )
            }
            emitFailureFeedback()
            if let originThreadID {
                persistThreadSnapshot(threadID: originThreadID)
            } else {
                persistActiveThreadSnapshot()
            }
        }
    }

    func discardRecording() async {
        guard isRecording else { return }
        isRecording = false
        recordingStartedAt = nil
        updateRemoteCommandState()
        if let audioFile = recorder.stop() {
            try? FileManager.default.removeItem(at: audioFile)
        }
        errorText = ""
        isLoading = false
        runPhaseText = "Idle"
        runStartedAt = nil
        runEndedAt = nil
        statusText = hasConfiguredConnection ? "Ready for prompts" : "Set server URL and token first."
    }

    func toggleVoiceMode() async {
        if isVoiceModeActiveForCurrentThread {
            endVoiceMode()
            return
        }
        await beginVoiceMode()
    }

    func startVoiceModeIfNeeded() async {
        guard !isVoiceModeActiveForCurrentThread else { return }
        await beginVoiceMode()
    }

    func toggleRecordingFromHeadsetControl() async {
        guard airPodsClickToRecordEnabled else { return }
        guard hasConfiguredConnection else {
            statusText = "Set server URL and token first."
            return
        }
        if isRecording {
            await stopRecordingAndSend()
        } else if !isLoading {
            await startRecording()
        }
    }

    func handleStartVoiceTaskShortcut() async {
        if isRecording || isLoading {
            return
        }
        await startVoiceModeIfNeeded()
    }

    func handleSendLastPromptShortcut() async {
        if canRetryLastPrompt {
            await retryLastPrompt()
            return
        }
        statusText = "No previous prompt to resend."
    }

    var isVoiceModeActiveForCurrentThread: Bool {
        guard let activeThreadID else { return false }
        return voiceModeEnabled && voiceModeThreadID == activeThreadID
    }

    var usesAutoSendForCurrentTurn: Bool {
        autoSendAfterSilenceEnabled || isVoiceModeActiveForCurrentThread
    }

    var voiceModeStatusText: String {
        guard isVoiceModeActiveForCurrentThread else { return "Voice mode" }
        if isRecording {
            return "Listening"
        }
        if isSpeakingReply {
            return "Speaking"
        }
        if isLoading {
            return "Replying"
        }
        return "Voice mode on"
    }

    var shouldPresentMicrophonePrimer: Bool {
        !hasSeenMicrophonePrimer
    }

    func markMicrophonePrimerSeen() {
        guard !hasSeenMicrophonePrimer else { return }
        hasSeenMicrophonePrimer = true
        defaults.set(true, forKey: DefaultsKey.microphonePrimerSeen)
    }

    private func beginVoiceMode() async {
        guard hasConfiguredConnection else {
            statusText = "Set server URL and token first."
            return
        }
        if activeThreadID == nil {
            createNewThread()
        }
        voiceModeEnabled = true
        voiceModeThreadID = activeThreadID
        shouldResumeVoiceModeAfterSpeech = false
        errorText = ""
        if !isRecording && !isLoading {
            await startRecording()
        } else if isLoading {
            statusText = "Voice mode will continue after this reply."
        } else {
            statusText = "Voice mode is on."
        }
    }

    func endVoiceMode() {
        deactivateVoiceMode(stopSpeaking: true)
        if !isRecording && !isLoading && hasConfiguredConnection {
            statusText = "Ready for prompts"
        }
    }

    private func deactivateVoiceMode(stopSpeaking: Bool) {
        voiceModeEnabled = false
        voiceModeThreadID = nil
        shouldResumeVoiceModeAfterSpeech = false
        isSpeakingReply = false
        if stopSpeaking, speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
        }
    }

    func consumePendingShortcutActionIfNeeded() async {
        let action = defaults.string(forKey: DefaultsKey.pendingShortcutAction)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased() ?? ""
        guard !action.isEmpty else { return }
        defaults.removeObject(forKey: DefaultsKey.pendingShortcutAction)
        switch action {
        case "start-voice":
            await handleStartVoiceTaskShortcut()
        case "send-last-prompt":
            await handleSendLastPromptShortcut()
        default:
            break
        }
    }

    var hasDraftContent: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty
    }

    var draftAttachmentFailureNotice: String? {
        let failedAttachments = draftAttachments.filter { attachment in
            if case .failed = draftAttachmentTransferState(for: attachment) {
                return true
            }
            return false
        }
        guard !failedAttachments.isEmpty else { return nil }
        if failedAttachments.count == 1, let attachment = failedAttachments.first {
            return "\(attachment.fileName) failed to upload. Check the connection and send again, or remove the file."
        }
        return "\(failedAttachments.count) attachments failed to upload. Check the connection and send again, or remove the files."
    }

    func addDraftAttachment(fromImportedFile sourceURL: URL) async {
        do {
            let attachment = try stageImportedAttachment(from: sourceURL)
            appendDraftAttachment(attachment)
        } catch {
            errorText = "Couldn't add file: \(error.localizedDescription)"
        }
    }

    func addDraftAttachment(data: Data, fileName: String, mimeType: String?) async {
        do {
            let attachment = try stageAttachmentData(data, fileName: fileName, mimeType: mimeType)
            appendDraftAttachment(attachment)
        } catch {
            errorText = "Couldn't add attachment: \(error.localizedDescription)"
        }
    }

    func pasteClipboardContentIntoDraft() async {
        let pasteboard = UIPasteboard.general

        if let image = pasteboard.image {
            guard let data = image.pngData() else {
                errorText = "Couldn't read the clipboard image."
                return
            }
            let timestamp = Int(Date().timeIntervalSince1970)
            await addDraftAttachment(
                data: data,
                fileName: "clipboard-image-\(timestamp).png",
                mimeType: "image/png"
            )
            return
        }

        let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            if promptText.isEmpty {
                promptText = text
            } else {
                promptText += promptText.hasSuffix("\n") ? text : "\n\(text)"
            }
            errorText = ""
            return
        }

        errorText = "Clipboard doesn't contain a supported image or text item."
    }

    func removeDraftAttachment(_ attachment: DraftAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
        clearDraftAttachmentTransferState(for: attachment.id)
        try? FileManager.default.removeItem(at: attachment.localFileURL)
    }

    func draftAttachmentTransferState(for attachment: DraftAttachment) -> DraftAttachmentTransferState {
        draftAttachmentTransferStates[attachment.id] ?? .idle
    }

    private func observeRun(runID: String, threadID: UUID?) async throws {
        guard let threadID else { return }
        ensureObservedRunContext(runID: runID, threadID: threadID)
        setThreadPendingHumanUnblock(threadID: threadID, request: nil, persist: false)
        updateThreadMetadata(threadID: threadID, runID: runID, statusText: "Running...", persist: true)
        if activeThreadID == threadID {
            isLoading = true
            if runPhaseText == "Idle" {
                runPhaseText = "Planning"
            }
        }
        let timeoutSec = normalizedRunTimeoutSeconds
        let streamTask = Task {
            try? await streamRunUntilDone(runID: runID, threadID: threadID, timeoutSec: timeoutSec)
        }
        defer { streamTask.cancel() }

        // Keep polling as a watchdog so terminal state is reflected even if SSE stalls.
        try await pollRunUntilDone(runID: runID, threadID: threadID, timeoutSec: timeoutSec)
    }

    private func pollRunUntilDone(runID: String, threadID: UUID, timeoutSec: TimeInterval?) async throws {
        let deadline = timeoutSec.map { Date().addingTimeInterval($0) }
        while true {
            if let deadline, Date() >= deadline {
                break
            }
            if isTerminalStatusText(statusText(for: threadID)) {
                return
            }
            do {
                let run = try await client.fetchRun(
                    serverURL: normalizedServerURL,
                    token: apiToken,
                    runID: runID
                )
                updateThreadMetadata(
                    threadID: threadID,
                    summaryText: run.summary,
                    statusText: "Run status: \(run.status)",
                    resolvedWorkingDirectory: run.workingDirectory,
                    persist: false
                )
                if activeThreadID == threadID, run.status == "running", runPhaseText == "Planning" || runPhaseText == "Idle" {
                    runPhaseText = "Executing"
                }
                ingestEvents(run.events, runID: runID, threadID: threadID)

                if isTerminalStatus(run.status) {
                    applyTerminalRunStateIfNeeded(run, threadID: threadID)
                    return
                }
            } catch {
                if isTerminalStatusText(statusText(for: threadID)) {
                    return
                }
            }
            if isTerminalStatusText(statusText(for: threadID)) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if isTerminalStatusText(statusText(for: threadID)) {
            return
        }
        if activeThreadID == threadID {
            isLoading = false
            errorText = "Timed out waiting for run completion."
            runPhaseText = "Timed out"
            runEndedAt = Date()
        }
        updateThreadMetadata(threadID: threadID, statusText: "Timed out")
        appendConversation(role: "assistant", text: "Timed out waiting for run completion.", to: threadID)
        removeObservedRunContext(runID: runID)
    }

    private func streamRunUntilDone(runID: String, threadID: UUID, timeoutSec: TimeInterval?) async throws {
        let deadline = timeoutSec.map { Date().addingTimeInterval($0) }
        while true {
            if let deadline, Date() > deadline {
                throw NSError(
                    domain: "VoiceAgentApp",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Run timed out while streaming events."]
                )
            }
            if isTerminalStatusText(statusText(for: threadID)) {
                return
            }

            let stream = client.streamRunEvents(
                serverURL: normalizedServerURL,
                token: apiToken,
                runID: runID,
                afterSeq: observedRunContexts[runID]?.lastEventSeq
            )

            for try await event in stream {
                ingestEvents([event], runID: runID, threadID: threadID)
                if let deadline, Date() > deadline {
                    throw NSError(
                        domain: "VoiceAgentApp",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Run timed out while streaming events."]
                    )
                }
                if event.type == "run.completed" || event.type == "run.failed" || event.type == "run.blocked" || event.type == "run.cancelled" {
                    let run = try await client.fetchRun(
                        serverURL: normalizedServerURL,
                        token: apiToken,
                        runID: runID
                    )
                    applyTerminalRunStateIfNeeded(run, threadID: threadID)
                    return
                }
            }

            if isTerminalStatusText(statusText(for: threadID)) {
                return
            }

            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    func startNewChat() {
        createNewThread()
    }

    func toggleDirectoryBrowser() async {
        if showDirectoryBrowser {
            showDirectoryBrowser = false
            return
        }
        await refreshDirectoryBrowser()
        showDirectoryBrowser = true
    }

    func openDirectory(path: String) async {
        await refreshDirectoryBrowser(path: path)
        showDirectoryBrowser = true
    }

    func openDirectoryEntry(_ entry: DirectoryEntry) async {
        guard entry.isDirectory else { return }
        await openDirectory(path: entry.path)
    }

    func navigateDirectoryUp() async {
        let current = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            await refreshDirectoryBrowser()
            return
        }
        if current == "/" {
            await refreshDirectoryBrowser(path: "/")
            return
        }
        let parent = (current as NSString).deletingLastPathComponent
        if parent.isEmpty {
            await refreshDirectoryBrowser(path: current.hasPrefix("/") ? "/" : current)
        } else {
            await refreshDirectoryBrowser(path: parent)
        }
    }

    func refreshDirectoryBrowser(path: String? = nil) async {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else {
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
            directoryBrowserError = "Set server URL and API token to browse cwd."
            directoryBrowserMissingPath = ""
            directoryBrowserPath = ""
            isLoadingDirectoryBrowser = false
            return
        }

        isLoadingDirectoryBrowser = true
        directoryBrowserError = ""
        directoryBrowserMissingPath = ""
        let explicitPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let browserPath = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredPath: String?
        if !explicitPath.isEmpty {
            preferredPath = explicitPath
        } else if !browserPath.isEmpty {
            preferredPath = browserPath
        } else {
            preferredPath = directoryPathForListing
        }
        do {
            let response = try await client.fetchDirectoryListing(
                serverURL: normalizedServerURL,
                token: token,
                path: preferredPath
            )
            directoryBrowserEntries = response.entries
            directoryBrowserTruncated = response.truncated
            resolvedWorkingDirectory = response.path
            directoryBrowserPath = response.path
        } catch let apiError as APIError {
            if case let .httpError(code, body) = apiError, code == 404 {
                let lower = body.lowercased()
                if lower.contains("not found") && !lower.contains("directory not found") {
                    directoryBrowserError = "Backend does not support folder listing yet. Pull latest backend and restart."
                } else {
                    if let missing = preferredPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !missing.isEmpty {
                        directoryBrowserMissingPath = missing
                        directoryBrowserError = "Directory not found. You can create it from here."
                    } else {
                        directoryBrowserError = "Directory not found. Check the working directory in Settings."
                    }
                }
            } else {
                directoryBrowserError = apiError.localizedDescription
            }
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
        } catch {
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
            directoryBrowserError = error.localizedDescription
            directoryBrowserMissingPath = ""
        }
        isLoadingDirectoryBrowser = false
    }

    func createDirectoryFromBrowser() async {
        let target = directoryBrowserMissingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !normalizedServerURL.isEmpty, !token.isEmpty else { return }
        isLoadingDirectoryBrowser = true
        directoryBrowserError = ""
        do {
            let response = try await client.createDirectory(
                serverURL: normalizedServerURL,
                token: token,
                path: target
            )
            resolvedWorkingDirectory = response.path
            directoryBrowserMissingPath = ""
            await refreshDirectoryBrowser(path: response.path)
        } catch {
            directoryBrowserError = error.localizedDescription
            isLoadingDirectoryBrowser = false
        }
    }

    func createDirectoryInCurrentBrowser(name: String) async -> Bool {
        let folderName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty, !normalizedServerURL.isEmpty, !token.isEmpty else { return false }

        let basePath = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath: String
        if basePath.isEmpty {
            targetPath = folderName
        } else if basePath == "/" {
            targetPath = "/" + folderName
        } else {
            targetPath = basePath + "/" + folderName
        }

        isLoadingDirectoryBrowser = true
        directoryBrowserError = ""
        do {
            let response = try await client.createDirectory(
                serverURL: normalizedServerURL,
                token: token,
                path: targetPath
            )
            resolvedWorkingDirectory = response.path
            await refreshDirectoryBrowser(path: basePath.isEmpty ? response.path : basePath)
            return true
        } catch {
            directoryBrowserError = error.localizedDescription
            isLoadingDirectoryBrowser = false
            return false
        }
    }

    func hideDirectoryBrowser() {
        showDirectoryBrowser = false
    }

    var directoryBreadcrumbs: [DirectoryBreadcrumb] {
        let current = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return [] }
        if current == "/" {
            return [DirectoryBreadcrumb(id: "/", title: "/", path: "/")]
        }

        let isAbsolute = current.hasPrefix("/")
        let parts = current.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var crumbs: [DirectoryBreadcrumb] = []
        var running = isAbsolute ? "/" : ""
        if isAbsolute {
            crumbs.append(DirectoryBreadcrumb(id: "/", title: "/", path: "/"))
        }
        for part in parts {
            if running.isEmpty {
                running = part
            } else if running == "/" {
                running = "/" + part
            } else {
                running += "/" + part
            }
            crumbs.append(DirectoryBreadcrumb(id: running, title: part, path: running))
        }
        return crumbs
    }

    var canNavigateDirectoryUp: Bool {
        let current = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !current.isEmpty && current != "/"
    }

    var filteredDirectoryBrowserEntries: [DirectoryEntry] {
        guard hideDotFoldersInBrowser else { return directoryBrowserEntries }
        return directoryBrowserEntries.filter { entry in
            !(entry.isDirectory && entry.name.hasPrefix("."))
        }
    }

    var hiddenDotFolderCount: Int {
        directoryBrowserEntries.reduce(0) { partial, entry in
            if entry.isDirectory && entry.name.hasPrefix(".") {
                return partial + 1
            }
            return partial
        }
    }

    var canRetryLastPrompt: Bool {
        guard !isLoading, let lastSubmittedUserMessage else { return false }
        return !lastSubmittedUserMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !lastSubmittedUserMessage.attachments.isEmpty
    }

    var composerSlashCatalog: [ComposerSlashCommand] {
        ComposerSlashCommand.mergedCatalog(backend: backendSlashCommands)
    }

    var composerSlashCommandState: ComposerSlashCommandState? {
        resolveComposerSlashCommandState(from: promptText, commands: composerSlashCatalog)
    }

    var pendingHumanUnblockRequest: HumanUnblockRequest? {
        if let threadID = activeThreadID,
           let thread = threads.first(where: { $0.id == threadID }),
           let request = thread.pendingHumanUnblock {
            return request
        }
        for message in conversation.reversed() {
            if message.role == "user" {
                return nil
            }
            if message.role == "assistant",
               let request = humanUnblockRequest(from: message.text) {
                return request
            }
        }
        return nil
    }

    var isUploadingAttachments: Bool {
        activeAttachmentUploadCancellation != nil
    }

    var canCancelActiveOperation: Bool {
        isLoading && (isUploadingAttachments || !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func retryLastPrompt() async {
        guard let lastSubmittedUserMessage, canRetryLastPrompt else { return }
        await submitPrompt(
            text: lastSubmittedUserMessage.text,
            stagedAttachments: [],
            existingAttachments: lastSubmittedUserMessage.attachments
        )
    }

    func prepareHumanUnblockReply() {
        let suggested = pendingHumanUnblockRequest?.suggestedReply
            ?? "I completed the requested unblock step. Continue from the preserved state."
        promptText = suggested
    }

    func prepareSlashCommand(_ command: ComposerSlashCommand) {
        promptText = command.insertionText
    }

    func clearComposerText() {
        promptText = ""
        errorText = ""
    }

    func clearComposerDraft() {
        promptText = ""
        clearDraftAttachments()
        errorText = ""
    }

    func workingDirectorySlashSummary() -> String {
        let current = slashWorkingDirectoryDisplayPath()
        if current.isEmpty {
            return "Working directory follows the backend default."
        }
        return "Working directory: \(current)"
    }

    func setWorkingDirectoryFromSlashCommand(_ rawPath: String) async -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return workingDirectorySlashSummary()
        }
        workingDirectory = trimmed
        if let normalized = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !normalized.isEmpty {
            resolvedWorkingDirectory = normalized
        } else {
            resolvedWorkingDirectory = trimmed
        }
        persistSettings()
        errorText = ""
        let fallback = "Working directory set to \(slashWorkingDirectoryDisplayPath())."
        guard hasConfiguredConnection else { return fallback }
        do {
            let context = try await syncSessionContextToBackend()
            return "Working directory set to \(context.resolvedWorkingDirectory)."
        } catch {
            errorText = error.localizedDescription
            return fallback
        }
    }

    func executorSlashSummary() -> String {
        let options = selectableExecutors.joined(separator: ", ")
        let model = currentBackendModelLabel
        return "Executor: \(effectiveExecutor.uppercased()) (\(model)). Available: \(options)."
    }

    func setExecutorFromSlashCommand(_ rawExecutor: String) async -> String {
        let normalized = rawExecutor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return executorSlashSummary()
        }
        guard selectableExecutors.contains(normalized) else {
            return "Executor \(normalized) isn't available. Options: \(selectableExecutors.joined(separator: ", "))."
        }
        executor = normalized
        persistSettings()
        errorText = ""
        let fallback = "Executor set to \(effectiveExecutor.uppercased()) (\(currentBackendModelLabel))."
        guard hasConfiguredConnection else { return fallback }
        do {
            _ = try await syncSessionContextToBackend()
            return "Executor set to \(effectiveExecutor.uppercased()) (\(currentBackendModelLabel))."
        } catch {
            errorText = error.localizedDescription
            return fallback
        }
    }

    @discardableResult
    func refreshSlashCommandsFromBackend() async throws -> [ComposerSlashCommand] {
        guard hasConfiguredConnection else {
            backendSlashCommands = []
            throw APIError.missingCredentials
        }
        let descriptors = try await client.fetchSlashCommands(
            serverURL: normalizedServerURL,
            token: apiToken
        )
        backendSlashCommands = descriptors.map(ComposerSlashCommand.init(descriptor:))
        return backendSlashCommands
    }

    @discardableResult
    func executeBackendSlashCommand(
        _ command: ComposerSlashCommand,
        arguments: String
    ) async throws -> SlashCommandExecutionResponse {
        guard hasConfiguredConnection else {
            throw APIError.missingCredentials
        }
        let response = try await client.executeSlashCommand(
            serverURL: normalizedServerURL,
            token: apiToken,
            sessionID: sessionID,
            commandID: command.id,
            arguments: arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : arguments
        )
        if let sessionContext = response.sessionContext {
            applySessionContext(sessionContext)
        }
        return response
    }

    @discardableResult
    func refreshSessionContextFromBackend() async throws -> SessionContext {
        guard hasConfiguredConnection else {
            throw APIError.missingCredentials
        }
        let context = try await client.fetchSessionContext(
            serverURL: normalizedServerURL,
            token: apiToken,
            sessionID: sessionID
        )
        applySessionContext(context)
        return context
    }

    @discardableResult
    func syncSessionContextToBackend() async throws -> SessionContext {
        guard hasConfiguredConnection else {
            throw APIError.missingCredentials
        }

        let executorOverride: String? = {
            let current = effectiveExecutor
            let backendDefault = normalizedExecutor(from: backendDefaultExecutor) ?? current
            return current == backendDefault ? nil : current
        }()

        let workingDirectoryOverride: String? = {
            let normalized = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty else { return nil }
            let root = backendWorkdirRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            if !root.isEmpty && normalized == root {
                return nil
            }
            return normalized
        }()

        let context = try await client.updateSessionContext(
            serverURL: normalizedServerURL,
            token: apiToken,
            sessionID: sessionID,
            requestBody: SessionContextUpdateRequest(
                executor: executorOverride,
                workingDirectory: workingDirectoryOverride
            )
        )
        applySessionContext(context)
        return context
    }

    func persistAndSyncRuntimeSettings() async {
        persistSettings()
        guard hasConfiguredConnection else { return }
        do {
            let normalizedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSession.isEmpty else { return }
            let sameBackend = lastHydratedSessionContextServerURL == normalizedServerURL
            if sameBackend, lastHydratedSessionContextID == normalizedSession {
                _ = try await syncSessionContextToBackend()
            } else {
                _ = try await refreshSessionContextFromBackend()
            }
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func applySessionContext(_ context: SessionContext) {
        let normalizedSession = context.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSession.isEmpty {
            sessionID = normalizedSession
        }
        if let normalizedExecutorValue = normalizedExecutor(from: context.executor) {
            executor = normalizedExecutorValue
        }
        let rawWorkingDirectory = context.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = context.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawWorkingDirectory.isEmpty {
            workingDirectory = rawWorkingDirectory
        } else if !backendWorkdirRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workingDirectory = backendWorkdirRoot
        } else if !resolved.isEmpty {
            workingDirectory = resolved
        }
        if !resolved.isEmpty {
            resolvedWorkingDirectory = resolved
        }
        lastHydratedSessionContextID = normalizedSession.isEmpty ? lastHydratedSessionContextID : normalizedSession
        lastHydratedSessionContextServerURL = normalizedServerURL
        persistSettings()
    }

    private func restoreLatestRunFromSessionContext(_ context: SessionContext) async throws -> Bool {
        let latestRunID = context.latestRunId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latestStatus = context.latestRunStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !latestRunID.isEmpty, !latestStatus.isEmpty else {
            return false
        }
        guard let targetThreadID = threads.first(where: { $0.runID == latestRunID })?.id else {
            return false
        }

        let latestSummary = context.latestRunSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updateThreadMetadata(
            threadID: targetThreadID,
            runID: latestRunID,
            summaryText: latestSummary.isEmpty ? nil : latestSummary,
            statusText: "Run status: \(latestStatus)",
            persist: false
        )
        setThreadPendingHumanUnblock(
            threadID: targetThreadID,
            request: latestStatus == "blocked" ? context.latestRunPendingHumanUnblock : nil,
            persist: false
        )

        if latestStatus == "running" {
            if activeThreadID == targetThreadID {
                isLoading = true
                didCompleteRun = false
                runPhaseText = "Executing"
                runEndedAt = nil
            }
            if observedRunContext(for: targetThreadID, runID: latestRunID) == nil {
                try await observeRun(runID: latestRunID, threadID: targetThreadID)
            }
        } else if isTerminalStatus(latestStatus) {
            if activeThreadID == targetThreadID {
                isLoading = false
                didCompleteRun = true
                runPhaseText = phaseText(forRunStatus: latestStatus)
                if runEndedAt == nil {
                    runEndedAt = Date()
                }
            }
        }

        persistThreadSnapshot(threadID: targetThreadID)
        return true
    }

    private func uploadDraftAttachmentsIfNeeded(_ attachments: [DraftAttachment]) async throws -> [UploadResponse] {
        guard !attachments.isEmpty else { return [] }
        activeAttachmentUploadCancellation = nil
        clearDraftAttachmentTransferStates(for: attachments)
        var uploaded: [UploadResponse] = []
        for (index, attachment) in attachments.enumerated() {
            if attachments.count == 1 {
                statusText = "Uploading attachment..."
            } else {
                statusText = "Uploading attachment \(index + 1) of \(attachments.count)..."
            }
            setDraftAttachmentTransferState(.uploading(progress: 0), for: attachment.id)
            let response: UploadResponse
            do {
                response = try await client.uploadAttachment(
                    serverURL: normalizedServerURL,
                    token: apiToken,
                    sessionID: sessionID,
                    fileURL: attachment.localFileURL,
                    mimeType: attachment.mimeType,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.setDraftAttachmentTransferState(
                                .uploading(progress: progress),
                                for: attachment.id
                            )
                        }
                    },
                    registerCancellation: { [weak self] cancel in
                        Task { @MainActor in
                            self?.activeAttachmentUploadCancellation = cancel
                        }
                    }
                )
            } catch {
                activeAttachmentUploadCancellation = nil
                if isAttachmentTransferCancellation(error) {
                    clearDraftAttachmentTransferState(for: attachment.id)
                    throw CancellationError()
                }
                setDraftAttachmentTransferState(
                    .failed(message: summarizedAttachmentTransferError(error)),
                    for: attachment.id
                )
                throw error
            }
            activeAttachmentUploadCancellation = nil
            clearDraftAttachmentTransferState(for: attachment.id)
            uploaded.append(response)
        }
        activeAttachmentUploadCancellation = nil
        return uploaded
    }

    private func submitPrompt(
        text rawText: String,
        stagedAttachments: [DraftAttachment],
        existingAttachments: [ChatArtifact]
    ) async {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !stagedAttachments.isEmpty || !existingAttachments.isEmpty else { return }
        let originThreadID = activeThreadID

        didCompleteRun = false
        errorText = ""
        summaryText = ""
        events = []
        clearObservedRunContext(for: originThreadID)
        resolvedWorkingDirectory = normalizedWorkingDirectory ?? ""
        isLoading = true
        runPhaseText = stagedAttachments.isEmpty ? "Planning" : "Preparing"
        runStartedAt = Date()
        runEndedAt = nil
        activeRunExecutor = effectiveExecutor

        do {
            let uploadedAttachments = try await uploadDraftAttachmentsIfNeeded(stagedAttachments)
            let explicitAttachments = existingAttachments + uploadedAttachments.map(\.artifact)
            if let originThreadID {
                updateThreadMetadata(
                    threadID: originThreadID,
                    statusText: "Starting run...",
                    activeRunExecutor: effectiveExecutor,
                    persist: false
                )
            } else {
                statusText = "Starting run..."
            }
            if activeThreadID == originThreadID {
                runPhaseText = "Planning"
            }

            let message = ConversationMessage(
                role: "user",
                text: trimmedText,
                attachments: explicitAttachments
            )
            appendConversation(message, to: originThreadID)
            clearDraftState(for: originThreadID, removing: stagedAttachments)

            let response = try await createUtteranceRun(
                threadID: originThreadID,
                utteranceText: trimmedText,
                attachments: explicitAttachments
            )
            if let originThreadID {
                ensureObservedRunContext(runID: response.runId, threadID: originThreadID)
                updateThreadMetadata(
                    threadID: originThreadID,
                    runID: response.runId,
                    statusText: "Run started (\(response.runId))",
                    activeRunExecutor: effectiveExecutor
                )
            } else {
                runID = response.runId
                statusText = "Run started (\(response.runId))"
                persistActiveThreadSnapshot()
            }
            try await observeRun(runID: response.runId, threadID: originThreadID)
        } catch {
            activeAttachmentUploadCancellation = nil
            if error is CancellationError || isAttachmentTransferCancellation(error) {
                if activeThreadID == originThreadID {
                    errorText = ""
                    statusText = "Cancelled"
                    isLoading = false
                    runPhaseText = "Cancelled"
                    runEndedAt = Date()
                } else if let originThreadID {
                    updateThreadMetadata(threadID: originThreadID, statusText: "Cancelled")
                }
                if let originThreadID {
                    persistThreadSnapshot(threadID: originThreadID)
                } else {
                    persistActiveThreadSnapshot()
                }
                return
            }
            maybeAutoFixWorkingDirectory(from: error)
            if activeThreadID == originThreadID {
                errorText = error.localizedDescription
                statusText = hasFailedDraftAttachments ? "Upload failed" : "Failed"
                isLoading = false
                runPhaseText = "Failed"
                runEndedAt = Date()
            } else if let originThreadID {
                updateThreadMetadata(
                    threadID: originThreadID,
                    statusText: hasFailedDraftAttachments ? "Upload failed" : "Failed"
                )
            }
            emitFailureFeedback()
            if let originThreadID {
                persistThreadSnapshot(threadID: originThreadID)
            } else {
                persistActiveThreadSnapshot()
            }
        }
    }

    private func createUtteranceRun(
        threadID: UUID?,
        utteranceText: String,
        attachments: [ChatArtifact]
    ) async throws -> UtteranceResponse {
        try await client.createUtterance(
            serverURL: normalizedServerURL,
            token: apiToken,
            requestBody: UtteranceRequest(
                sessionId: sessionID,
                threadID: threadID?.uuidString,
                utteranceText: utteranceText,
                attachments: attachments,
                mode: "execute",
                executor: nil,
                workingDirectory: nil,
                responseMode: effectiveResponseMode,
                responseProfile: effectiveAgentGuidanceMode
            )
        )
    }

    private func composeVoiceUtteranceText(draftText: String, transcriptText: String) -> String {
        let segments = [draftText, transcriptText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return segments.joined(separator: "\n\n")
    }

    private func backendAudioUploadAvailable(forceRefresh: Bool) async -> Bool {
        if forceRefresh, hasConfiguredConnection {
            _ = try? await refreshRuntimeConfiguration()
        }
        let provider = backendTranscribeProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard backendTranscribeReady else { return false }
        return provider != "mock" && !provider.isEmpty && provider != "unknown"
    }

    private func voiceInputUnavailableError(from error: Error) -> Error {
        let speechMessage = error.localizedDescription
        if backendTranscribeReady && backendTranscribeProvider.lowercased() == "mock" {
            return SpeechTranscriptionError.unavailable(
                "\(speechMessage) The backend is currently using mock transcription, so voice upload would not produce a real transcript."
            )
        }
        return SpeechTranscriptionError.unavailable(
            "\(speechMessage) Enable Speech Recognition on the iPhone, or configure OPENAI_API_KEY on the backend for audio upload fallback."
        )
    }

    private func stageImportedAttachment(from sourceURL: URL) throws -> DraftAttachment {
        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let fileName = sourceURL.lastPathComponent.isEmpty ? "attachment" : sourceURL.lastPathComponent
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey])
        let mimeType = resourceValues?.contentType?.preferredMIMEType
        let data = try Data(contentsOf: sourceURL)
        return try stageAttachmentData(data, fileName: fileName, mimeType: mimeType)
    }

    private func stageAttachmentData(_ data: Data, fileName: String, mimeType: String?) throws -> DraftAttachment {
        try FileManager.default.createDirectory(
            at: draftAttachmentDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let safeName = sanitizeAttachmentFileName(fileName)
        let targetURL = draftAttachmentDirectory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        try data.write(to: targetURL, options: .atomic)
        let resolvedMimeType = inferAttachmentMimeType(fileName: safeName, fallback: mimeType)
        return DraftAttachment(
            id: UUID(),
            localFileURL: targetURL,
            fileName: safeName,
            mimeType: resolvedMimeType,
            kind: inferAttachmentKind(fileName: safeName, mimeType: resolvedMimeType),
            sizeBytes: Int64(data.count)
        )
    }

    private func appendDraftAttachment(_ attachment: DraftAttachment) {
        if draftAttachments.contains(where: {
            $0.fileName == attachment.fileName && $0.sizeBytes == attachment.sizeBytes
        }) {
            try? FileManager.default.removeItem(at: attachment.localFileURL)
            return
        }
        errorText = ""
        clearDraftAttachmentTransferState(for: attachment.id)
        draftAttachments.append(attachment)
    }

    private func clearDraftAttachments() {
        let existing = draftAttachments
        draftAttachments = []
        clearDraftAttachmentTransferStates(for: existing)
        for attachment in existing {
            try? FileManager.default.removeItem(at: attachment.localFileURL)
        }
    }

    private func clearDraftState(for threadID: UUID?, removing attachments: [DraftAttachment]) {
        guard let threadID else {
            promptText = ""
            clearDraftAttachments()
            return
        }
        if activeThreadID == threadID {
            promptText = ""
            clearDraftAttachments()
            return
        }
        guard let idx = threadIndex(for: threadID) else { return }
        threads[idx].draftText = ""
        clearDraftAttachmentTransferStates(for: attachments)
        deleteDraftAttachments(attachments)
        threads[idx].draftAttachments = []
        persistThreadSnapshot(threadID: threadID)
    }

    private func sanitizeAttachmentFileName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let final = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return final.isEmpty ? "attachment" : final
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.toggleRecordingFromHeadsetControl()
            }
            return .success
        }
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.airPodsClickToRecordEnabled, !self.isRecording, !self.isLoading {
                    await self.startRecording()
                }
            }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.airPodsClickToRecordEnabled, self.isRecording {
                    await self.stopRecordingAndSend()
                }
            }
            return .success
        }

        didConfigureRemoteCommands = true
        updateRemoteCommandState()
    }

    private func updateRemoteCommandState() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let canStartRecording = airPodsClickToRecordEnabled
        commandCenter.togglePlayPauseCommand.isEnabled = canStartRecording
        commandCenter.playCommand.isEnabled = canStartRecording
        commandCenter.pauseCommand.isEnabled = canStartRecording && isRecording

        if isRecording {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "MOBaiLE Recording",
                MPNowPlayingInfoPropertyPlaybackRate: 1
            ]
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func emitRecordingStartedFeedback() {
        if hapticCuesEnabled {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
        if audioCuesEnabled {
            AudioServicesPlaySystemSound(1104)
        }
    }

    private func emitRecordingSentFeedback() {
        if hapticCuesEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
        if audioCuesEnabled {
            AudioServicesPlaySystemSound(1113)
        }
    }

    private func emitFailureFeedback() {
        if hapticCuesEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
        if audioCuesEnabled {
            AudioServicesPlaySystemSound(1073)
        }
    }

    private func refreshClientConnectionCandidates() {
        client.fallbackServerURLs = Array(connectionCandidateServerURLs.dropFirst())
    }

    private func normalizedServerURLs(
        preferredServerURL: String? = nil,
        additionalServerURLs: [String] = []
    ) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        let candidates = [preferredServerURL] + additionalServerURLs
        for raw in candidates {
            let normalizedValue = normalized(raw ?? "")
            guard !normalizedValue.isEmpty, !seen.contains(normalizedValue) else { continue }
            seen.insert(normalizedValue)
            ordered.append(normalizedValue)
        }
        return ordered
    }

    private func applyAdvertisedServerURLs(
        primaryServerURL: String?,
        advertisedServerURLs: [String],
        persist: Bool = true
    ) {
        let resolved = normalizedServerURLs(
            preferredServerURL: primaryServerURL,
            additionalServerURLs: advertisedServerURLs
        )
        let finalCandidates = resolved.isEmpty
            ? normalizedServerURLs(
                preferredServerURL: normalizedServerURL,
                additionalServerURLs: connectionCandidateServerURLs
            )
            : resolved
        if let preferred = finalCandidates.first {
            serverURL = preferred
        }
        connectionCandidateServerURLs = finalCandidates
        refreshClientConnectionCandidates()
        if persist {
            persistSettings()
        }
    }

    private func promoteResolvedServerURL(_ resolvedURL: String) {
        let promoted = normalized(resolvedURL)
        guard !promoted.isEmpty else { return }
        if promoted == normalizedServerURL {
            return
        }
        let currentCandidates = connectionCandidateServerURLs.isEmpty ? [normalizedServerURL] : connectionCandidateServerURLs
        applyAdvertisedServerURLs(
            primaryServerURL: promoted,
            advertisedServerURLs: currentCandidates,
            persist: true
        )
    }

    func persistSettings() {
        if responseMode != "concise" {
            responseMode = "concise"
        }
        let normalizedServer = normalizedServerURL
        if normalizedServer.isEmpty {
            connectionCandidateServerURLs = []
        } else if connectionCandidateServerURLs.contains(normalizedServer) {
            connectionCandidateServerURLs = normalizedServerURLs(
                preferredServerURL: normalizedServer,
                additionalServerURLs: connectionCandidateServerURLs
            )
        } else {
            connectionCandidateServerURLs = [normalizedServer]
        }
        defaults.set(serverURL, forKey: DefaultsKey.serverURL)
        defaults.set(connectionCandidateServerURLs, forKey: DefaultsKey.serverURLCandidates)
        if !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainStore.save(value: apiToken, service: "MOBaiLE", account: "api_token")
            defaults.removeObject(forKey: DefaultsKey.apiToken)
        } else {
            KeychainStore.delete(service: "MOBaiLE", account: "api_token")
            defaults.removeObject(forKey: DefaultsKey.apiToken)
        }
        defaults.set(sessionID, forKey: DefaultsKey.sessionID)
        defaults.set(workingDirectory, forKey: DefaultsKey.workingDirectory)
        defaults.set(runTimeoutSeconds, forKey: DefaultsKey.runTimeoutSeconds)
        defaults.set(executor, forKey: DefaultsKey.executor)
        defaults.set("concise", forKey: DefaultsKey.responseMode)
        defaults.set(agentGuidanceMode, forKey: DefaultsKey.agentGuidanceMode)
        defaults.set(developerMode, forKey: DefaultsKey.developerMode)
        defaults.set(airPodsClickToRecordEnabled, forKey: DefaultsKey.airPodsClickToRecordEnabled)
        defaults.set(hideDotFoldersInBrowser, forKey: DefaultsKey.hideDotFoldersInBrowser)
        defaults.set(hapticCuesEnabled, forKey: DefaultsKey.hapticCuesEnabled)
        defaults.set(audioCuesEnabled, forKey: DefaultsKey.audioCuesEnabled)
        defaults.set(autoSendAfterSilenceEnabled, forKey: DefaultsKey.autoSendAfterSilenceEnabled)
        defaults.set(autoSendAfterSilenceSeconds, forKey: DefaultsKey.autoSendAfterSilenceSeconds)
        refreshClientConnectionCandidates()
        updateRemoteCommandState()
    }

    func bootstrapSessionIfNeeded() async {
        guard !didBootstrapSession else { return }
        guard !normalizedServerURL.isEmpty, !apiToken.isEmpty, !sessionID.isEmpty else { return }
        didBootstrapSession = true
        do {
            _ = try? await refreshRuntimeConfiguration()
            let context = try await refreshSessionContextFromBackend()
            let restoredFromContext = (try? await restoreLatestRunFromSessionContext(context)) ?? false
            if restoredFromContext {
                return
            }
            let runs = try await client.fetchSessionRuns(
                serverURL: normalizedServerURL,
                token: apiToken,
                sessionID: sessionID,
                limit: 1
            )
            guard let latest = runs.first else { return }
            guard let targetThreadID = threads.first(where: { $0.runID == latest.runId })?.id else {
                return
            }
            updateThreadMetadata(
                threadID: targetThreadID,
                runID: latest.runId,
                statusText: "Run status: \(latest.status)",
                activeRunExecutor: latest.executor ?? executor,
                persist: false
            )
            if activeThreadID == targetThreadID {
                runPhaseText = phaseText(forRunStatus: latest.status)
            }
            if latest.status == "running" {
                if activeThreadID == targetThreadID {
                    isLoading = true
                    runPhaseText = "Executing"
                    runStartedAt = Date()
                    runEndedAt = nil
                }
                try await observeRun(runID: latest.runId, threadID: targetThreadID)
            } else if isTerminalStatus(latest.status) {
                if activeThreadID == targetThreadID {
                    runEndedAt = Date()
                }
            }
            persistThreadSnapshot(threadID: targetThreadID)
        } catch {
            // Ignore bootstrap errors to avoid blocking first render.
        }
    }

    func refreshSessionPresenceFromBackendIfPossible() async {
        guard hasConfiguredConnection else { return }
        do {
            let context = try await refreshSessionContextFromBackend()
            _ = try? await restoreLatestRunFromSessionContext(context)
        } catch {
            // Ignore foreground refresh failures to keep the UI responsive.
        }
    }

    func applyPairingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "mobaile" else { return }
        guard let host = url.host?.lowercased(), host == "pair" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        var advertisedServerURLs: [String] = []
        var updatedToken: String?
        var pairCode: String?
        var updatedSession: String?

        for item in components.queryItems ?? [] {
            switch item.name {
            case "server_url":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    advertisedServerURLs.append(value)
                }
            case "api_token":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    updatedToken = value
                }
            case "pair_code":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    pairCode = value
                }
            case "session_id":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    updatedSession = value
                }
            default:
                continue
            }
        }

        let resolvedServerURLs = normalizedServerURLs(additionalServerURLs: advertisedServerURLs)
        guard let normalizedServer = resolvedServerURLs.first else {
            errorText = "Invalid pairing QR. Missing server URL."
            return
        }
        for candidate in resolvedServerURLs {
            guard let parsedServer = URL(string: candidate),
                  let schemeValue = parsedServer.scheme?.lowercased(),
                  schemeValue == "http" || schemeValue == "https",
                  let hostValue = parsedServer.host?.lowercased() else {
                errorText = "Invalid pairing QR. Server URL must be a valid http(s) URL."
                return
            }
            if schemeValue != "https" && !isLocalOrPrivateHost(hostValue) {
                errorText = "Pairing requires HTTPS for non-local servers."
                return
            }
        }
        if pairCode == nil, updatedToken != nil, !developerMode {
            errorText = "Legacy token pairing links are disabled. Use pair-code QR pairing."
            return
        }
        if pairCode == nil, updatedToken == nil {
            errorText = "Invalid pairing QR. Missing pair_code."
            return
        }

        pendingPairing = PendingPairing(
            serverURL: normalizedServer,
            serverURLs: resolvedServerURLs,
            sessionID: updatedSession,
            pairCode: pairCode,
            legacyToken: developerMode ? updatedToken : nil
        )
        errorText = ""
    }

    func cancelPendingPairing() {
        pendingPairing = nil
    }

    func isTrustedPairHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return false }
        return trustedPairHosts.contains(normalizedHost)
    }

    func setTrustedPairHost(_ host: String, trusted: Bool) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return }
        if trusted {
            trustedPairHosts.insert(normalizedHost)
        } else {
            trustedPairHosts.remove(normalizedHost)
        }
        defaults.set(Array(trustedPairHosts).sorted(), forKey: DefaultsKey.trustedPairHosts)
    }

    func confirmPendingPairing(trustHost: Bool) {
        guard let pending = pendingPairing else { return }

        if trustHost {
            setTrustedPairHost(pending.serverHost, trusted: true)
        }

        if let oneTimeCode = pending.pairCode {
            Task {
                await exchangePairCode(
                    serverURLs: pending.serverURLs,
                    pairCode: oneTimeCode,
                    sessionID: pending.sessionID
                )
            }
            return
        }
        if let token = pending.legacyToken {
            pendingPairing = nil
            applyAdvertisedServerURLs(
                primaryServerURL: pending.serverURL,
                advertisedServerURLs: pending.serverURLs,
                persist: false
            )
            if let session = pending.sessionID, !session.isEmpty {
                sessionID = session
            }
            apiToken = token
            persistSettings()
            statusText = "Paired successfully (legacy token)"
            errorText = ""
            persistActiveThreadSnapshot()
            return
        }
        errorText = "Invalid pairing QR. Missing pair code."
    }

    func confirmPendingPairing() {
        confirmPendingPairing(trustHost: false)
    }

    var sortedThreads: [ChatThread] {
        threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func switchToThread(_ threadID: UUID) {
        guard let idx = threadIndex(for: threadID) else { return }
        if voiceModeEnabled, voiceModeThreadID != threadID {
            deactivateVoiceMode(stopSpeaking: true)
        }
        persistActiveThreadSnapshot()
        let thread = threads[idx]
        let restoredAttachments = availableDraftAttachments(from: thread.draftAttachments)
        let restoredConversation = threadStore.loadMessages(threadID: threadID)
        let restoredEvents: [ExecutionEvent]
        restoredEvents = observedRunContext(for: threadID, runID: thread.runID)?.events ?? []
        let hasObservedRun = observedRunContext(for: threadID, runID: thread.runID) != nil &&
            !isTerminalStatusText(thread.statusText)
        performThreadStateRestore {
            activeThreadID = threadID
            threads[idx].conversation = restoredConversation
            conversation = restoredConversation
            lastSubmittedUserMessage = conversation.last(where: { $0.role == "user" })
            promptText = thread.draftText
            draftAttachments = restoredAttachments
            draftAttachmentTransferStates = [:]
            runID = thread.runID
            summaryText = thread.summaryText
            transcriptText = thread.transcriptText
            statusText = thread.statusText
            runPhaseText = phaseText(forStatusText: thread.statusText)
            runStartedAt = nil
            runEndedAt = nil
            isLoading = hasObservedRun || thread.statusText.lowercased().contains("running")
            resolvedWorkingDirectory = thread.resolvedWorkingDirectory
            activeRunExecutor = thread.activeRunExecutor
            errorText = ""
            events = restoredEvents
            didCompleteRun = isTerminalStatusText(thread.statusText)
        }
        defaults.set(threadID.uuidString, forKey: DefaultsKey.activeThreadID)
    }

    func createNewThread() {
        if voiceModeEnabled {
            deactivateVoiceMode(stopSpeaking: true)
        }
        persistActiveThreadSnapshot()
        let thread = ChatThread(
            id: UUID(),
            title: "New Chat",
            updatedAt: Date(),
            conversation: [],
            runID: "",
            summaryText: "",
            transcriptText: "",
            statusText: "Idle",
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            activeRunExecutor: effectiveExecutor,
            draftText: "",
            draftAttachments: []
        )
        threads.append(thread)
        performThreadStateRestore {
            activeThreadID = thread.id
            conversation = []
            lastSubmittedUserMessage = nil
            promptText = ""
            draftAttachments = []
            draftAttachmentTransferStates = [:]
            runID = ""
            summaryText = ""
            transcriptText = ""
            statusText = "Idle"
            runPhaseText = "Idle"
            runStartedAt = nil
            runEndedAt = nil
            recordingStartedAt = nil
            isLoading = false
            errorText = ""
            events = []
            didCompleteRun = false
            activeRunExecutor = effectiveExecutor
        }
        threadStore.upsertThread(thread)
        defaults.set(thread.id.uuidString, forKey: DefaultsKey.activeThreadID)
    }

    func renameThread(_ threadID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].title = trimmed
        threads[idx].updatedAt = Date()
        threadStore.upsertThread(threads[idx])
    }

    func deleteThread(_ threadID: UUID) {
        if voiceModeThreadID == threadID {
            deactivateVoiceMode(stopSpeaking: true)
        }
        if activeThreadID == threadID {
            persistActiveThreadSnapshot()
        }
        clearObservedRunContext(for: threadID)
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
        deleteDraftAttachments(thread.draftAttachments)
        threads.removeAll { $0.id == threadID }
        threadStore.deleteThread(threadID: threadID)
        if threads.isEmpty {
            createNewThread()
            switchToThread(activeThreadID ?? threads[0].id)
            return
        }
        if activeThreadID == threadID {
            let next = sortedThreads.first?.id ?? threads[0].id
            switchToThread(next)
        }
    }

    @discardableResult
    func refreshRuntimeConfiguration() async throws -> RuntimeConfig {
        guard hasConfiguredConnection else {
            clearRuntimeConfiguration()
            throw APIError.missingCredentials
        }
        let cfg = try await client.fetchRuntimeConfig(
            serverURL: normalizedServerURL,
            token: apiToken
        )
        applyAdvertisedServerURLs(
            primaryServerURL: cfg.serverURL,
            advertisedServerURLs: cfg.serverURLs ?? [],
            persist: true
        )
        backendSecurityMode = cfg.securityMode
        backendDefaultExecutor = normalizedExecutor(from: cfg.defaultExecutor) ?? "codex"
        backendExecutorDescriptors = normalizedRuntimeExecutors(
            cfg.executors,
            config: cfg,
            defaultExecutor: backendDefaultExecutor
        )
        backendAvailableExecutors = normalizedAvailableExecutors(
            cfg.availableExecutors,
            descriptors: backendExecutorDescriptors,
            defaultExecutor: backendDefaultExecutor
        )
        backendTranscribeProvider = normalizedTranscribeProvider(from: cfg.transcribeProvider)
        backendTranscribeReady = cfg.transcribeReady ?? false
        backendWorkdirRoot = cfg.workdirRoot ?? ""
        let slashDescriptors = try await client.fetchSlashCommands(
            serverURL: normalizedServerURL,
            token: apiToken
        )
        backendSlashCommands = slashDescriptors.map(ComposerSlashCommand.init(descriptor:))
        if normalizedExecutor(from: executor) == nil {
            executor = backendDefaultExecutor
        }
        return cfg
    }

    func useCurrentBrowserDirectoryAsWorkingDirectory() async {
        let path = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        workingDirectory = path
        resolvedWorkingDirectory = path
        persistSettings()
        guard hasConfiguredConnection else { return }
        do {
            _ = try await syncSessionContextToBackend()
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func speak(_ text: String) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.rate = 0.5
        speaker.speak(utterance)
    }

    private func scheduleVoiceModeResumeAfterCurrentReply(threadID: UUID, replyText: String) {
        guard voiceModeEnabled, voiceModeThreadID == threadID else {
            speak(replyText)
            return
        }
        shouldResumeVoiceModeAfterSpeech = true
        let spokenReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenReply.isEmpty else {
            Task { @MainActor in
                await self.resumeVoiceModeAfterSpokenReplyIfNeeded()
            }
            return
        }
        speak(spokenReply)
    }

    private func resumeVoiceModeAfterSpokenReplyIfNeeded() async {
        guard shouldResumeVoiceModeAfterSpeech else { return }
        guard voiceModeEnabled,
              let voiceModeThreadID,
              voiceModeThreadID == activeThreadID else {
            shouldResumeVoiceModeAfterSpeech = false
            return
        }
        shouldResumeVoiceModeAfterSpeech = false
        guard !isLoading, !isRecording else { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        await startRecording()
        if !isRecording {
            deactivateVoiceMode(stopSpeaking: false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeakingReply = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeakingReply = false
            await self.resumeVoiceModeAfterSpokenReplyIfNeeded()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeakingReply = false
            await self.resumeVoiceModeAfterSpokenReplyIfNeeded()
        }
    }

    private var normalizedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var hasConfiguredConnection: Bool {
        !normalizedServerURL.isEmpty && !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedWorkingDirectory: String? {
        let value = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        let root = backendWorkdirRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" || value == "." {
            return root.isEmpty ? value : root
        }
        if value.hasPrefix("/") {
            return value
        }
        if !root.isEmpty {
            return root + "/" + value
        }
        return value
    }

    private func slashWorkingDirectoryDisplayPath() -> String {
        let normalized = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty {
            return normalized
        }
        let resolved = resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty {
            return resolved
        }
        return workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var selectableExecutors: [String] {
        var values = backendAvailableExecutors.filter { $0 == "local" || $0 == "codex" || $0 == "claude" }
        if values.isEmpty {
            if let preferred = normalizedExecutor(from: backendDefaultExecutor) {
                values = [preferred]
            } else {
                values = ["codex"]
            }
        }
        if developerMode {
            if !values.contains("local") {
                values.append("local")
            }
            return values
        }
        if effectiveExecutor == "local" && !values.contains("local") {
            values.insert("local", at: 0)
        }
        if backendDefaultExecutor == "local", values.contains("local") {
            return ["local"]
        }
        let agentExecutors = values.filter { $0 == "codex" || $0 == "claude" }
        if effectiveExecutor == "local" && values.contains("local") {
            return ["local"] + agentExecutors
        }
        if !agentExecutors.isEmpty {
            return agentExecutors
        }
        return values
    }

    var backendExecutorModelRows: [(id: String, title: String, model: String)] {
        backendExecutorDescriptors
            .filter { $0.kind == "agent" }
            .map { descriptor in
                (
                    id: descriptor.id,
                    title: descriptor.title,
                    model: displayModelName(descriptor.model)
                )
            }
    }

    var currentBackendModelLabel: String {
        modelLabel(for: effectiveExecutor)
    }

    private var effectiveExecutor: String {
        let trimmed = executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "local" {
            return "local"
        }
        if trimmed == "codex" || trimmed == "claude" {
            return trimmed
        }
        let backendDefault = backendDefaultExecutor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if backendDefault == "local" || backendDefault == "codex" || backendDefault == "claude" {
            return backendDefault
        }
        return "codex"
    }

    private var effectiveResponseMode: String {
        "concise"
    }

    private var effectiveAgentGuidanceMode: String {
        agentGuidanceMode == "minimal" ? "minimal" : "guided"
    }

    private var directoryPathForListing: String? {
        let resolved = resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty {
            return resolved
        }
        guard let requested = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty,
              requested != "~",
              requested != "." else {
            return nil
        }
        return requested
    }

    private var normalizedRunTimeoutSeconds: TimeInterval? {
        let value = runTimeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(value), parsed > 0 else { return nil }
        return max(10, parsed)
    }

    private var normalizedAutoSendAfterSilenceSeconds: TimeInterval {
        let value = autoSendAfterSilenceSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(value) else { return 1.2 }
        return min(5.0, max(0.8, parsed))
    }

    func modelLabel(for executor: String) -> String {
        let normalized = executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "local" {
            return "n/a"
        }
        if let descriptor = backendExecutorDescriptors.first(where: { $0.id == normalized }) {
            return displayModelName(descriptor.model)
        }
        return "default"
    }

    private func isTerminalStatus(_ status: String) -> Bool {
        status == "completed" || status == "failed" || status == "rejected" || status == "blocked" || status == "cancelled"
    }

    private func applyTerminalRunStateIfNeeded(_ run: RunRecord, threadID: UUID) {
        if activeThreadID == threadID, didCompleteRun && summaryText == run.summary {
            return
        }
        let shouldContinueVoiceMode = voiceModeEnabled && voiceModeThreadID == threadID
        if shouldContinueVoiceMode, run.status != "completed" {
            deactivateVoiceMode(stopSpeaking: false)
        }

        setThreadPendingHumanUnblock(
            threadID: threadID,
            request: run.status == "blocked" ? run.pendingHumanUnblock : nil,
            persist: false
        )
        updateThreadMetadata(
            threadID: threadID,
            summaryText: run.summary,
            statusText: "Run status: \(run.status)",
            resolvedWorkingDirectory: run.workingDirectory,
            persist: false
        )

        if activeThreadID == threadID {
            isLoading = false
            didCompleteRun = true
            runPhaseText = phaseText(forRunStatus: run.status)
            if runEndedAt == nil {
                runEndedAt = Date()
            }
            if shouldContinueVoiceMode && run.status == "completed" {
                scheduleVoiceModeResumeAfterCurrentReply(threadID: threadID, replyText: run.summary)
            } else {
                speak(run.summary)
            }
        }

        removeObservedRunContext(runID: run.runId)

        persistThreadSnapshot(threadID: threadID)
    }

    private func ingestEvents(_ runEvents: [ExecutionEvent], runID: String, threadID: UUID) {
        ensureObservedRunContext(runID: runID, threadID: threadID)
        for event in runEvents {
            guard var context = observedRunContexts[runID] else { continue }
            if let seq = event.seq {
                if seq <= context.lastEventSeq {
                    continue
                }
                context.lastEventSeq = seq
            } else {
                let eventID = event.eventID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !eventID.isEmpty {
                    if context.seenEventIDs.contains(eventID) {
                        continue
                    }
                    context.seenEventIDs.insert(eventID)
                } else {
                    let fingerprint = "\(event.type)|\(event.actionIndex ?? -1)|\(event.message)"
                    if context.seenEventFingerprints.contains(fingerprint) {
                        continue
                    }
                    context.seenEventFingerprints.insert(fingerprint)
                }
            }
            context.events.append(event)
            observedRunContexts[runID] = context
            if activeThreadID == threadID, self.runID == runID {
                events = context.events
            }
            updateRunPhase(for: event, threadID: threadID)
            if let text = conversationText(for: event, threadID: threadID) {
                appendConversation(role: "assistant", text: text, to: threadID)
            }
        }
    }

    private func updateRunPhase(for event: ExecutionEvent, threadID: UUID) {
        guard activeThreadID == threadID else { return }
        switch event.type {
        case "run.started":
            if isLoading { runPhaseText = "Planning" }
        case "action.started", "action.stdout", "action.stderr", "action.completed":
            if isLoading { runPhaseText = "Executing" }
        case "chat.message", "assistant.message":
            if isLoading { runPhaseText = "Summarizing" }
        case "run.completed":
            runPhaseText = "Completed"
            if runEndedAt == nil {
                runEndedAt = Date()
            }
        case "run.blocked":
            runPhaseText = "Needs Input"
            if runEndedAt == nil {
                runEndedAt = Date()
            }
        case "run.failed", "run.rejected":
            runPhaseText = "Failed"
            if runEndedAt == nil {
                runEndedAt = Date()
            }
        case "run.cancelled":
            runPhaseText = "Cancelled"
            if runEndedAt == nil {
                runEndedAt = Date()
            }
        default:
            return
        }
    }

    private func conversationText(for event: ExecutionEvent, threadID: UUID) -> String? {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if isContextLeak(message) { return nil }
        let lastSubmitted = lastSubmittedUserMessage(for: threadID)
        let executor = runExecutor(for: threadID)
        switch event.type {
        case "chat.message":
            if message.isEmpty { return nil }
            if let envelope = parseEnvelope(message),
               envelope.sections.isEmpty,
               envelope.agendaItems.isEmpty,
               envelope.summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "run completed successfully" {
                return nil
            }
            return message
        case "assistant.message":
            if message.isEmpty { return nil }
            if message == lastSubmitted?.text { return nil }
            return message
        case "log.message", "action.stdout", "action.stderr":
            return nil
        case "action.completed":
            if executor != "local" { return nil }
            if message.isEmpty { return nil }
            return message
        case "run.failed":
            return message
        case "run.blocked":
            return nil
        case "run.cancelled":
            return message
        default:
            return nil
        }
    }

    private func appendConversation(role: String, text: String, to threadID: UUID? = nil) {
        appendConversation(ConversationMessage(role: role, text: text), to: threadID)
    }

    private func appendConversation(_ message: ConversationMessage, to threadID: UUID? = nil) {
        let targetThreadID = threadID ?? activeThreadID
        guard let targetThreadID else { return }

        let preparedText = message.role == "assistant" ? normalizeAssistantText(message.text) : message.text
        let normalized = ConversationMessage(
            id: message.id,
            role: message.role,
            text: preparedText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: message.attachments
        )
        guard !normalized.text.isEmpty || !normalized.attachments.isEmpty else { return }
        var threadConversation = cachedConversation(for: targetThreadID)
        let threadStatus = statusText(for: targetThreadID)

        if normalized.role == "assistant",
           shouldCoalesceAssistantProgress(with: normalized.text),
           let last = threadConversation.last,
           last.role == "assistant",
           isProgressAssistantMessage(last.text),
           !isTerminalStatusText(threadStatus) {
            threadConversation[threadConversation.count - 1] = normalized
            storeConversation(threadConversation, for: targetThreadID)
            persistConversationMessage(normalized, at: threadConversation.count - 1, threadID: targetThreadID)
            persistThreadSnapshot(threadID: targetThreadID)
            return
        }
        if let last = threadConversation.last, last.role == normalized.role {
            if last.text == normalized.text && last.attachments == normalized.attachments {
                return
            }
            if normalized.role == "assistant" {
                // Keep assistant updates as separate bubbles for readability.
                threadConversation.append(normalized)
                storeConversation(threadConversation, for: targetThreadID)
                persistConversationMessage(normalized, at: threadConversation.count - 1, threadID: targetThreadID)
                persistThreadSnapshot(threadID: targetThreadID)
                return
            }
        }
        threadConversation.append(normalized)
        storeConversation(threadConversation, for: targetThreadID)
        persistConversationMessage(normalized, at: threadConversation.count - 1, threadID: targetThreadID)
        if normalized.role == "user",
           let idx = threadIndex(for: targetThreadID),
           threads[idx].title == "New Chat" {
            threads[idx].title = suggestThreadTitle(for: normalized)
        }
        persistThreadSnapshot(threadID: targetThreadID)
    }

    private func normalizeAssistantText(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        return out
    }

    private func shouldCoalesceAssistantProgress(with text: String) -> Bool {
        isProgressAssistantMessage(text)
    }

    private func isProgressAssistantMessage(_ text: String) -> Bool {
        if let envelope = parseEnvelope(text) {
            if !envelope.agendaItems.isEmpty || !envelope.artifacts.isEmpty {
                return false
            }
            if envelope.sections.count > 1 {
                return false
            }
            if let section = envelope.sections.first {
                let lowerTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lowerTitle != "result" && lowerTitle != "status" {
                    return false
                }
                return looksLikeProgressSentence(section.body)
            }
            return looksLikeProgressSentence(envelope.summary)
        }
        return looksLikeProgressSentence(text)
    }

    private func looksLikeProgressSentence(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        if lower.contains("run completed successfully") || lower.contains("run failed") || lower.contains("```") {
            return false
        }
        let markers = [
            "checking ",
            "querying ",
            "pulling ",
            "reading ",
            "fetching ",
            "reformatting ",
            "processing ",
            "running ",
            "trying ",
            "retrying ",
            "i'll ",
            "i will ",
            "i'm ",
            "working on",
        ]
        return markers.contains { lower.contains($0) }
    }

    private func loadSettings() {
        migrateLegacyRunTimeoutDefaultIfNeeded()
        if let value = defaults.string(forKey: DefaultsKey.serverURL), !value.isEmpty {
            serverURL = value
        }
        let storedServerCandidates = defaults.stringArray(forKey: DefaultsKey.serverURLCandidates) ?? []
        let normalizedCurrentServer = normalized(serverURL)
        if !normalizedCurrentServer.isEmpty && storedServerCandidates.contains(normalizedCurrentServer) {
            connectionCandidateServerURLs = normalizedServerURLs(
                preferredServerURL: normalizedCurrentServer,
                additionalServerURLs: storedServerCandidates
            )
        } else if !normalizedCurrentServer.isEmpty {
            connectionCandidateServerURLs = [normalizedCurrentServer]
        } else {
            connectionCandidateServerURLs = normalizedServerURLs(additionalServerURLs: storedServerCandidates)
            if let preferred = connectionCandidateServerURLs.first {
                serverURL = preferred
            }
        }
        if let keychainToken = KeychainStore.load(service: "MOBaiLE", account: "api_token"),
           !keychainToken.isEmpty {
            apiToken = keychainToken
        } else if let value = defaults.string(forKey: DefaultsKey.apiToken), !value.isEmpty {
            apiToken = value
            KeychainStore.save(value: value, service: "MOBaiLE", account: "api_token")
            defaults.removeObject(forKey: DefaultsKey.apiToken)
        }
        if let value = defaults.string(forKey: DefaultsKey.sessionID), !value.isEmpty {
            sessionID = value
        }
        if let value = defaults.string(forKey: DefaultsKey.workingDirectory), !value.isEmpty {
            workingDirectory = value
        }
        if let value = defaults.string(forKey: DefaultsKey.runTimeoutSeconds), !value.isEmpty {
            runTimeoutSeconds = value
        }
        if let value = defaults.string(forKey: DefaultsKey.executor), !value.isEmpty {
            executor = value
        }
        if let value = defaults.string(forKey: DefaultsKey.responseMode), !value.isEmpty {
            responseMode = value == "verbose" ? "concise" : value
        }
        if responseMode != "concise" {
            responseMode = "concise"
        }
        if let value = defaults.string(forKey: DefaultsKey.agentGuidanceMode), !value.isEmpty {
            agentGuidanceMode = value
        }
        developerMode = defaults.bool(forKey: DefaultsKey.developerMode)
        if defaults.object(forKey: DefaultsKey.airPodsClickToRecordEnabled) == nil {
            airPodsClickToRecordEnabled = true
        } else {
            airPodsClickToRecordEnabled = defaults.bool(forKey: DefaultsKey.airPodsClickToRecordEnabled)
        }
        if defaults.object(forKey: DefaultsKey.hideDotFoldersInBrowser) == nil {
            hideDotFoldersInBrowser = true
        } else {
            hideDotFoldersInBrowser = defaults.bool(forKey: DefaultsKey.hideDotFoldersInBrowser)
        }
        if defaults.object(forKey: DefaultsKey.hapticCuesEnabled) == nil {
            hapticCuesEnabled = true
        } else {
            hapticCuesEnabled = defaults.bool(forKey: DefaultsKey.hapticCuesEnabled)
        }
        if defaults.object(forKey: DefaultsKey.audioCuesEnabled) == nil {
            audioCuesEnabled = true
        } else {
            audioCuesEnabled = defaults.bool(forKey: DefaultsKey.audioCuesEnabled)
        }
        if defaults.object(forKey: DefaultsKey.autoSendAfterSilenceEnabled) == nil {
            autoSendAfterSilenceEnabled = false
        } else {
            autoSendAfterSilenceEnabled = defaults.bool(forKey: DefaultsKey.autoSendAfterSilenceEnabled)
        }
        if let value = defaults.string(forKey: DefaultsKey.autoSendAfterSilenceSeconds), !value.isEmpty {
            autoSendAfterSilenceSeconds = value
        }
        hasSeenMicrophonePrimer = defaults.bool(forKey: DefaultsKey.microphonePrimerSeen)
        trustedPairHosts = Set(defaults.stringArray(forKey: DefaultsKey.trustedPairHosts) ?? [])
        refreshClientConnectionCandidates()
    }

    private func migrateLegacyRunTimeoutDefaultIfNeeded() {
        if defaults.bool(forKey: DefaultsKey.runTimeoutMigratedToZeroDefault) {
            return
        }
        defer {
            defaults.set(true, forKey: DefaultsKey.runTimeoutMigratedToZeroDefault)
        }

        let storedTimeout = defaults.string(forKey: DefaultsKey.runTimeoutSeconds)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard storedTimeout == "300" else { return }
        defaults.set("0", forKey: DefaultsKey.runTimeoutSeconds)
    }

    private func exchangePairCode(serverURLs: [String], pairCode: String, sessionID: String?) async {
        let resolvedServerURLs = normalizedServerURLs(additionalServerURLs: serverURLs)
        guard let primaryServerURL = resolvedServerURLs.first else {
            self.errorText = "Pairing failed"
            self.statusText = "Missing pairing server URL"
            return
        }
        let previousFallbacks = client.fallbackServerURLs
        client.fallbackServerURLs = Array(resolvedServerURLs.dropFirst())
        defer {
            client.fallbackServerURLs = previousFallbacks
            refreshClientConnectionCandidates()
        }
        do {
            let response = try await client.exchangePairingCode(
                serverURL: primaryServerURL,
                pairCode: pairCode,
                sessionID: sessionID ?? self.sessionID
            )
            self.apiToken = response.apiToken
            self.sessionID = response.sessionId
            self.applyAdvertisedServerURLs(
                primaryServerURL: response.serverURL ?? primaryServerURL,
                advertisedServerURLs: (response.serverURLs ?? []) + resolvedServerURLs,
                persist: false
            )
            self.backendSecurityMode = response.securityMode
            _ = try? await self.refreshRuntimeConfiguration()
            _ = try? await self.refreshSessionContextFromBackend()
            self.persistSettings()
            self.errorText = ""
            self.statusText = "Paired successfully (\(response.securityMode))"
            self.pendingPairing = nil
            self.persistActiveThreadSnapshot()
        } catch {
            self.errorText = error.localizedDescription
            self.statusText = "Pairing failed"
        }
    }

    private func normalized(_ rawURL: String) -> String {
        rawURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func displayModelName(_ rawModel: String?) -> String {
        let value = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "default" : value
    }

    private func normalizedExecutor(from rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if value == "local" || value == "codex" || value == "claude" {
            return value
        }
        return nil
    }

    private func normalizedAvailableExecutors(
        _ rawValues: [String]?,
        descriptors: [RuntimeExecutorDescriptor],
        defaultExecutor: String
    ) -> [String] {
        var values = (rawValues ?? []).compactMap(normalizedExecutor(from:))
        if values.isEmpty {
            values = descriptors
                .filter { $0.available && !$0.internalOnly }
                .compactMap { normalizedExecutor(from: $0.id) }
        }
        if let preferred = normalizedExecutor(from: defaultExecutor), !values.contains(preferred) {
            values.append(preferred)
        }
        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private func normalizedRuntimeExecutors(
        _ rawDescriptors: [RuntimeExecutorDescriptor]?,
        config: RuntimeConfig,
        defaultExecutor: String
    ) -> [RuntimeExecutorDescriptor] {
        var descriptors = (rawDescriptors ?? []).compactMap { descriptor -> RuntimeExecutorDescriptor? in
            guard let normalized = normalizedExecutor(from: descriptor.id) else { return nil }
            return RuntimeExecutorDescriptor(
                id: normalized,
                title: descriptor.title,
                kind: descriptor.kind,
                available: descriptor.available,
                isDefault: descriptor.isDefault,
                internalOnly: descriptor.internalOnly,
                model: descriptor.model
            )
        }

        if descriptors.isEmpty {
            descriptors = [
                RuntimeExecutorDescriptor(
                    id: "codex",
                    title: "Codex",
                    kind: "agent",
                    available: (config.availableExecutors ?? []).contains("codex"),
                    isDefault: defaultExecutor == "codex",
                    internalOnly: false,
                    model: config.codexModel
                ),
                RuntimeExecutorDescriptor(
                    id: "claude",
                    title: "Claude Code",
                    kind: "agent",
                    available: (config.availableExecutors ?? []).contains("claude"),
                    isDefault: defaultExecutor == "claude",
                    internalOnly: false,
                    model: config.claudeModel
                ),
                RuntimeExecutorDescriptor(
                    id: "local",
                    title: "Local fallback",
                    kind: "internal",
                    available: defaultExecutor == "local",
                    isDefault: defaultExecutor == "local",
                    internalOnly: true,
                    model: nil
                ),
            ]
        }

        if !descriptors.contains(where: { $0.id == "local" }) {
            descriptors.append(
                RuntimeExecutorDescriptor(
                    id: "local",
                    title: "Local fallback",
                    kind: "internal",
                    available: defaultExecutor == "local",
                    isDefault: defaultExecutor == "local",
                    internalOnly: true,
                    model: nil
                )
            )
        }
        return descriptors
    }

    private func normalizedTranscribeProvider(from rawValue: String?) -> String {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? "unknown" : value
    }

    private func clearRuntimeConfiguration() {
        backendSecurityMode = "unknown"
        backendDefaultExecutor = "codex"
        backendAvailableExecutors = ["codex"]
        backendTranscribeProvider = "unknown"
        backendTranscribeReady = false
        backendExecutorDescriptors = []
        backendSlashCommands = []
        backendWorkdirRoot = ""
    }

    private func isLocalOrPrivateHost(_ host: String) -> Bool {
        PairingHostRules.isLocalOrPrivateHost(host)
    }

    private func loadThreads() {
        threadStore.migrateLegacyThreadsIfNeeded(
            defaults: defaults,
            threadsKey: DefaultsKey.threads
        )
        let loaded = threadStore.loadThreads()
        if !loaded.isEmpty {
            threads = loaded
        } else {
            createNewThread()
        }

        if let rawID = defaults.string(forKey: DefaultsKey.activeThreadID),
           let uuid = UUID(uuidString: rawID),
           threads.contains(where: { $0.id == uuid }) {
            switchToThread(uuid)
            return
        }
        if let first = sortedThreads.first {
            switchToThread(first.id)
        }
    }

    private func persistActiveThreadSnapshot() {
        guard let threadID = activeThreadID else { return }
        persistThreadSnapshot(threadID: threadID)
    }

    private func persistThreadSnapshot(threadID: UUID) {
        guard !isRestoringThreadState, let idx = threadIndex(for: threadID) else { return }
        if activeThreadID == threadID {
            threads[idx].conversation = conversation
            threads[idx].runID = runID
            threads[idx].summaryText = summaryText
            threads[idx].transcriptText = transcriptText
            threads[idx].statusText = statusText
            threads[idx].resolvedWorkingDirectory = resolvedWorkingDirectory
            threads[idx].activeRunExecutor = activeRunExecutor
            threads[idx].draftText = promptText
            threads[idx].draftAttachments = draftAttachments
        }
        threads[idx].updatedAt = Date()
        threadStore.upsertThread(threads[idx])
    }

    private func persistDraftStateIfNeeded() {
        guard !isRestoringThreadState else { return }
        persistActiveThreadSnapshot()
    }

    private var hasFailedDraftAttachments: Bool {
        draftAttachments.contains { attachment in
            if case .failed = draftAttachmentTransferState(for: attachment) {
                return true
            }
            return false
        }
    }

    private func activeThreadIndex() -> Int? {
        guard let id = activeThreadID else { return nil }
        return threadIndex(for: id)
    }

    private func threadIndex(for threadID: UUID) -> Int? {
        threads.firstIndex(where: { $0.id == threadID })
    }

    private func cachedConversation(for threadID: UUID) -> [ConversationMessage] {
        if activeThreadID == threadID {
            return conversation
        }
        if let idx = threadIndex(for: threadID), !threads[idx].conversation.isEmpty {
            return threads[idx].conversation
        }
        let loaded = threadStore.loadMessages(threadID: threadID)
        if let idx = threadIndex(for: threadID) {
            threads[idx].conversation = loaded
        }
        return loaded
    }

    private func storeConversation(_ messages: [ConversationMessage], for threadID: UUID) {
        guard let idx = threadIndex(for: threadID) else { return }
        threads[idx].conversation = messages
        if activeThreadID == threadID {
            conversation = messages
            lastSubmittedUserMessage = messages.last(where: { $0.role == "user" })
        }
    }

    private func persistConversationMessage(_ message: ConversationMessage, at index: Int, threadID: UUID) {
        threadStore.upsertMessage(
            threadID: threadID,
            message: message,
            position: index
        )
    }

    private func updateThreadMetadata(
        threadID: UUID,
        runID: String? = nil,
        summaryText: String? = nil,
        transcriptText: String? = nil,
        statusText: String? = nil,
        resolvedWorkingDirectory: String? = nil,
        activeRunExecutor: String? = nil,
        persist: Bool = true
    ) {
        guard let idx = threadIndex(for: threadID) else { return }
        if let runID {
            threads[idx].runID = runID
        }
        if let summaryText {
            threads[idx].summaryText = summaryText
        }
        if let transcriptText {
            threads[idx].transcriptText = transcriptText
        }
        if let statusText {
            threads[idx].statusText = statusText
        }
        if let resolvedWorkingDirectory {
            threads[idx].resolvedWorkingDirectory = resolvedWorkingDirectory
        }
        if let activeRunExecutor {
            threads[idx].activeRunExecutor = activeRunExecutor
        }
        if activeThreadID == threadID {
            if let runID {
                self.runID = runID
            }
            if let summaryText {
                self.summaryText = summaryText
            }
            if let transcriptText {
                self.transcriptText = transcriptText
            }
            if let statusText {
                self.statusText = statusText
            }
            if let resolvedWorkingDirectory {
                self.resolvedWorkingDirectory = resolvedWorkingDirectory
            }
            if let activeRunExecutor {
                self.activeRunExecutor = activeRunExecutor
            }
        }
        if persist {
            persistThreadSnapshot(threadID: threadID)
        }
    }

    private func setThreadPendingHumanUnblock(
        threadID: UUID,
        request: HumanUnblockRequest?,
        persist: Bool = true
    ) {
        guard let idx = threadIndex(for: threadID) else { return }
        var thread = threads[idx]
        thread.pendingHumanUnblock = request
        threads[idx] = thread
        if persist {
            persistThreadSnapshot(threadID: threadID)
        }
    }

    private func statusText(for threadID: UUID) -> String {
        if activeThreadID == threadID {
            return statusText
        }
        return threads.first(where: { $0.id == threadID })?.statusText ?? "Idle"
    }

    private func runExecutor(for threadID: UUID) -> String {
        if activeThreadID == threadID {
            return activeRunExecutor
        }
        return threads.first(where: { $0.id == threadID })?.activeRunExecutor ?? effectiveExecutor
    }

    private func lastSubmittedUserMessage(for threadID: UUID) -> ConversationMessage? {
        if activeThreadID == threadID {
            return lastSubmittedUserMessage
        }
        return cachedConversation(for: threadID).last(where: { $0.role == "user" })
    }

    private func runID(for threadID: UUID) -> String {
        if activeThreadID == threadID {
            return runID
        }
        return threads.first(where: { $0.id == threadID })?.runID ?? ""
    }

    private func observedRunContext(for threadID: UUID, runID: String? = nil) -> ObservedRunContext? {
        let resolvedRunID = (runID ?? self.runID(for: threadID)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedRunID.isEmpty else { return nil }
        guard let context = observedRunContexts[resolvedRunID], context.threadID == threadID else {
            return nil
        }
        return context
    }

    private func removeObservedRunContext(runID: String) {
        let trimmedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRunID.isEmpty else { return }
        observedRunContexts.removeValue(forKey: trimmedRunID)
        if self.runID == trimmedRunID {
            events = []
        }
    }

    private func clearObservedRunContext(for threadID: UUID?) {
        guard let threadID else { return }
        removeObservedRunContext(runID: runID(for: threadID))
    }

    private func ensureObservedRunContext(runID: String, threadID: UUID) {
        if observedRunContexts[runID]?.threadID == threadID {
            return
        }
        observedRunContexts[runID] = ObservedRunContext(runID: runID, threadID: threadID)
    }

    private func performThreadStateRestore(_ updates: () -> Void) {
        isRestoringThreadState = true
        updates()
        isRestoringThreadState = false
    }

    private func availableDraftAttachments(from attachments: [DraftAttachment]) -> [DraftAttachment] {
        attachments.filter { FileManager.default.fileExists(atPath: $0.localFileURL.path) }
    }

    private func deleteDraftAttachments(_ attachments: [DraftAttachment]) {
        clearDraftAttachmentTransferStates(for: attachments)
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.localFileURL)
        }
    }

    private func setDraftAttachmentTransferState(_ state: DraftAttachmentTransferState, for attachmentID: UUID) {
        switch state {
        case .idle:
            draftAttachmentTransferStates.removeValue(forKey: attachmentID)
        default:
            draftAttachmentTransferStates[attachmentID] = state
        }
    }

    private func clearDraftAttachmentTransferState(for attachmentID: UUID) {
        draftAttachmentTransferStates.removeValue(forKey: attachmentID)
    }

    private func clearDraftAttachmentTransferStates(for attachments: [DraftAttachment]) {
        let ids = Set(attachments.map(\.id))
        guard !ids.isEmpty else { return }
        draftAttachmentTransferStates = draftAttachmentTransferStates.filter { !ids.contains($0.key) }
    }

    private func cancelActiveAttachmentUploadIfNeeded() {
        guard let cancel = activeAttachmentUploadCancellation else { return }
        errorText = ""
        statusText = "Cancelling upload..."
        runPhaseText = "Cancelling"
        activeAttachmentUploadCancellation = nil
        cancel()
    }

    private func isAttachmentTransferCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func summarizedAttachmentTransferError(_ error: Error) -> String {
        let collapsed = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "Upload failed." }
        if collapsed.count <= 72 {
            return collapsed
        }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: 72)
        return String(collapsed[..<cut]) + "..."
    }

    private func suggestThreadTitle(for message: ConversationMessage) -> String {
        let collapsed = message.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !collapsed.isEmpty {
            if collapsed.count <= 42 {
                return collapsed
            }
            let cut = collapsed.index(collapsed.startIndex, offsetBy: 42)
            return String(collapsed[..<cut]) + "..."
        }
        if message.attachments.count == 1 {
            let name = message.attachments[0].title.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Attachment" : name
        }
        return "\(message.attachments.count) attachments"
    }

    private func isTerminalStatusText(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("completed") || lower.contains("failed") || lower.contains("cancelled") || lower.contains("rejected") || lower.contains("blocked")
    }

    private func phaseText(forStatusText value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("cancel") { return "Cancelled" }
        if lower.contains("fail") || lower.contains("rejected") { return "Failed" }
        if lower.contains("complete") { return "Completed" }
        if lower.contains("running") { return "Executing" }
        if lower.contains("starting") { return "Planning" }
        return "Idle"
    }

    private func phaseText(forRunStatus status: String) -> String {
        switch status.lowercased() {
        case "completed":
            return "Completed"
        case "blocked":
            return "Needs Input"
        case "failed", "rejected":
            return "Failed"
        case "cancelled":
            return "Cancelled"
        case "running":
            return "Executing"
        default:
            return "Planning"
        }
    }

    private func isContextLeak(_ message: String) -> Bool {
        let lower = message.lowercased()
        let markers = [
            "you are the coding agent used by mobaile",
            "you run on the user's server/computer",
            "your stdout is streamed to a phone ui",
            "product intent:",
            "mobaile makes a user's computer available from their phone",
            "primary users are software engineers who run coding agents while away from the computer",
            "secondary use cases include normal remote productivity tasks",
            "output style for phone ux:",
            "prefer short status + result summaries",
            "environment notes:",
            "keep responses concise and grouped",
            "do not repeat or summarize this runtime context",
        ]
        return markers.contains { lower.contains($0) }
    }

    private func parseEnvelope(_ rawText: String) -> ChatEnvelope? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ChatEnvelope.self, from: data) {
            return parsed
        }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data),
           let second = decoded.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ChatEnvelope.self, from: second) {
            return parsed
        }
        return nil
    }

    private func humanUnblockRequest(from rawText: String) -> HumanUnblockRequest? {
        guard let envelope = parseEnvelope(rawText) else { return nil }
        guard let section = envelope.sections.first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "human unblock"
        }) else {
            return nil
        }
        let instructions = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return nil }
        return HumanUnblockRequest(instructions: instructions)
    }

    private func maybeAutoFixWorkingDirectory(from error: Error) {
        guard let apiError = error as? APIError else { return }
        guard case let .httpError(code, body) = apiError else { return }
        guard code == 400 else { return }
        let marker = "working_directory must stay inside "
        guard let markerRange = body.range(of: marker) else { return }
        let tail = body[markerRange.upperBound...]
        var corrected = ""
        for ch in tail {
            if ch == "\"" || ch == "}" || ch == "," {
                break
            }
            corrected.append(ch)
        }
        corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return }
        backendWorkdirRoot = corrected
        workingDirectory = corrected
        persistSettings()
    }

    func _test_bindObservedRun(runID: String, threadID: UUID) {
        ensureObservedRunContext(runID: runID, threadID: threadID)
    }

    func _test_updateThreadMetadata(
        threadID: UUID,
        runID: String? = nil,
        statusText: String? = nil,
        activeRunExecutor: String? = nil
    ) {
        updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: statusText,
            activeRunExecutor: activeRunExecutor
        )
    }

    func _test_ingestRunEvents(_ runEvents: [ExecutionEvent], runID: String, threadID: UUID) {
        ingestEvents(runEvents, runID: runID, threadID: threadID)
    }

    func _test_composeVoiceUtteranceText(draftText: String, transcriptText: String) -> String {
        composeVoiceUtteranceText(draftText: draftText, transcriptText: transcriptText)
    }

    func _test_setVoiceModeEnabled(_ enabled: Bool, threadID: UUID?) {
        if enabled {
            voiceModeEnabled = true
            voiceModeThreadID = threadID
            return
        }
        deactivateVoiceMode(stopSpeaking: false)
    }

    func _test_usesAutoSendForCurrentTurn() -> Bool {
        usesAutoSendForCurrentTurn
    }
}
