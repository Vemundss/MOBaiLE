import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

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

    struct ConnectionRepairState: Equatable {
        let title: String
        let message: String
    }

    private struct PersistedConnectionRepairState: Codable {
        let title: String
        let message: String
    }

    private struct ObservedRunContext {
        let runID: String
        let threadID: UUID
        var lastEventSeq: Int = -1
        var seenEventIDs: Set<String> = []
        var seenEventFingerprints: Set<String> = []
        var events: [ExecutionEvent] = []
        var liveActivityMessageID: UUID?
        var hasReceivedFinalAssistantMessage = false
        var finalAssistantReplyText: String?
        var shouldSpeakReply = false
    }

    enum VoiceInputPhase: Equatable {
        case idle
        case transcribing
        case startingRun
        case uploadingAudio

        var isActive: Bool {
            self != .idle
        }

        var cancelAccessibilityLabel: String {
            switch self {
            case .idle:
                return "Cancel run"
            case .transcribing:
                return "Cancel transcription"
            case .startingRun:
                return "Cancel voice prompt"
            case .uploadingAudio:
                return "Cancel audio upload"
            }
        }
    }

    @Published var serverURL: String = ""
    @Published var apiToken: String = ""
    @Published var sessionID: String = "iphone-app"
    @Published var workingDirectory: String = "~"
    @Published var runTimeoutSeconds: String = "0"
    @Published var executor: String = "codex"
    @Published private(set) var runtimeSettingOverrides: [String: [String: String]] = [:]
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
    @Published private(set) var fetchedRunDiagnostics: RunDiagnostics?
    @Published private(set) var pagedRunLogEvents: [ExecutionEvent] = []
    @Published private(set) var canLoadOlderRunLogEvents = false
    @Published private(set) var isLoadingRunLogEvents = false
    @Published private(set) var runLogErrorText: String = ""
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
    @Published var backendCodexModelOptions: [String] = []
    @Published var backendCodexReasoningEffort: String = ""
    @Published var backendCodexReasoningEffortOptions: [String] = ["minimal", "low", "medium", "high", "xhigh"]
    @Published var backendClaudeModelOptions: [String] = []
    @Published var showDirectoryBrowser: Bool = false
    @Published var isLoadingDirectoryBrowser: Bool = false
    @Published var directoryBrowserEntries: [DirectoryEntry] = []
    @Published var directoryBrowserTruncated: Bool = false
    @Published var directoryBrowserError: String = ""
    @Published var directoryBrowserMissingPath: String = ""
    @Published var pendingPairing: PendingPairing?
    @Published private(set) var connectionRepairState: ConnectionRepairState?
    @Published var runPhaseText: String = "Idle"
    @Published var runStartedAt: Date?
    @Published var runEndedAt: Date?
    @Published var directoryBrowserPath: String = ""
    @Published var airPodsClickToRecordEnabled: Bool = true
    @Published var hideDotFoldersInBrowser: Bool = true
    @Published var hapticCuesEnabled: Bool = true
    @Published var audioCuesEnabled: Bool = true
    @Published var speakRepliesEnabled: Bool = true {
        didSet {
            if !speakRepliesEnabled, speaker.isSpeaking {
                speaker.stopSpeaking(at: .immediate)
            }
        }
    }
    @Published var autoSendAfterSilenceEnabled: Bool = false
    @Published var autoSendAfterSilenceSeconds: String = "1.2"
    @Published private(set) var voiceInteractionNoticeText: String?
    @Published private(set) var activeVoiceInputPhase: VoiceInputPhase = .idle

    let client = APIClient()
    private let speaker = AVSpeechSynthesizer()
    private let recorder: AudioRecording
    private let speechTranscriber = SpeechTranscriptionService()
    private let threadStore: ChatThreadStore
    let defaults: UserDefaults
    private let draftAttachmentDirectory: URL
    var pairedRefreshToken: String = ""
    private var lastSubmittedUserMessage: ConversationMessage?
    private var hasSeenMicrophonePrimer = false
    private var didBootstrapSession = false
    var trustedPairHosts: Set<String> = []
    var connectionCandidateServerURLs: [String] = []
    private var didConfigureRemoteCommands = false
    private var isRestoringThreadState = false
    private var activeAttachmentUploadCancellation: (() -> Void)?
    private var activeVoiceInputCancellation: (() -> Void)?
    private var activeVoiceInputRunID: String?
    private var didCancelAttachmentUpload = false
    private var didCancelVoiceInputPreparation = false
    private var pendingDraftPersistenceTask: Task<Void, Never>?
    private var backendTranscribeProvider: String = "unknown"
    private var backendTranscribeReady = false
    private var observedRunContexts: [String: ObservedRunContext] = [:]
    private var pagedRunLogRunID: String?
    private var nextRunLogBeforeSeq: Int?
    var lastHydratedSessionContextID: String?
    var lastHydratedSessionContextServerURL: String?
    private var voiceModeThreadID: UUID?
    private var lastVoiceModeThreadID: UUID?
    private var shouldResumeVoiceModeAfterSpeech = false
    var credentialRefreshTask: Task<String?, Error>?
    private var clearVoiceInteractionNoticeTask: Task<Void, Never>?

    static let defaultCodexReasoningEffortOptions = ["minimal", "low", "medium", "high", "xhigh"]
    static let defaultCodexModelOptions = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.1"]
    static let defaultClaudeModelOptions = ["claude-sonnet-4-5"]
    static let globalAgentRuntimeSettingIDs: Set<String> = ["profile_agents", "profile_memory"]

    private var attachmentDraftService: AttachmentDraftService {
        AttachmentDraftService(draftDirectory: draftAttachmentDirectory)
    }

    var currentRunDiagnostics: RunDiagnostics? {
        let activeRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fetchedRunDiagnostics,
           !activeRunID.isEmpty,
           fetchedRunDiagnostics.runId == activeRunID {
            return fetchedRunDiagnostics
        }

        let hasVisibleRunState = !activeRunID.isEmpty
            || !events.isEmpty
            || !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard hasVisibleRunState else { return nil }

        return RunDiagnostics.derived(
            runId: activeRunID,
            status: statusText,
            summary: summaryText,
            events: events
        )
    }

    var visibleRunLogEvents: [ExecutionEvent] {
        let activeRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        if pagedRunLogRunID == activeRunID, !pagedRunLogEvents.isEmpty || canLoadOlderRunLogEvents {
            return pagedRunLogEvents
        }
        return events
    }

    deinit {
        pendingDraftPersistenceTask?.cancel()
        clearVoiceInteractionNoticeTask?.cancel()
    }

    private enum DefaultsKey {
        static let serverURL = "mobaile.server_url"
        static let serverURLCandidates = "mobaile.server_url_candidates"
        static let apiToken = "mobaile.api_token_legacy"
        static let sessionID = "mobaile.session_id"
        static let workingDirectory = "mobaile.working_directory"
        static let runTimeoutSeconds = "mobaile.run_timeout_seconds"
        static let runTimeoutMigratedToZeroDefault = "mobaile.run_timeout_migrated_to_zero_default"
        static let executor = "mobaile.executor"
        static let runtimeSettingOverrides = "mobaile.runtime_setting_overrides"
        static let codexModelOverride = "mobaile.codex_model_override"
        static let codexReasoningEffort = "mobaile.codex_reasoning_effort"
        static let claudeModelOverride = "mobaile.claude_model_override"
        static let responseMode = "mobaile.response_mode"
        static let agentGuidanceMode = "mobaile.agent_guidance_mode"
        static let developerMode = "mobaile.developer_mode"
        static let threads = "mobaile.threads"
        static let activeThreadID = "mobaile.active_thread_id"
        static let lastVoiceModeThreadID = "mobaile.last_voice_mode_thread_id"
        static let trustedPairHosts = "mobaile.trusted_pair_hosts"
        static let connectionRepairState = "mobaile.connection_repair_state"
        static let airPodsClickToRecordEnabled = "mobaile.airpods_click_to_record"
        static let hideDotFoldersInBrowser = "mobaile.hide_dot_folders"
        static let hapticCuesEnabled = "mobaile.haptic_cues_enabled"
        static let audioCuesEnabled = "mobaile.audio_cues_enabled"
        static let speakRepliesEnabled = "mobaile.speak_replies_enabled"
        static let autoSendAfterSilenceEnabled = "mobaile.auto_send_after_silence_enabled"
        static let autoSendAfterSilenceSeconds = "mobaile.auto_send_after_silence_seconds"
        static let microphonePrimerSeen = "mobaile.microphone_primer_seen"
        static let pendingShortcutAction = "mobaile.pending_shortcut_action"
    }

    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.threadStore = ChatThreadStore()
        self.defaults = .standard
        self.draftAttachmentDirectory = appSupport
            .appendingPathComponent("MOBaiLE", isDirectory: true)
            .appendingPathComponent("draft-attachments", isDirectory: true)
        self.recorder = AudioRecorderService()
        super.init()
        completeInitialization()
    }

    init(
        threadStore: ChatThreadStore,
        defaults: UserDefaults,
        draftAttachmentDirectory: URL,
        recorder: AudioRecording = AudioRecorderService()
    ) {
        self.threadStore = threadStore
        self.defaults = defaults
        self.draftAttachmentDirectory = draftAttachmentDirectory
        self.recorder = recorder
        super.init()
        completeInitialization()
    }

    private func completeInitialization() {
        try? FileManager.default.createDirectory(
            at: draftAttachmentDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        speaker.delegate = self
        speaker.usesApplicationAudioSession = false
        client.onResolvedServerURL = { [weak self] resolvedURL in
            Task { @MainActor in
                self?.promoteResolvedServerURL(resolvedURL)
            }
        }
        client.onUnauthorizedRecovery = { [weak self] resolvedURL in
            guard let self else { return nil }
            return try await self.silentlyRefreshPairingCredentials(preferredServerURL: resolvedURL)
        }
        loadSettings()
        loadThreads()
        if let previewScenario = PreviewScenario.current {
            applyPreviewScenario(previewScenario)
        }
        configureRemoteCommandsIfNeeded()
    }

    private func applyPreviewScenario(_ scenario: PreviewScenario) {
        let preview = VoiceAgentPreviewFactory.make(
            scenario: scenario,
            draftAttachmentDirectory: draftAttachmentDirectory,
            codexReasoningEffortOptions: Self.defaultCodexReasoningEffortOptions
        )
        serverURL = "https://demo.mobaile.app"
        connectionCandidateServerURLs = ["https://demo.mobaile.app"]
        apiToken = "preview-token"
        sessionID = "app-preview"
        workingDirectory = preview.workspace
        resolvedWorkingDirectory = preview.workspace
        backendWorkdirRoot = preview.workspace
        backendSecurityMode = "workspace-write"
        executor = "codex"
        activeRunExecutor = "codex"
        backendDefaultExecutor = "codex"
        backendAvailableExecutors = preview.executors.map(\.id)
        backendExecutorDescriptors = preview.executors
        backendCodexModelOptions = preview.codexModelOptions
        backendCodexReasoningEffort = preview.codexReasoningEffort
        backendCodexReasoningEffortOptions = preview.codexReasoningEffortOptions
        backendClaudeModelOptions = preview.claudeModelOptions
        backendSlashCommands = preview.slashCommands
        directoryBrowserPath = preview.workspace
        directoryBrowserEntries = []
        directoryBrowserError = ""
        directoryBrowserMissingPath = ""
        directoryBrowserTruncated = false
        showDirectoryBrowser = false
        events = preview.events
        fetchedRunDiagnostics = nil
        errorText = ""
        pendingPairing = nil
        setConnectionRepairState(preview.connectionRepairState, persist: false)
        didBootstrapSession = true
        draftAttachmentTransferStates = [:]
        codexModelOverride = ""
        codexReasoningEffort = ""
        claudeModelOverride = ""
        voiceModeEnabled = false
        voiceModeThreadID = nil
        isSpeakingReply = false
        shouldResumeVoiceModeAfterSpeech = false
        refreshClientConnectionCandidates()

        performThreadStateRestore {
            threads = preview.threads
            activeThreadID = preview.activeThreadID
            conversation = preview.conversation
            promptText = preview.promptText
            draftAttachments = preview.draftAttachments
            runID = preview.runID
            summaryText = preview.summaryText
            transcriptText = preview.transcriptText
            statusText = preview.statusText
            runPhaseText = preview.runPhaseText
            runStartedAt = preview.runStartedAt
            runEndedAt = preview.runEndedAt
            isLoading = preview.isLoading
            isRecording = preview.isRecording
            recordingStartedAt = preview.recordingStartedAt
            didCompleteRun = preview.didCompleteRun
            lastSubmittedUserMessage = preview.conversation.last(where: { $0.role == "user" })
            voiceModeEnabled = preview.voiceModeEnabled
            voiceModeThreadID = preview.voiceModeThreadID
            if let autoSendAfterSilenceEnabled = preview.autoSendAfterSilenceEnabled {
                self.autoSendAfterSilenceEnabled = autoSendAfterSilenceEnabled
            }
        }
    }

    func refreshRunDiagnosticsIfPossible() async {
        let activeRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activeRunID.isEmpty else {
            fetchedRunDiagnostics = nil
            return
        }
        guard PreviewScenario.current == nil else {
            fetchedRunDiagnostics = nil
            return
        }

        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else {
            fetchedRunDiagnostics = nil
            return
        }

        do {
            let diagnostics = try await client.fetchRunDiagnostics(
                serverURL: normalizedServerURL,
                token: token,
                runID: activeRunID
            )
            guard runID.trimmingCharacters(in: .whitespacesAndNewlines) == activeRunID else { return }
            fetchedRunDiagnostics = diagnostics
        } catch {
            guard runID.trimmingCharacters(in: .whitespacesAndNewlines) == activeRunID else { return }
            fetchedRunDiagnostics = nil
        }
    }

    func refreshRunLogsIfPossible() async {
        await refreshRunDiagnosticsIfPossible()
        let activeRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activeRunID.isEmpty else {
            resetRunLogPagination()
            return
        }
        guard PreviewScenario.current == nil else {
            resetRunLogPagination()
            return
        }
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else {
            resetRunLogPagination()
            return
        }

        isLoadingRunLogEvents = true
        defer { isLoadingRunLogEvents = false }
        runLogErrorText = ""
        do {
            let page = try await client.fetchRunEventsPage(
                serverURL: normalizedServerURL,
                token: token,
                runID: activeRunID,
                limit: 100
            )
            guard runID.trimmingCharacters(in: .whitespacesAndNewlines) == activeRunID else { return }
            pagedRunLogRunID = activeRunID
            pagedRunLogEvents = page.events
            canLoadOlderRunLogEvents = page.hasMoreBefore
            nextRunLogBeforeSeq = page.nextBeforeSeq
        } catch {
            guard runID.trimmingCharacters(in: .whitespacesAndNewlines) == activeRunID else { return }
            runLogErrorText = error.localizedDescription
        }
    }

    func loadOlderRunLogsIfPossible() async {
        let activeRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pagedRunLogRunID == activeRunID,
              canLoadOlderRunLogEvents,
              let beforeSeq = nextRunLogBeforeSeq else {
            return
        }
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else { return }

        isLoadingRunLogEvents = true
        defer { isLoadingRunLogEvents = false }
        runLogErrorText = ""
        do {
            let page = try await client.fetchRunEventsPage(
                serverURL: normalizedServerURL,
                token: token,
                runID: activeRunID,
                limit: 100,
                beforeSeq: beforeSeq
            )
            guard runID.trimmingCharacters(in: .whitespacesAndNewlines) == activeRunID else { return }
            let existingIDs = Set(pagedRunLogEvents.map(\.id))
            let olderEvents = page.events.filter { !existingIDs.contains($0.id) }
            pagedRunLogEvents = olderEvents + pagedRunLogEvents
            canLoadOlderRunLogEvents = page.hasMoreBefore
            nextRunLogBeforeSeq = page.nextBeforeSeq
        } catch {
            guard runID.trimmingCharacters(in: .whitespacesAndNewlines) == activeRunID else { return }
            runLogErrorText = error.localizedDescription
        }
    }

    private func resetRunLogPagination(for runID: String? = nil) {
        pagedRunLogRunID = runID
        pagedRunLogEvents = []
        canLoadOlderRunLogEvents = false
        nextRunLogBeforeSeq = nil
        isLoadingRunLogEvents = false
        runLogErrorText = ""
    }

    func sendPrompt() async {
        guard !needsConnectionRepair else {
            statusText = "Connection needs repair"
            errorText = connectionRepairMessage
            return
        }
        await submitPrompt(
            text: promptText,
            stagedAttachments: draftAttachments,
            existingAttachments: []
        )
    }

    @discardableResult
    func startRecording() async -> Bool {
        guard !isLoading else {
            statusText = "A run is already in progress."
            return false
        }
        guard !needsConnectionRepair else {
            statusText = "Connection needs repair"
            errorText = connectionRepairMessage
            return false
        }
        guard hasConfiguredConnection else {
            statusText = "Run setup on your computer or enter connection details first."
            return false
        }
        errorText = ""
        recordingStartedAt = nil
        do {
            shouldResumeVoiceModeAfterSpeech = false
            if speaker.isSpeaking {
                speaker.stopSpeaking(at: .immediate)
            }
            try await recorder.start(silenceConfig: activeSilenceConfig) { [weak self] in
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
            return true
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
            return false
        } catch {
            recordingStartedAt = nil
            errorText = error.localizedDescription
            statusText = "Failed to start recording"
            emitFailureFeedback()
            return false
        }
    }

    func cancelCurrentRun() async {
        let activeRun = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activeRun.isEmpty else {
            cancelActiveAttachmentUploadIfNeeded()
            return
        }
        guard isRunActivelyObserved(activeRun) else { return }
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
                            runID: activeRun,
                            eventsLimit: 0
                        )
                        if let activeThreadID {
                            applyTerminalRunStateIfNeeded(run, threadID: activeThreadID)
                        }
                        return
                    } catch {
                        _ = registerConnectionRepairIfNeeded(from: error)
                        errorText = error.localizedDescription
                        return
                    }
                }
                if let repairMessage = registerConnectionRepairIfNeeded(from: apiError) {
                    errorText = repairMessage
                    statusText = "Connection needs repair"
                    return
                }
                errorText = apiError.localizedDescription
            default:
                errorText = apiError.localizedDescription
            }
        } catch {
            if let repairMessage = registerConnectionRepairIfNeeded(from: error) {
                errorText = repairMessage
                statusText = "Connection needs repair"
                return
            }
            errorText = error.localizedDescription
        }
    }

    func cancelActiveOperation() {
        if isUploadingAttachments {
            cancelActiveAttachmentUploadIfNeeded()
            return
        }
        if cancelActiveVoiceInputIfNeeded() {
            return
        }
        guard isRunActivelyObserved(runID) else { return }
        Task { await cancelCurrentRun() }
    }

    func stopRecordingAndSend() async {
        guard isRecording else { return }
        let originThreadID = activeThreadID
        let stagedDraftText = promptText
        let stagedDraftAttachments = draftAttachments
        guard validateDraftAttachmentsBeforeSend(stagedDraftAttachments) else {
            return
        }
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
        didCancelVoiceInputPreparation = false
        activeVoiceInputCancellation = nil
        defer {
            activeVoiceInputCancellation = nil
            activeVoiceInputRunID = nil
            didCancelVoiceInputPreparation = false
            activeVoiceInputPhase = .idle
        }

        guard let audioFile = recorder.stop() else {
            deactivateVoiceModeAfterVoiceInputFailure(threadID: originThreadID)
            isLoading = false
            errorText = "No recorded audio file found."
            statusText = "Failed"
            runPhaseText = "Failed"
            runEndedAt = Date()
            return
        }

        do {
            var localTranscription: SpeechTranscriptionResult?
            var startedRunID = ""
            do {
                activeVoiceInputPhase = .transcribing
                runPhaseText = "Transcribing"
                statusText = "Transcribing on iPhone..."
                localTranscription = try await speechTranscriber.transcribeFile(
                    at: audioFile,
                    registerCancellation: { [weak self] cancel in
                        Task { @MainActor in
                            if self?.didCancelVoiceInputPreparation == true {
                                cancel()
                            } else {
                                self?.activeVoiceInputCancellation = cancel
                            }
                        }
                    }
                )
                activeVoiceInputCancellation = nil
                activeVoiceInputPhase = .idle
                try checkVoiceInputCancellation()
            } catch {
                activeVoiceInputCancellation = nil
                activeVoiceInputPhase = .idle
                if didCancelVoiceInputPreparation {
                    throw error
                }
                if await backendAudioUploadAvailable(forceRefresh: true) {
                    localTranscription = nil
                } else {
                    throw voiceInputUnavailableError(from: error)
                }
            }

            if let localTranscription {
                activeVoiceInputPhase = .startingRun
                let utteranceText = composeVoiceUtteranceText(
                    draftText: stagedDraftText,
                    transcriptText: localTranscription.text
                )
                let uploadedAttachments = try await uploadDraftAttachmentsIfNeeded(stagedDraftAttachments)
                try checkVoiceInputCancellation()
                let explicitAttachments = uploadedAttachments.map(\.artifact)
                if let originThreadID {
                    updateThreadMetadata(
                        threadID: originThreadID,
                        transcriptText: localTranscription.text,
                        lastSubmittedInputOrigin: .voice,
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
                        lastSubmittedInputOrigin: .voice,
                        persist: false
                    )
                } else {
                    statusText = "Starting run..."
                }
                let response = try await createUtteranceRun(
                    threadID: originThreadID,
                    utteranceText: utteranceText,
                    attachments: explicitAttachments,
                    registerCancellation: { [weak self] cancel in
                        Task { @MainActor in
                            if self?.didCancelVoiceInputPreparation == true {
                                cancel()
                            } else {
                                self?.activeVoiceInputCancellation = cancel
                            }
                        }
                    }
                )
                activeVoiceInputCancellation = nil
                try checkVoiceInputCancellation()
                startedRunID = response.runId
                if let originThreadID {
                    ensureObservedRunContext(runID: response.runId, threadID: originThreadID, inputOrigin: .voice)
                    updateThreadMetadata(
                        threadID: originThreadID,
                        runID: response.runId,
                        statusText: "Voice run started (\(response.runId))",
                        activeRunExecutor: effectiveExecutor,
                        persist: true
                    )
                    primeLiveActivityIfNeeded(
                        for: response.runId,
                        threadID: originThreadID,
                        text: initialLiveActivityText(
                            for: utteranceText,
                            includesAttachments: !explicitAttachments.isEmpty
                        )
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
                try attachmentDraftService.validateAudioFileForUpload(audioFile)
                if let originThreadID {
                    updateThreadMetadata(
                        threadID: originThreadID,
                        statusText: "Uploading audio to backend...",
                        activeRunExecutor: effectiveExecutor,
                        lastSubmittedInputOrigin: .voice,
                        persist: false
                    )
                } else {
                    statusText = "Uploading audio to backend..."
                }
                let uploadedAttachments = try await uploadDraftAttachmentsIfNeeded(stagedDraftAttachments)
                try checkVoiceInputCancellation()
                let explicitAttachments = uploadedAttachments.map(\.artifact)
                activeVoiceInputPhase = .uploadingAudio
                let pendingAudioRunID = UUID().uuidString
                activeVoiceInputRunID = pendingAudioRunID
                let response = try await client.createAudioRun(
                    serverURL: normalizedServerURL,
                    token: apiToken,
                    sessionID: sessionID,
                    threadID: originThreadID?.uuidString,
                    executor: effectiveExecutor,
                    workingDirectory: normalizedWorkingDirectory,
                    responseMode: effectiveResponseMode,
                    responseProfile: effectiveAgentGuidanceMode,
                    draftText: stagedDraftText,
                    attachments: explicitAttachments,
                    audioFileURL: audioFile,
                    runID: pendingAudioRunID,
                    registerCancellation: { [weak self] cancel in
                        Task { @MainActor in
                            if self?.didCancelVoiceInputPreparation == true {
                                cancel()
                            } else {
                                self?.activeVoiceInputCancellation = cancel
                            }
                        }
                    }
                )
                activeVoiceInputCancellation = nil
                activeVoiceInputRunID = nil
                activeVoiceInputPhase = .idle
                try checkVoiceInputCancellation()
                let utteranceText = composeVoiceUtteranceText(
                    draftText: stagedDraftText,
                    transcriptText: response.transcriptText
                )
                startedRunID = response.runId
                if let originThreadID {
                    ensureObservedRunContext(runID: response.runId, threadID: originThreadID, inputOrigin: .voice)
                    updateThreadMetadata(
                        threadID: originThreadID,
                        runID: response.runId,
                        transcriptText: response.transcriptText,
                        statusText: "Audio run started (\(response.runId))",
                        activeRunExecutor: effectiveExecutor,
                        lastSubmittedInputOrigin: .voice,
                        persist: false
                    )
                    primeLiveActivityIfNeeded(
                        for: response.runId,
                        threadID: originThreadID,
                        text: initialLiveActivityText(
                            for: utteranceText,
                            includesAttachments: !explicitAttachments.isEmpty
                        )
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
            activeVoiceInputCancellation = nil
            if didCancelVoiceInputPreparation || error is CancellationError || isAttachmentTransferCancellation(error) {
                deactivateVoiceModeAfterVoiceInputFailure(threadID: originThreadID)
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
            if let repairMessage = registerConnectionRepairIfNeeded(from: error) {
                deactivateVoiceModeAfterVoiceInputFailure(threadID: originThreadID)
                if activeThreadID == originThreadID {
                    errorText = repairMessage
                    statusText = "Connection needs repair"
                    isLoading = false
                    runPhaseText = "Reconnect"
                    runEndedAt = Date()
                } else if let originThreadID {
                    updateThreadMetadata(threadID: originThreadID, statusText: "Connection needs repair")
                }
                emitFailureFeedback()
                if let originThreadID {
                    persistThreadSnapshot(threadID: originThreadID)
                } else {
                    persistActiveThreadSnapshot()
                }
                return
            }
            maybeAutoFixWorkingDirectory(from: error)
            deactivateVoiceModeAfterVoiceInputFailure(threadID: originThreadID)
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
        discardActiveRecording()
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

    private func canStartVoiceMode() -> Bool {
        guard !needsConnectionRepair else {
            statusText = "Connection needs repair"
            errorText = connectionRepairMessage
            return false
        }
        guard hasConfiguredConnection else {
            statusText = "Run setup on your computer or enter connection details first."
            return false
        }
        return true
    }

    private func startExternalVoiceModeIfPossible() async {
        guard canStartVoiceMode() else { return }
        _ = prepareExternalVoiceResumeTarget()
        await startVoiceModeIfNeeded()
    }

    func toggleRecordingFromHeadsetControl() async {
        guard airPodsClickToRecordEnabled else { return }
        if isRecording {
            await stopRecordingAndSend()
        } else if !isLoading {
            await startExternalVoiceModeIfPossible()
        }
    }

    func handleStartVoiceTaskShortcut() async {
        guard !isRecording, !isLoading else { return }
        await startExternalVoiceModeIfPossible()
    }

    func handleStartNewVoiceThreadShortcut() async {
        if isRecording || isLoading {
            return
        }
        startNewChat()
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
        guard canStartVoiceMode() else {
            return
        }
        if activeThreadID == nil {
            createNewThread()
        }
        clearVoiceInteractionNotice()
        voiceModeEnabled = true
        voiceModeThreadID = activeThreadID
        rememberLastVoiceModeThread(activeThreadID)
        shouldResumeVoiceModeAfterSpeech = false
        errorText = ""
        if !isRecording && !isLoading {
            let didStartRecording = await startRecording()
            if !didStartRecording {
                deactivateVoiceMode(stopSpeaking: false)
            }
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

    func consumePendingShortcutActionIfNeeded() async {
        let action = defaults.string(forKey: DefaultsKey.pendingShortcutAction)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased() ?? ""
        guard !action.isEmpty else { return }
        defaults.removeObject(forKey: DefaultsKey.pendingShortcutAction)
        switch action {
        case "start-voice":
            await handleStartVoiceTaskShortcut()
        case "start-new-voice":
            await handleStartNewVoiceThreadShortcut()
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
            if let failure = draftAttachmentTransferState(for: attachment).failureMessage, !failure.isEmpty {
                return failure
            }
            return "\(attachment.fileName) needs attention. Check the file and send again, or remove it."
        }
        return "\(failedAttachments.count) attachments need attention. Check the files and send again, or remove them."
    }

    var draftAttachmentSummaryText: String? {
        attachmentDraftService.summaryText(for: draftAttachments)
    }

    var hasInvalidDraftAttachments: Bool {
        draftAttachments.contains { attachment in
            if case .failed = draftAttachmentTransferState(for: attachment) {
                return true
            }
            return false
        }
    }

    func addDraftAttachment(fromImportedFile sourceURL: URL) async {
        do {
            let attachment = try attachmentDraftService.stageImportedAttachment(from: sourceURL)
            appendDraftAttachment(attachment)
        } catch {
            errorText = "Couldn't add file: \(error.localizedDescription)"
        }
    }

    func addDraftAttachment(data: Data, fileName: String, mimeType: String?) async {
        do {
            let attachment = try attachmentDraftService.stageAttachmentData(data, fileName: fileName, mimeType: mimeType)
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

    func observeRun(runID: String, threadID: UUID?) async throws {
        guard let threadID else { return }
        ensureObservedRunContext(runID: runID, threadID: threadID)
        resetRunLogPagination(for: runID)
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
                    runID: runID,
                    eventsLimit: 0
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
                try await fetchAndIngestRunEventsPage(runID: runID, threadID: threadID)

                if isTerminalStatus(run.status) {
                    applyTerminalRunStateIfNeeded(run, threadID: threadID)
                    return
                }
            } catch {
                if let repairMessage = registerConnectionRepairIfNeeded(from: error) {
                    if activeThreadID == threadID {
                        isLoading = false
                        errorText = repairMessage
                        statusText = "Connection needs repair"
                        runPhaseText = "Reconnect"
                        runEndedAt = Date()
                    }
                    updateThreadMetadata(threadID: threadID, statusText: "Connection needs repair")
                    removeObservedRunContext(runID: runID)
                    persistThreadSnapshot(threadID: threadID)
                    return
                }
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

    private func fetchAndIngestRunEventsPage(runID: String, threadID: UUID) async throws {
        let lastSeq = observedRunContexts[runID]?.lastEventSeq ?? -1
        let page = try await client.fetchRunEventsPage(
            serverURL: normalizedServerURL,
            token: apiToken,
            runID: runID,
            limit: 500,
            afterSeq: lastSeq >= 0 ? lastSeq : nil
        )
        ingestEvents(page.events, runID: runID, threadID: threadID)
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
                        runID: runID,
                        eventsLimit: 0
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

    var canRetryLastPrompt: Bool {
        guard !isLoading, let lastSubmittedUserMessage else { return false }
        return !lastSubmittedUserMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !lastSubmittedUserMessage.attachments.isEmpty
    }

    var activeThreadTitle: String {
        guard let activeThreadID,
              let thread = threads.first(where: { $0.id == activeThreadID }) else {
            return "MOBaiLE"
        }
        let trimmed = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "MOBaiLE" : trimmed
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
        activeAttachmentUploadCancellation != nil ||
            draftAttachmentTransferStates.values.contains { $0.isUploading }
    }

    var isPreparingVoiceInput: Bool {
        activeVoiceInputPhase.isActive
    }

    var activeOperationCancelAccessibilityLabel: String {
        if isUploadingAttachments {
            return "Cancel upload"
        }
        if activeVoiceInputPhase.isActive {
            return activeVoiceInputPhase.cancelAccessibilityLabel
        }
        return "Cancel run"
    }

    var canCancelActiveOperation: Bool {
        isLoading && (
            isUploadingAttachments ||
            activeVoiceInputPhase.isActive ||
            activeVoiceInputCancellation != nil ||
            isRunActivelyObserved(runID)
        )
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

    func clearComposerText() {
        promptText = ""
        errorText = ""
    }

    func clearComposerDraft() {
        promptText = ""
        clearDraftAttachments()
        errorText = ""
    }

    private func uploadDraftAttachmentsIfNeeded(_ attachments: [DraftAttachment]) async throws -> [UploadResponse] {
        guard !attachments.isEmpty else { return [] }
        try attachmentDraftService.validateAttachmentsForSend(attachments)
        activeAttachmentUploadCancellation = nil
        didCancelAttachmentUpload = false
        defer {
            activeAttachmentUploadCancellation = nil
            didCancelAttachmentUpload = false
        }
        clearDraftAttachmentTransferStates(for: attachments)
        var uploaded: [UploadResponse] = []
        for (index, attachment) in attachments.enumerated() {
            if didCancelAttachmentUpload {
                throw CancellationError()
            }
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
                            if self?.didCancelAttachmentUpload == true {
                                cancel()
                            } else {
                                self?.activeAttachmentUploadCancellation = cancel
                            }
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
            if didCancelAttachmentUpload {
                clearDraftAttachmentTransferState(for: attachment.id)
                throw CancellationError()
            }
            activeAttachmentUploadCancellation = nil
            clearDraftAttachmentTransferState(for: attachment.id)
            uploaded.append(response)
        }
        return uploaded
    }

    private func submitPrompt(
        text rawText: String,
        stagedAttachments: [DraftAttachment],
        existingAttachments: [ChatArtifact]
    ) async {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !stagedAttachments.isEmpty || !existingAttachments.isEmpty else { return }
        guard !isLoading else {
            statusText = "A run is already in progress."
            return
        }
        guard validateDraftAttachmentsBeforeSend(stagedAttachments) else {
            return
        }
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
                    lastSubmittedInputOrigin: .text,
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
                ensureObservedRunContext(runID: response.runId, threadID: originThreadID, inputOrigin: .text)
                updateThreadMetadata(
                    threadID: originThreadID,
                    runID: response.runId,
                    statusText: "Run started (\(response.runId))",
                    activeRunExecutor: effectiveExecutor
                )
                primeLiveActivityIfNeeded(
                    for: response.runId,
                    threadID: originThreadID,
                    text: initialLiveActivityText(
                        for: trimmedText,
                        includesAttachments: !explicitAttachments.isEmpty
                    )
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
            if let repairMessage = registerConnectionRepairIfNeeded(from: error) {
                if activeThreadID == originThreadID {
                    errorText = repairMessage
                    statusText = "Connection needs repair"
                    isLoading = false
                    runPhaseText = "Reconnect"
                    runEndedAt = Date()
                } else if let originThreadID {
                    updateThreadMetadata(threadID: originThreadID, statusText: "Connection needs repair")
                }
                emitFailureFeedback()
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
        attachments: [ChatArtifact],
        registerCancellation: ((@escaping () -> Void) -> Void)? = nil
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
                executor: effectiveExecutor,
                workingDirectory: normalizedWorkingDirectory,
                responseMode: effectiveResponseMode,
                responseProfile: effectiveAgentGuidanceMode
            ),
            registerCancellation: registerCancellation
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

    private func validateDraftAttachmentsBeforeSend(_ attachments: [DraftAttachment]) -> Bool {
        guard !attachments.isEmpty else { return true }
        clearDraftAttachmentTransferStates(for: attachments)
        for attachment in attachments {
            do {
                try attachmentDraftService.validateAttachmentsForSend([attachment])
            } catch {
                setDraftAttachmentTransferState(
                    .failed(message: summarizedAttachmentTransferError(error)),
                    for: attachment.id
                )
                errorText = error.localizedDescription
                statusText = "Attachment needs attention"
                return false
            }
        }
        return true
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
                    await self.startExternalVoiceModeIfPossible()
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
        preferHighestReachabilityServerURL()
        defaults.set(serverURL, forKey: DefaultsKey.serverURL)
        defaults.set(connectionCandidateServerURLs, forKey: DefaultsKey.serverURLCandidates)
        if !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainStore.save(value: apiToken, service: "MOBaiLE", account: "api_token")
            defaults.removeObject(forKey: DefaultsKey.apiToken)
            if !pairedRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                KeychainStore.save(value: pairedRefreshToken, service: "MOBaiLE", account: "refresh_token")
            } else {
                KeychainStore.delete(service: "MOBaiLE", account: "refresh_token")
            }
        } else {
            KeychainStore.delete(service: "MOBaiLE", account: "api_token")
            KeychainStore.delete(service: "MOBaiLE", account: "refresh_token")
            defaults.removeObject(forKey: DefaultsKey.apiToken)
        }
        defaults.set(sessionID, forKey: DefaultsKey.sessionID)
        defaults.set(workingDirectory, forKey: DefaultsKey.workingDirectory)
        defaults.set(runTimeoutSeconds, forKey: DefaultsKey.runTimeoutSeconds)
        defaults.set(executor, forKey: DefaultsKey.executor)
        if let data = try? JSONEncoder().encode(runtimeSettingOverrides) {
            defaults.set(data, forKey: DefaultsKey.runtimeSettingOverrides)
        } else {
            defaults.removeObject(forKey: DefaultsKey.runtimeSettingOverrides)
        }
        defaults.set(codexModelOverride, forKey: DefaultsKey.codexModelOverride)
        defaults.set(codexReasoningEffort, forKey: DefaultsKey.codexReasoningEffort)
        defaults.set(claudeModelOverride, forKey: DefaultsKey.claudeModelOverride)
        defaults.set("concise", forKey: DefaultsKey.responseMode)
        defaults.set(agentGuidanceMode, forKey: DefaultsKey.agentGuidanceMode)
        defaults.set(developerMode, forKey: DefaultsKey.developerMode)
        defaults.set(airPodsClickToRecordEnabled, forKey: DefaultsKey.airPodsClickToRecordEnabled)
        defaults.set(hideDotFoldersInBrowser, forKey: DefaultsKey.hideDotFoldersInBrowser)
        defaults.set(hapticCuesEnabled, forKey: DefaultsKey.hapticCuesEnabled)
        defaults.set(audioCuesEnabled, forKey: DefaultsKey.audioCuesEnabled)
        defaults.set(speakRepliesEnabled, forKey: DefaultsKey.speakRepliesEnabled)
        defaults.set(autoSendAfterSilenceEnabled, forKey: DefaultsKey.autoSendAfterSilenceEnabled)
        normalizeAutoSendAfterSilenceSetting()
        defaults.set(autoSendAfterSilenceSeconds, forKey: DefaultsKey.autoSendAfterSilenceSeconds)
        refreshClientConnectionCandidates()
        updateRemoteCommandState()
    }

    func bootstrapSessionIfNeeded() async {
        guard !didBootstrapSession else { return }
        guard !normalizedServerURL.isEmpty, !apiToken.isEmpty, !sessionID.isEmpty else { return }
        didBootstrapSession = true
        do {
            await ensureRefreshCredentialIfPossible()
            if needsConnectionRepair {
                return
            }
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
            if registerConnectionRepairIfNeeded(from: error) != nil {
                statusText = "Connection needs repair"
            }
        }
    }

    var sortedThreads: [ChatThread] {
        threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func switchToThread(_ threadID: UUID) {
        guard let idx = threadIndex(for: threadID) else { return }
        clearVoiceInteractionNotice()
        if activeThreadID != threadID {
            discardActiveRecording()
        }
        if voiceModeEnabled, voiceModeThreadID != threadID {
            deactivateVoiceMode(stopSpeaking: true)
            publishVoiceInteractionNotice("Voice mode ended")
        }
        persistActiveThreadSnapshot()
        fetchedRunDiagnostics = nil
        let thread = threads[idx]
        let restoredAttachments = availableDraftAttachments(from: thread.draftAttachments)
        let restoredConversation = threadStore.loadMessages(threadID: threadID)
        let restoredRunID = thread.runID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !restoredRunID.isEmpty,
           !isTerminalStatusText(thread.statusText),
           restoredConversation.contains(where: {
               $0.presentation == .liveActivity && $0.sourceRunID == restoredRunID
           }) {
            ensureObservedRunContext(runID: restoredRunID, threadID: threadID)
        }
        let restoredEvents = observedRunContext(for: threadID, runID: thread.runID)?.events ?? []
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
        fetchedRunDiagnostics = nil
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
            lastSubmittedInputOrigin: .text,
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
        if lastVoiceModeThreadID == threadID {
            rememberLastVoiceModeThread(nil)
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
        do {
            let cfg = try await client.fetchRuntimeConfig(
                serverURL: normalizedServerURL,
                token: apiToken
            )
            let activeServerURL = normalizedServerURL
            clearConnectionRepairState()
            applyAdvertisedServerURLs(
                primaryServerURL: activeServerURL,
                advertisedServerURLs: [cfg.serverURL].compactMap { $0 } + (cfg.serverURLs ?? []),
                persist: true
            )
            backendSecurityMode = cfg.securityMode
            backendDefaultExecutor = normalizedExecutor(from: cfg.defaultExecutor) ?? "codex"
            backendExecutorDescriptors = RuntimeConfigurationCatalog.normalizedRuntimeExecutors(
                cfg.executors,
                config: cfg,
                defaultExecutor: backendDefaultExecutor,
                inputs: runtimeLegacySettingInputs,
                defaults: runtimeCatalogDefaults
            )
            backendAvailableExecutors = RuntimeConfigurationCatalog.normalizedAvailableExecutors(
                cfg.availableExecutors,
                descriptors: backendExecutorDescriptors,
                defaultExecutor: backendDefaultExecutor
            )
            backendTranscribeProvider = RuntimeConfigurationCatalog.normalizedTranscribeProvider(from: cfg.transcribeProvider)
            backendTranscribeReady = cfg.transcribeReady ?? false
            backendWorkdirRoot = cfg.workdirRoot ?? ""
            let codexSetting = backendExecutorDescriptors
                .first(where: { $0.id == "codex" })?
                .settings?
                .first(where: { $0.id == "model" })
            let advertisedCodexModels = ((cfg.codexModelOptions ?? []).isEmpty
                ? (codexSetting?.options ?? [])
                : (cfg.codexModelOptions ?? []))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            backendCodexModelOptions = advertisedCodexModels.isEmpty
                ? Self.defaultCodexModelOptions
                : RuntimeConfigurationCatalog.dedupedModelOptions(advertisedCodexModels)
            let codexEffortSetting = backendExecutorDescriptors
                .first(where: { $0.id == "codex" })?
                .settings?
                .first(where: { $0.id == "reasoning_effort" })
            backendCodexReasoningEffort = (
                cfg.codexReasoningEffort
                ?? codexEffortSetting?.value
            )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let advertisedEffortOptions = ((cfg.codexReasoningEffortOptions ?? []).isEmpty
                ? (codexEffortSetting?.options ?? [])
                : (cfg.codexReasoningEffortOptions ?? []))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            backendCodexReasoningEffortOptions = advertisedEffortOptions.isEmpty
                ? Self.defaultCodexReasoningEffortOptions
                : advertisedEffortOptions
            let claudeSetting = backendExecutorDescriptors
                .first(where: { $0.id == "claude" })?
                .settings?
                .first(where: { $0.id == "model" })
            let advertisedClaudeModels = ((cfg.claudeModelOptions ?? []).isEmpty
                ? (claudeSetting?.options ?? [])
                : (cfg.claudeModelOptions ?? []))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            backendClaudeModelOptions = advertisedClaudeModels.isEmpty
                ? Self.defaultClaudeModelOptions
                : RuntimeConfigurationCatalog.dedupedModelOptions(advertisedClaudeModels)
            let slashDescriptors = try await client.fetchSlashCommands(
                serverURL: normalizedServerURL,
                token: apiToken
            )
            backendSlashCommands = slashDescriptors.map(ComposerSlashCommand.init(descriptor:))
            if normalizedExecutor(from: executor) == nil {
                executor = backendDefaultExecutor
            }
            return cfg
        } catch {
            _ = registerConnectionRepairIfNeeded(from: error)
            throw error
        }
    }

    @discardableResult
    private func speak(_ text: String) -> Bool {
        guard speakRepliesEnabled else { return false }
        guard let spoken = spokenTextForPlayback(from: text) else { return false }
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.prefersAssistiveTechnologySettings = true
        utterance.preUtteranceDelay = 0.02
        utterance.postUtteranceDelay = 0.08
        speaker.speak(utterance)
        return true
    }

    private func scheduleVoiceModeResumeAfterCurrentReply(threadID: UUID, replyText: String) {
        guard voiceModeEnabled, voiceModeThreadID == threadID else {
            if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speak(replyText)
            }
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
        if !speak(spokenReply) {
            Task { @MainActor in
                await self.resumeVoiceModeAfterSpokenReplyIfNeeded()
            }
        }
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

    func runtimeSettingOverrideValue(for settingID: String, executor: String) -> String {
        let normalizedExecutorValue = normalizedExecutor(from: executor) ?? executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        return runtimeSettingOverrides[normalizedExecutorValue]?[normalizedSettingID] ?? ""
    }

    func updateRuntimeSettingOverride(_ value: String?, for settingID: String, executor: String) {
        let normalizedExecutorValue = normalizedExecutor(from: executor) ?? executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
        guard !normalizedExecutorValue.isEmpty, !normalizedSettingID.isEmpty else { return }

        let normalizedValue: String? = {
            guard let text = normalizedRuntimeSettingText(value) else { return nil }
            if normalizedSettingID == "reasoning_effort" {
                return text.lowercased()
            }
            return text
        }()

        var next = runtimeSettingOverrides
        for targetExecutor in runtimeSettingTargetExecutors(
            for: normalizedSettingID,
            preferredExecutor: normalizedExecutorValue
        ) {
            var executorOverrides = next[targetExecutor] ?? [:]
            if let normalizedValue {
                executorOverrides[normalizedSettingID] = normalizedValue
            } else {
                executorOverrides.removeValue(forKey: normalizedSettingID)
            }

            if executorOverrides.isEmpty {
                next.removeValue(forKey: targetExecutor)
            } else {
                next[targetExecutor] = executorOverrides
            }
        }

        if next != runtimeSettingOverrides {
            runtimeSettingOverrides = next
        }
    }

    private func runtimeSettingTargetExecutors(for settingID: String, preferredExecutor: String) -> [String] {
        guard Self.globalAgentRuntimeSettingIDs.contains(settingID) else {
            return [preferredExecutor]
        }
        var values = backendExecutorDescriptors
            .filter { $0.kind == "agent" }
            .map(\.id)
        if values.isEmpty {
            values = ["codex", "claude"]
        }
        if !values.contains(preferredExecutor) {
            values.insert(preferredExecutor, at: 0)
        }
        return values
    }

    private func normalizedRuntimeSettingOverrides(_ raw: [String: [String: String]]) -> [String: [String: String]] {
        var normalized: [String: [String: String]] = [:]
        for (executorID, settings) in raw {
            let normalizedExecutorValue = normalizedExecutor(from: executorID) ?? executorID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedExecutorValue.isEmpty else { continue }

            var normalizedSettings: [String: String] = normalized[normalizedExecutorValue] ?? [:]
            for (settingID, value) in settings {
                let normalizedSettingID = normalizedRuntimeSettingIdentifier(settingID)
                guard !normalizedSettingID.isEmpty else { continue }
                guard let normalizedValue = normalizedRuntimeSettingText(value) else {
                    normalizedSettings.removeValue(forKey: normalizedSettingID)
                    continue
                }
                if normalizedSettingID == "reasoning_effort" {
                    normalizedSettings[normalizedSettingID] = normalizedValue.lowercased()
                } else {
                    normalizedSettings[normalizedSettingID] = normalizedValue
                }
            }

            if normalizedSettings.isEmpty {
                normalized.removeValue(forKey: normalizedExecutorValue)
            } else {
                normalized[normalizedExecutorValue] = normalizedSettings
            }
        }
        return normalized
    }

    private var effectiveResponseMode: String {
        "concise"
    }

    private var effectiveAgentGuidanceMode: String {
        agentGuidanceMode == "minimal" ? "minimal" : "guided"
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

    var autoSendAfterSilenceDelaySeconds: Double {
        normalizedAutoSendAfterSilenceSeconds
    }

    var autoSendAfterSilenceDelayLabel: String {
        "\(autoSendAfterSilenceSecondsFormatted(autoSendAfterSilenceDelaySeconds)) seconds"
    }

    func setAutoSendAfterSilenceDelay(_ seconds: Double) {
        autoSendAfterSilenceSeconds = autoSendAfterSilenceSecondsFormatted(seconds)
    }

    private func normalizeAutoSendAfterSilenceSetting() {
        autoSendAfterSilenceSeconds = autoSendAfterSilenceSecondsFormatted(normalizedAutoSendAfterSilenceSeconds)
    }

    private func autoSendAfterSilenceSecondsFormatted(_ seconds: Double) -> String {
        String(format: "%.1f", min(5.0, max(0.8, seconds)))
    }

    private var activeSilenceConfig: AudioRecorderService.SilenceConfig? {
        guard usesAutoSendForCurrentTurn else { return nil }
        if isVoiceModeActiveForCurrentThread {
            return AudioRecorderService.SilenceConfig(
                thresholdDB: -39,
                requiredSilenceDuration: min(1.0, normalizedAutoSendAfterSilenceSeconds),
                minimumRecordDuration: 0.6
            )
        }
        return AudioRecorderService.SilenceConfig(
            requiredSilenceDuration: normalizedAutoSendAfterSilenceSeconds
        )
    }

    func isTerminalStatus(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "completed"
            || normalized == "failed"
            || normalized == "rejected"
            || normalized == "blocked"
            || normalized == "cancelled"
            || normalized == "timed_out"
            || normalized == "timed out"
    }

    private func applyTerminalRunStateIfNeeded(_ run: RunRecord, threadID: UUID) {
        if activeThreadID == threadID, didCompleteRun && summaryText == run.summary {
            return
        }
        if let context = observedRunContexts[run.runId], !context.hasReceivedFinalAssistantMessage {
            compressLiveActivityIfNeeded(
                runID: run.runId,
                threadID: threadID,
                replacementText: fallbackCompressedCompletionText(for: run)
            )
        } else {
            compressLiveActivityIfNeeded(runID: run.runId, threadID: threadID)
        }
        let spokenReply = resolvedSpokenReplyText(for: run, threadID: threadID)
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
                scheduleVoiceModeResumeAfterCurrentReply(threadID: threadID, replyText: spokenReply ?? "")
            } else if let spokenReply {
                speak(spokenReply)
            }
        }

        removeObservedRunContext(runID: run.runId, preserveVisibleEvents: true)

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
            if let liveActivityText = liveActivityText(for: event, threadID: threadID) {
                upsertLiveActivityMessage(liveActivityText, runID: runID, threadID: threadID)
            }
            if let text = conversationText(for: event, threadID: threadID) {
                if event.type == "chat.message" || event.type == "assistant.message" {
                    context.hasReceivedFinalAssistantMessage = true
                    context.finalAssistantReplyText = text
                    observedRunContexts[runID] = context
                }
                compressLiveActivityIfNeeded(runID: runID, threadID: threadID)
                appendConversation(
                    role: "assistant",
                    text: text,
                    to: threadID,
                    sourceRunID: runID
                )
            }
        }
    }

    private func updateRunPhase(for event: ExecutionEvent, threadID: UUID) {
        guard activeThreadID == threadID else { return }
        if let activityPhase = activityPhaseText(for: event), isLoading {
            runPhaseText = activityPhase
            return
        }
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
            if liveActivitySummary(from: message) != nil {
                return nil
            }
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
            if liveActivitySummary(from: message) != nil {
                return nil
            }
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

    private func appendConversation(
        role: String,
        text: String,
        to threadID: UUID? = nil,
        presentation: ConversationMessagePresentation = .standard,
        sourceRunID: String? = nil
    ) {
        appendConversation(
            ConversationMessage(
                role: role,
                text: text,
                presentation: presentation,
                sourceRunID: sourceRunID
            ),
            to: threadID
        )
    }

    private func appendConversation(_ message: ConversationMessage, to threadID: UUID? = nil) {
        let targetThreadID = threadID ?? activeThreadID
        guard let targetThreadID else { return }

        let preparedText = message.role == "assistant" ? normalizeAssistantText(message.text) : message.text
        let normalized = ConversationMessage(
            id: message.id,
            role: message.role,
            text: preparedText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: message.attachments,
            presentation: message.presentation,
            sourceRunID: message.sourceRunID
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
            if last.text == normalized.text
                && last.attachments == normalized.attachments
                && last.presentation == normalized.presentation
                && last.sourceRunID == normalized.sourceRunID {
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

    private func resolvedSpokenReplyText(for run: RunRecord, threadID: UUID) -> String? {
        let normalizedStatus = run.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (normalizedStatus == "completed" || normalizedStatus == "blocked"),
              speakRepliesEnabled,
              activeThreadID == threadID else {
            return nil
        }
        let threadWantsVoiceReply = thread(for: threadID)?.lastSubmittedInputOrigin == .voice
        let context = observedRunContext(for: threadID, runID: run.runId)
        guard context?.shouldSpeakReply == true || threadWantsVoiceReply else {
            return nil
        }
        if let assistantReply = context?.finalAssistantReplyText,
           let spokenAssistantReply = spokenTextForPlayback(from: assistantReply) {
            return spokenAssistantReply
        }
        if normalizedStatus == "blocked",
           let instructions = run.pendingHumanUnblock?.instructions,
           let spokenInstructions = spokenTextForPlayback(from: instructions) {
            return spokenInstructions
        }
        return spokenTextForPlayback(from: run.summary)
    }

    private func spokenTextForPlayback(from rawText: String) -> String? {
        if let envelope = parseEnvelope(rawText) {
            return spokenTextForPlayback(from: envelope)
        }
        return finalizeSpeechText(cleansedSpeechMarkup(rawText))
    }

    private func spokenTextForPlayback(from envelope: ChatEnvelope) -> String? {
        var segments: [String] = []

        let summary = cleansedSpeechMarkup(envelope.summary)
        if !summary.isEmpty {
            segments.append(summary)
        }

        for section in envelope.sections {
            let body = cleansedSpeechMarkup(section.body)
            guard !body.isEmpty else { continue }
            let title = cleansedSpeechMarkup(section.title)
            let normalizedTitle = title.lowercased()
            let spokenSection: String
            if title.isEmpty || normalizedTitle == "result" || normalizedTitle == "summary" || normalizedTitle == "status" {
                spokenSection = body
            } else {
                spokenSection = "\(title). \(body)"
            }
            if !segments.contains(spokenSection) {
                segments.append(spokenSection)
            }
            if segments.count >= 2 || segments.joined(separator: " ").count >= 260 {
                break
            }
        }

        if segments.isEmpty {
            if !envelope.agendaItems.isEmpty {
                segments.append("I have follow-up items on screen.")
            } else if !envelope.artifacts.isEmpty {
                segments.append("I sent files or artifacts. Check the screen for details.")
            }
        }

        return finalizeSpeechText(segments.joined(separator: " "))
    }

    private func cleansedSpeechMarkup(_ rawText: String) -> String {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let hadCodeFence = normalized.contains("```")

        var text = normalized.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " Code omitted. ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^\\)]*\\)",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^\\)]+\\)",
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?m)^\\s{0,3}#{1,6}\\s*",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?m)^\\s*[-*•]\\s+",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?m)^\\s*\\d+\\.\\s+",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?m)^\\s*>\\s*",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "[*_~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty, hadCodeFence {
            return "I sent code. Check the screen for details."
        }
        return trimmed
    }

    private func finalizeSpeechText(_ rawText: String) -> String? {
        let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let sentenceEndings = cleaned.indices.filter { ".!?".contains(cleaned[$0]) }
        if sentenceEndings.count > 3 {
            let thirdEnding = sentenceEndings[2]
            let truncated = cleaned[...thirdEnding].trimmingCharacters(in: .whitespacesAndNewlines)
            if truncated.count >= 120 {
                return "\(truncated) There's more on screen."
            }
        }

        let maxCharacters = 320
        guard cleaned.count > maxCharacters else { return cleaned }
        let cutIndex = cleaned.index(cleaned.startIndex, offsetBy: maxCharacters)
        let prefix = String(cleaned[..<cutIndex])
        let boundary = prefix.lastIndex(where: { ".!? ".contains($0) }) ?? prefix.index(before: prefix.endIndex)
        let truncated = String(prefix[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !truncated.isEmpty else { return cleaned }
        let suffix = truncated.last.map { ".!?".contains($0) } == true ? " There's more on screen." : ". There's more on screen."
        return truncated + suffix
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

    private func liveActivityText(for event: ExecutionEvent, threadID: UUID) -> String? {
        if isTypedActivityEvent(event.type) {
            let text = event.displayMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? event.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return compactLiveActivityText(text)
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

    private func liveActivitySummary(from rawText: String) -> String? {
        let message = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }

        if let envelope = parseEnvelope(message) {
            if !envelope.agendaItems.isEmpty || !envelope.artifacts.isEmpty || envelope.sections.count > 1 {
                return nil
            }
            if let section = envelope.sections.first {
                let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard title == "result" || title == "status" else { return nil }
                let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard looksLikeProgressSentence(body) else { return nil }
                return compactLiveActivityText(body)
            }
            let summary = envelope.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeProgressSentence(summary) else { return nil }
            return compactLiveActivityText(summary)
        }

        guard looksLikeProgressSentence(message) else { return nil }
        return compactLiveActivityText(message)
    }

    private func compactLiveActivityText(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activityText(forActionEvent event: ExecutionEvent, threadID: UUID) -> String? {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if message.hasPrefix("starting codex exec") || message.hasPrefix("starting claude exec") {
            return "Reviewing your request and planning the next steps…"
        }
        if message.hasPrefix("starting calendar adapter") {
            return "Checking today’s calendar…"
        }
        if message.contains("starting write_file") {
            return "Writing files…"
        }
        if message.contains("starting run_command") {
            return "Running commands…"
        }
        return nil
    }

    private func activityPhaseText(for event: ExecutionEvent) -> String? {
        guard isTypedActivityEvent(event.type) else { return nil }
        let normalizedStage = event.stage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalizedStage {
        case "planning":
            return "Planning"
        case "executing":
            return "Executing"
        case "summarizing":
            return "Summarizing"
        case "blocked":
            return "Needs Input"
        default:
            break
        }

        let normalizedTitle = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedTitle.isEmpty ? nil : normalizedTitle
    }

    private func isTypedActivityEvent(_ type: String) -> Bool {
        type == "activity.started" || type == "activity.updated" || type == "activity.completed"
    }

    private func initialLiveActivityText(for requestText: String, includesAttachments: Bool) -> String {
        let trimmed = compactLiveActivityText(requestText)
        if !trimmed.isEmpty {
            return includesAttachments
                ? "Reviewing your request and attached context…"
                : "Reviewing your request and planning the next steps…"
        }
        return includesAttachments
            ? "Reviewing the task and attached context…"
            : "Reviewing the task and planning the next steps…"
    }

    private func displayTitle(forExecutor executor: String) -> String {
        let normalized = normalizedExecutor(from: executor) ?? executor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let descriptor = backendExecutorDescriptors.first(where: { $0.id == normalized }) {
            return descriptor.title
        }
        switch normalized {
        case "codex":
            return "Codex"
        case "claude":
            return "Claude Code"
        case "local":
            return "Local Runner"
        default:
            return normalized.capitalized
        }
    }

    private func primeLiveActivityIfNeeded(for runID: String, threadID: UUID, text: String) {
        let normalizedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRunID.isEmpty else { return }
        let context = observedRunContexts[normalizedRunID] ?? ObservedRunContext(runID: normalizedRunID, threadID: threadID)
        observedRunContexts[normalizedRunID] = context
        guard context.liveActivityMessageID == nil else { return }
        upsertLiveActivityMessage(text, runID: normalizedRunID, threadID: threadID)
    }

    private func upsertLiveActivityMessage(_ text: String, runID: String, threadID: UUID) {
        let normalizedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = compactLiveActivityText(text)
        guard !normalizedRunID.isEmpty, !normalizedText.isEmpty else { return }
        var context = observedRunContexts[normalizedRunID] ?? ObservedRunContext(runID: normalizedRunID, threadID: threadID)
        guard context.threadID == threadID else { return }

        var messages = cachedConversation(for: threadID)
        if let messageID = context.liveActivityMessageID,
           let idx = messages.firstIndex(where: { $0.id == messageID }) {
            let existing = messages[idx]
            if existing.text == normalizedText {
                return
            }
            let updated = ConversationMessage(
                id: existing.id,
                role: "assistant",
                text: normalizedText,
                presentation: .liveActivity,
                sourceRunID: normalizedRunID
            )
            messages[idx] = updated
            storeConversation(messages, for: threadID)
            persistConversationMessage(updated, at: idx, threadID: threadID)
            persistThreadSnapshot(threadID: threadID)
            return
        }

        let liveMessage = ConversationMessage(
            role: "assistant",
            text: normalizedText,
            presentation: .liveActivity,
            sourceRunID: normalizedRunID
        )
        messages.append(liveMessage)
        context.liveActivityMessageID = liveMessage.id
        observedRunContexts[normalizedRunID] = context
        storeConversation(messages, for: threadID)
        persistConversationMessage(liveMessage, at: messages.count - 1, threadID: threadID)
        persistThreadSnapshot(threadID: threadID)
    }

    private func compressLiveActivityIfNeeded(runID: String, threadID: UUID, replacementText: String? = nil) {
        let normalizedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRunID.isEmpty else { return }
        guard var context = observedRunContexts[normalizedRunID], context.threadID == threadID else { return }
        guard let messageID = context.liveActivityMessageID else { return }

        var messages = cachedConversation(for: threadID)
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else {
            context.liveActivityMessageID = nil
            observedRunContexts[normalizedRunID] = context
            return
        }

        let fallback = replacementText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallback.isEmpty {
            messages[idx] = ConversationMessage(
                id: messageID,
                role: "assistant",
                text: fallback,
                presentation: .standard,
                sourceRunID: normalizedRunID
            )
        } else {
            messages.remove(at: idx)
        }

        context.liveActivityMessageID = nil
        observedRunContexts[normalizedRunID] = context
        storeConversation(messages, for: threadID)
        threadStore.replaceMessages(threadID: threadID, messages: messages)
        persistThreadSnapshot(threadID: threadID)
    }

    private func fallbackCompressedCompletionText(for run: RunRecord) -> String? {
        let trimmed = run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower == "run completed successfully" {
            return nil
        }
        if run.status == "completed" && lower == "completed" {
            return nil
        }
        return trimmed
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
        preferHighestReachabilityServerURL()
        if let keychainToken = KeychainStore.load(service: "MOBaiLE", account: "api_token"),
           !keychainToken.isEmpty {
            apiToken = keychainToken
        } else if let value = defaults.string(forKey: DefaultsKey.apiToken), !value.isEmpty {
            apiToken = value
            KeychainStore.save(value: value, service: "MOBaiLE", account: "api_token")
            defaults.removeObject(forKey: DefaultsKey.apiToken)
        }
        if let keychainRefreshToken = KeychainStore.load(service: "MOBaiLE", account: "refresh_token"),
           !keychainRefreshToken.isEmpty {
            pairedRefreshToken = keychainRefreshToken
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
        if let data = defaults.data(forKey: DefaultsKey.runtimeSettingOverrides),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            runtimeSettingOverrides = normalizedRuntimeSettingOverrides(decoded)
        }
        if let value = defaults.string(forKey: DefaultsKey.codexModelOverride),
           runtimeSettingOverrideValue(for: "model", executor: "codex").isEmpty {
            updateRuntimeSettingOverride(value, for: "model", executor: "codex")
        }
        if let value = defaults.string(forKey: DefaultsKey.codexReasoningEffort),
           runtimeSettingOverrideValue(for: "reasoning_effort", executor: "codex").isEmpty {
            updateRuntimeSettingOverride(value, for: "reasoning_effort", executor: "codex")
        }
        if let value = defaults.string(forKey: DefaultsKey.claudeModelOverride),
           runtimeSettingOverrideValue(for: "model", executor: "claude").isEmpty {
            updateRuntimeSettingOverride(value, for: "model", executor: "claude")
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
        if defaults.object(forKey: DefaultsKey.speakRepliesEnabled) == nil {
            speakRepliesEnabled = true
        } else {
            speakRepliesEnabled = defaults.bool(forKey: DefaultsKey.speakRepliesEnabled)
        }
        if defaults.object(forKey: DefaultsKey.autoSendAfterSilenceEnabled) == nil {
            autoSendAfterSilenceEnabled = false
        } else {
            autoSendAfterSilenceEnabled = defaults.bool(forKey: DefaultsKey.autoSendAfterSilenceEnabled)
        }
        if let value = defaults.string(forKey: DefaultsKey.autoSendAfterSilenceSeconds), !value.isEmpty {
            autoSendAfterSilenceSeconds = value
        }
        normalizeAutoSendAfterSilenceSetting()
        if let data = defaults.data(forKey: DefaultsKey.connectionRepairState),
           let decoded = try? JSONDecoder().decode(PersistedConnectionRepairState.self, from: data) {
            setConnectionRepairState(
                ConnectionRepairState(title: decoded.title, message: decoded.message),
                persist: false
            )
        }
        hasSeenMicrophonePrimer = defaults.bool(forKey: DefaultsKey.microphonePrimerSeen)
        trustedPairHosts = Set(defaults.stringArray(forKey: DefaultsKey.trustedPairHosts) ?? [])
        refreshClientConnectionCandidates()
    }

    func persistTrustedPairHosts() {
        defaults.set(Array(trustedPairHosts).sorted(), forKey: DefaultsKey.trustedPairHosts)
    }

    func setConnectionRepairState(_ state: ConnectionRepairState?, persist: Bool = true) {
        connectionRepairState = state
        guard persist else { return }

        if let state,
           let data = try? JSONEncoder().encode(
               PersistedConnectionRepairState(title: state.title, message: state.message)
           ) {
            defaults.set(data, forKey: DefaultsKey.connectionRepairState)
        } else {
            defaults.removeObject(forKey: DefaultsKey.connectionRepairState)
        }
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

    private func clearRuntimeConfiguration() {
        backendSecurityMode = "unknown"
        backendDefaultExecutor = "codex"
        backendAvailableExecutors = ["codex"]
        backendTranscribeProvider = "unknown"
        backendTranscribeReady = false
        backendExecutorDescriptors = []
        backendSlashCommands = []
        backendWorkdirRoot = ""
        backendCodexModelOptions = Self.defaultCodexModelOptions
        backendCodexReasoningEffort = ""
        backendCodexReasoningEffortOptions = Self.defaultCodexReasoningEffortOptions
        backendClaudeModelOptions = Self.defaultClaudeModelOptions
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
        restoreLastVoiceModeThreadIfPossible()

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

    private func rememberLastVoiceModeThread(_ threadID: UUID?) {
        lastVoiceModeThreadID = threadID
        if let threadID {
            defaults.set(threadID.uuidString, forKey: DefaultsKey.lastVoiceModeThreadID)
        } else {
            defaults.removeObject(forKey: DefaultsKey.lastVoiceModeThreadID)
        }
    }

    private func restoreLastVoiceModeThreadIfPossible() {
        let rawThreadID = defaults.string(forKey: DefaultsKey.lastVoiceModeThreadID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let threadID = UUID(uuidString: rawThreadID),
              threads.contains(where: { $0.id == threadID }) else {
            rememberLastVoiceModeThread(nil)
            return
        }
        lastVoiceModeThreadID = threadID
    }

    private func publishVoiceInteractionNotice(_ text: String) {
        clearVoiceInteractionNoticeTask?.cancel()
        voiceInteractionNoticeText = text
        clearVoiceInteractionNoticeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard self?.voiceInteractionNoticeText == text else { return }
                self?.voiceInteractionNoticeText = nil
                self?.clearVoiceInteractionNoticeTask = nil
            }
        }
    }

    private func clearVoiceInteractionNotice() {
        clearVoiceInteractionNoticeTask?.cancel()
        clearVoiceInteractionNoticeTask = nil
        voiceInteractionNoticeText = nil
    }

    private func discardActiveRecording() {
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
        statusText = hasConfiguredConnection ? "Ready for prompts" : "Run setup on your computer or enter connection details first."
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

    func persistActiveThreadSnapshot() {
        guard let threadID = activeThreadID else { return }
        persistThreadSnapshot(threadID: threadID)
    }

    func persistThreadSnapshot(threadID: UUID) {
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
        pendingDraftPersistenceTask?.cancel()
        pendingDraftPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.persistDraftStateNowIfNeeded()
        }
    }

    private func persistDraftStateNowIfNeeded() {
        guard !isRestoringThreadState,
              let threadID = activeThreadID,
              let idx = threadIndex(for: threadID) else { return }
        pendingDraftPersistenceTask = nil
        var snapshot = threads[idx]
        snapshot.draftText = promptText
        snapshot.draftAttachments = draftAttachments
        threadStore.upsertThread(snapshot)
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

    private func thread(for threadID: UUID) -> ChatThread? {
        guard let idx = threadIndex(for: threadID) else { return nil }
        return threads[idx]
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

    func updateThreadMetadata(
        threadID: UUID,
        runID: String? = nil,
        summaryText: String? = nil,
        transcriptText: String? = nil,
        statusText: String? = nil,
        resolvedWorkingDirectory: String? = nil,
        activeRunExecutor: String? = nil,
        lastSubmittedInputOrigin: ConversationInputOrigin? = nil,
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
        if let lastSubmittedInputOrigin {
            threads[idx].lastSubmittedInputOrigin = lastSubmittedInputOrigin
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

    func setThreadPendingHumanUnblock(
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

    func hasObservedRunContext(runID: String, threadID: UUID) -> Bool {
        observedRunContext(for: threadID, runID: runID) != nil
    }

    private func removeObservedRunContext(runID: String, preserveVisibleEvents: Bool = false) {
        let trimmedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRunID.isEmpty else { return }
        observedRunContexts.removeValue(forKey: trimmedRunID)
        if self.runID == trimmedRunID && !preserveVisibleEvents {
            events = []
        }
    }

    private func isRunActivelyObserved(_ runID: String) -> Bool {
        let trimmedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRunID.isEmpty,
              let context = observedRunContexts[trimmedRunID],
              let activeThreadID else {
            return false
        }
        return context.threadID == activeThreadID
    }

    private func clearObservedRunContext(for threadID: UUID?) {
        guard let threadID else { return }
        let previousRunID = runID(for: threadID)
        if let context = observedRunContexts[previousRunID], context.liveActivityMessageID != nil {
            compressLiveActivityIfNeeded(runID: previousRunID, threadID: threadID)
        }
        removeObservedRunContext(runID: previousRunID)
    }

    private func ensureObservedRunContext(runID: String, threadID: UUID) {
        let inputOrigin = thread(for: threadID)?.lastSubmittedInputOrigin ?? .text
        if var existing = observedRunContexts[runID], existing.threadID == threadID {
            existing.shouldSpeakReply = inputOrigin == .voice
            observedRunContexts[runID] = existing
            return
        }
        var context = ObservedRunContext(runID: runID, threadID: threadID)
        context.shouldSpeakReply = inputOrigin == .voice
        if let liveMessage = cachedConversation(for: threadID).last(where: {
            $0.presentation == .liveActivity && $0.sourceRunID == runID
        }) {
            context.liveActivityMessageID = liveMessage.id
        }
        observedRunContexts[runID] = context
    }

    private func ensureObservedRunContext(
        runID: String,
        threadID: UUID,
        inputOrigin: ConversationInputOrigin
    ) {
        updateThreadMetadata(
            threadID: threadID,
            lastSubmittedInputOrigin: inputOrigin,
            persist: false
        )
        ensureObservedRunContext(runID: runID, threadID: threadID)
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
        guard isUploadingAttachments else { return }
        errorText = ""
        statusText = "Cancelling upload..."
        runPhaseText = "Cancelling"
        didCancelAttachmentUpload = true
        let cancel = activeAttachmentUploadCancellation
        activeAttachmentUploadCancellation = nil
        cancel?()
    }

    private func cancelActiveVoiceInputIfNeeded() -> Bool {
        guard activeVoiceInputPhase.isActive || activeVoiceInputCancellation != nil else { return false }
        errorText = ""
        statusText = "Cancelling voice input..."
        runPhaseText = "Cancelling"
        didCancelVoiceInputPreparation = true
        activeVoiceInputPhase = .idle
        let cancel = activeVoiceInputCancellation
        let backendRunID = activeVoiceInputRunID?.trimmingCharacters(in: .whitespacesAndNewlines)
        activeVoiceInputCancellation = nil
        activeVoiceInputRunID = nil
        cancel?()
        if let backendRunID, !backendRunID.isEmpty {
            cancelBackendVoiceInputRun(runID: backendRunID)
        }
        return true
    }

    private func cancelBackendVoiceInputRun(runID: String) {
        let serverURL = normalizedServerURL
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !token.isEmpty else { return }
        Task {
            _ = try? await client.cancelRun(
                serverURL: serverURL,
                token: token,
                runID: runID
            )
        }
    }

    private func checkVoiceInputCancellation() throws {
        if didCancelVoiceInputPreparation {
            throw CancellationError()
        }
    }

    private func deactivateVoiceModeAfterVoiceInputFailure(threadID: UUID?) {
        guard voiceModeEnabled else { return }
        if let threadID, voiceModeThreadID != threadID {
            return
        }
        deactivateVoiceMode(stopSpeaking: false)
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
        return lower.contains("completed")
            || lower.contains("failed")
            || lower.contains("cancelled")
            || lower.contains("rejected")
            || lower.contains("blocked")
            || lower.contains("timed out")
    }

    private func phaseText(forStatusText value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("cancel") { return "Cancelled" }
        if lower.contains("timed out") { return "Timed Out" }
        if lower.contains("fail") || lower.contains("rejected") { return "Failed" }
        if lower.contains("complete") { return "Completed" }
        if lower.contains("blocked") || lower.contains("input") { return "Needs Input" }
        if lower.contains("running") { return "Executing" }
        if lower.contains("starting") { return "Planning" }
        return "Idle"
    }

    func phaseText(forRunStatus status: String) -> String {
        switch status.lowercased() {
        case "completed":
            return "Completed"
        case "timed_out", "timed out":
            return "Timed Out"
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
            "phone ux feedback guidance:",
            "emit short progress updates at meaningful milestones",
            "finish with a compressed final result",
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
        activeRunExecutor: String? = nil,
        lastSubmittedInputOrigin: ConversationInputOrigin? = nil
    ) {
        updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: statusText,
            activeRunExecutor: activeRunExecutor,
            lastSubmittedInputOrigin: lastSubmittedInputOrigin
        )
    }

    func _test_ingestRunEvents(_ runEvents: [ExecutionEvent], runID: String, threadID: UUID) {
        ingestEvents(runEvents, runID: runID, threadID: threadID)
    }

    func _test_composeVoiceUtteranceText(draftText: String, transcriptText: String) -> String {
        composeVoiceUtteranceText(draftText: draftText, transcriptText: transcriptText)
    }

    func _test_setActiveVoiceInputPhase(_ phase: VoiceInputPhase) {
        activeVoiceInputPhase = phase
    }

    func _test_deactivateVoiceModeAfterVoiceInputFailure(threadID: UUID?) {
        deactivateVoiceModeAfterVoiceInputFailure(threadID: threadID)
    }

    func _test_resolvedSpokenReplyText(runID: String, threadID: UUID, summary: String, status: String) -> String? {
        resolvedSpokenReplyText(
            for: RunRecord(
                runId: runID,
                sessionId: "test-session",
                executor: nil,
                utteranceText: "",
                workingDirectory: nil,
                status: status,
                pendingHumanUnblock: nil,
                summary: summary,
                events: [],
                createdAt: nil,
                updatedAt: nil
            ),
            threadID: threadID
        )
    }

    func _test_spokenTextForPlayback(_ rawText: String) -> String? {
        spokenTextForPlayback(from: rawText)
    }

    func _test_scheduleVoiceModeResumeAfterCurrentReply(threadID: UUID, replyText: String) {
        scheduleVoiceModeResumeAfterCurrentReply(threadID: threadID, replyText: replyText)
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

    func _test_shouldResumeVoiceModeAfterSpeech() -> Bool {
        shouldResumeVoiceModeAfterSpeech
    }

    func _test_activeSilenceConfig() -> AudioRecorderService.SilenceConfig? {
        activeSilenceConfig
    }

    func _test_setPendingHumanUnblock(_ request: HumanUnblockRequest?, threadID: UUID) {
        setThreadPendingHumanUnblock(threadID: threadID, request: request)
    }

    func _test_persistActiveThreadSnapshot() {
        persistActiveThreadSnapshot()
    }

    func _test_lastVoiceModeThreadID() -> UUID? {
        lastVoiceModeThreadID
    }

    func _test_prepareExternalVoiceResumeTarget() -> VoiceThreadResumeTarget {
        prepareExternalVoiceResumeTarget()
    }

    func _test_hasObservedRunContext(runID: String, threadID: UUID) -> Bool {
        hasObservedRunContext(runID: runID, threadID: threadID)
    }

    func _test_isRunActivelyObserved(_ runID: String) -> Bool {
        isRunActivelyObserved(runID)
    }

    func _test_applyTerminalRunState(
        runID: String,
        threadID: UUID,
        status: String,
        summary: String,
        events: [ExecutionEvent]
    ) {
        applyTerminalRunStateIfNeeded(
            RunRecord(
                runId: runID,
                sessionId: "test-session",
                executor: nil,
                utteranceText: "",
                workingDirectory: nil,
                status: status,
                pendingHumanUnblock: nil,
                summary: summary,
                events: events,
                createdAt: nil,
                updatedAt: nil
            ),
            threadID: threadID
        )
    }

    func _test_voiceInteractionNoticeText() -> String? {
        voiceInteractionNoticeText
    }

    func _test_setIsRecording(_ recording: Bool) {
        isRecording = recording
        recordingStartedAt = recording ? Date() : nil
    }
}
