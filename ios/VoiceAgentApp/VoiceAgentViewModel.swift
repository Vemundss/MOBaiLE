import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import SQLite3
import Security
import UIKit

@MainActor
final class VoiceAgentViewModel: ObservableObject {
    struct PendingPairing: Identifiable, Equatable {
        let id = UUID()
        let serverURL: String
        let sessionID: String?
        let pairCode: String?
        let legacyToken: String?

        var serverHost: String {
            URL(string: serverURL)?.host?.lowercased() ?? ""
        }

        var badgeText: String {
            if serverURL.lowercased().hasPrefix("https://") {
                return "HTTPS"
            }
            if Self.isLocalOrPrivateHost(serverHost) {
                return "LOCAL"
            }
            return "HTTP"
        }

        private static func isLocalOrPrivateHost(_ host: String) -> Bool {
            if host.isEmpty { return false }
            if host == "localhost" || host == "::1" || host.hasSuffix(".local") {
                return true
            }
            if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
                return true
            }
            if host.hasPrefix("100.") {
                let parts = host.split(separator: ".")
                if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                    return true
                }
            }
            if host.hasPrefix("172.") {
                let parts = host.split(separator: ".")
                if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                    return true
                }
            }
            return false
        }
    }

    struct DirectoryBreadcrumb: Identifiable, Equatable {
        let id: String
        let title: String
        let path: String
    }

    @Published var serverURL: String = "http://127.0.0.1:8000"
    @Published var apiToken: String = ""
    @Published var sessionID: String = "iphone-app"
    @Published var workingDirectory: String = "~"
    @Published var runTimeoutSeconds: String = "300"
    @Published var executor: String = "codex"
    @Published var responseMode: String = "concise"
    @Published var agentGuidanceMode: String = "guided"
    @Published var developerMode: Bool = false
    @Published var promptText: String = "create a hello python script and run it"
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
    @Published var didCompleteRun: Bool = false
    @Published var activeRunExecutor: String = "codex"
    @Published var threads: [ChatThread] = []
    @Published var activeThreadID: UUID?
    @Published var backendSecurityMode: String = "unknown"
    @Published var backendCodexModel: String = "default"
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
    private let threadStore = ChatThreadStore()
    private let defaults = UserDefaults.standard
    private var seenEventIDs: Set<String> = []
    private var seenEventFingerprints: Set<String> = []
    private var lastSubmittedUserText: String = ""
    private var didBootstrapSession = false
    private var trustedPairHosts: Set<String> = []
    private var didConfigureRemoteCommands = false

    private enum DefaultsKey {
        static let serverURL = "mobaile.server_url"
        static let apiToken = "mobaile.api_token_legacy"
        static let sessionID = "mobaile.session_id"
        static let workingDirectory = "mobaile.working_directory"
        static let runTimeoutSeconds = "mobaile.run_timeout_seconds"
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
        static let pendingShortcutAction = "mobaile.pending_shortcut_action"
    }

    init() {
        loadSettings()
        loadThreads()
        configureRemoteCommandsIfNeeded()
    }

    func sendPrompt() async {
        let sentPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentPrompt.isEmpty else { return }
        didCompleteRun = false
        errorText = ""
        summaryText = ""
        events = []
        seenEventIDs = []
        seenEventFingerprints = []
        resolvedWorkingDirectory = normalizedWorkingDirectory ?? ""
        isLoading = true
        runPhaseText = "Planning"
        runStartedAt = Date()
        runEndedAt = nil
        statusText = "Starting run..."
        appendConversation(role: "user", text: sentPrompt)
        lastSubmittedUserText = sentPrompt
        promptText = ""
        activeRunExecutor = effectiveExecutor

        do {
            let response = try await client.createUtterance(
                serverURL: normalizedServerURL,
                token: apiToken,
                requestBody: UtteranceRequest(
                    sessionId: sessionID,
                    threadID: activeThreadID?.uuidString,
                    utteranceText: sentPrompt,
                    mode: "execute",
                    executor: effectiveExecutor,
                    workingDirectory: normalizedWorkingDirectory,
                    responseMode: effectiveResponseMode,
                    responseProfile: effectiveAgentGuidanceMode
                )
            )
            runID = response.runId
            statusText = "Run started (\(response.runId))"
            persistActiveThreadSnapshot()
            try await observeRun(runID: response.runId)
        } catch {
            maybeAutoFixWorkingDirectory(from: error)
            errorText = error.localizedDescription
            statusText = "Failed"
            isLoading = false
            runPhaseText = "Failed"
            runEndedAt = Date()
            persistActiveThreadSnapshot()
        }
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
        do {
            let silenceConfig: AudioRecorderService.SilenceConfig?
            if autoSendAfterSilenceEnabled {
                silenceConfig = AudioRecorderService.SilenceConfig(
                    requiredSilenceDuration: normalizedAutoSendAfterSilenceSeconds
                )
            } else {
                silenceConfig = nil
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
            statusText = "Recording..."
            syncNowPlayingRecordingState()
            emitRecordingStartedFeedback()
        } catch {
            errorText = error.localizedDescription
            statusText = "Failed to start recording"
            emitFailureFeedback()
        }
    }

    func cancelCurrentRun() async {
        let activeRun = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activeRun.isEmpty else { return }
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
                        applyTerminalRunStateIfNeeded(run)
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

    func stopRecordingAndSend() async {
        guard isRecording else { return }
        didCompleteRun = false
        isRecording = false
        syncNowPlayingRecordingState()
        statusText = "Uploading audio..."
        errorText = ""
        summaryText = ""
        transcriptText = ""
        events = []
        seenEventIDs = []
        seenEventFingerprints = []
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
            let response = try await client.createAudioRun(
                serverURL: normalizedServerURL,
                token: apiToken,
                sessionID: sessionID,
                threadID: activeThreadID?.uuidString,
                executor: effectiveExecutor,
                workingDirectory: normalizedWorkingDirectory,
                responseMode: effectiveResponseMode,
                responseProfile: effectiveAgentGuidanceMode,
                audioFileURL: audioFile
            )
            runID = response.runId
            transcriptText = response.transcriptText
            appendConversation(role: "user", text: response.transcriptText)
            lastSubmittedUserText = response.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            activeRunExecutor = effectiveExecutor
            statusText = "Audio run started (\(response.runId))"
            emitRecordingSentFeedback()
            persistActiveThreadSnapshot()
            try await observeRun(runID: response.runId)
        } catch {
            maybeAutoFixWorkingDirectory(from: error)
            errorText = error.localizedDescription
            statusText = "Failed"
            isLoading = false
            runPhaseText = "Failed"
            runEndedAt = Date()
            emitFailureFeedback()
            persistActiveThreadSnapshot()
        }
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
        await startRecording()
    }

    func handleSendLastPromptShortcut() async {
        if canRetryLastPrompt {
            await retryLastPrompt()
            return
        }
        statusText = "No previous prompt to resend."
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

    private func observeRun(runID: String) async throws {
        statusText = "Running..."
        if runPhaseText == "Idle" {
            runPhaseText = "Planning"
        }
        let timeoutSec = normalizedRunTimeoutSeconds
        let streamTask = Task {
            try await streamRunUntilDone(runID: runID, timeoutSec: timeoutSec)
        }
        do {
            // Keep polling as a watchdog so terminal state is reflected even if SSE stalls.
            try await pollRunUntilDone(runID: runID, timeoutSec: timeoutSec)
            streamTask.cancel()
        } catch {
            streamTask.cancel()
            throw error
        }
    }

    private func pollRunUntilDone(runID: String, timeoutSec: TimeInterval) async throws {
        let pollCount = max(1, Int(timeoutSec / 0.5))
        for _ in 0..<pollCount {
            let run = try await client.fetchRun(
                serverURL: normalizedServerURL,
                token: apiToken,
                runID: runID
            )
            statusText = "Run status: \(run.status)"
            summaryText = run.summary
            resolvedWorkingDirectory = run.workingDirectory ?? resolvedWorkingDirectory
            if run.status == "running", runPhaseText == "Planning" || runPhaseText == "Idle" {
                runPhaseText = "Executing"
            }
            ingestEvents(run.events)

            if isTerminalStatus(run.status) {
                applyTerminalRunStateIfNeeded(run)
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        isLoading = false
        errorText = "Timed out waiting for run completion."
        runPhaseText = "Timed out"
        runEndedAt = Date()
        appendConversation(role: "assistant", text: "Timed out waiting for run completion.")
    }

    private func streamRunUntilDone(runID: String, timeoutSec: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSec)
        let stream = client.streamRunEvents(
            serverURL: normalizedServerURL,
            token: apiToken,
            runID: runID
        )
        for try await event in stream {
            ingestEvents([event])
            if Date() > deadline {
                throw NSError(
                    domain: "VoiceAgentApp",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Run timed out while streaming events."]
                )
            }
            if event.type == "run.completed" || event.type == "run.failed" || event.type == "run.cancelled" {
                let run = try await client.fetchRun(
                    serverURL: normalizedServerURL,
                    token: apiToken,
                    runID: runID
                )
                applyTerminalRunStateIfNeeded(run)
                return
            }
        }
        throw NSError(
            domain: "VoiceAgentApp",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Event stream ended before run reached a terminal state."]
        )
    }

    func startNewChat() {
        createNewThread()
        runID = ""
        summaryText = ""
        transcriptText = ""
        errorText = ""
        statusText = "Idle"
        runPhaseText = "Idle"
        runStartedAt = nil
        runEndedAt = nil
        events = []
        conversation = []
        seenEventIDs = []
        seenEventFingerprints = []
        didCompleteRun = false
        activeRunExecutor = effectiveExecutor
        persistActiveThreadSnapshot()
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
        !isLoading && !lastSubmittedUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func retryLastPrompt() async {
        guard canRetryLastPrompt else { return }
        promptText = lastSubmittedUserText
        await sendPrompt()
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true

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
        syncNowPlayingRecordingState()
    }

    private func syncNowPlayingRecordingState() {
        if isRecording {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "MOBaiLE Recording",
                MPNowPlayingInfoPropertyPlaybackRate: 1
            ]
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "MOBaiLE",
                MPNowPlayingInfoPropertyPlaybackRate: 0
            ]
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

    func persistSettings() {
        if !developerMode {
            if executor != "codex" {
                executor = "codex"
            }
        }
        if responseMode != "concise" {
            responseMode = "concise"
        }
        defaults.set(serverURL, forKey: DefaultsKey.serverURL)
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
    }

    func bootstrapSessionIfNeeded() async {
        guard !didBootstrapSession else { return }
        guard !normalizedServerURL.isEmpty, !apiToken.isEmpty, !sessionID.isEmpty else { return }
        didBootstrapSession = true
        do {
            if let cfg = try? await client.fetchRuntimeConfig(
                serverURL: normalizedServerURL,
                token: apiToken
            ) {
                backendSecurityMode = cfg.securityMode
                backendCodexModel = displayModelName(cfg.codexModel)
                backendWorkdirRoot = cfg.workdirRoot ?? ""
            }
            let runs = try await client.fetchSessionRuns(
                serverURL: normalizedServerURL,
                token: apiToken,
                sessionID: sessionID,
                limit: 1
            )
            guard let latest = runs.first else { return }
            runID = latest.runId
            statusText = "Run status: \(latest.status)"
            runPhaseText = phaseText(forRunStatus: latest.status)
            if latest.status == "running" {
                isLoading = true
                runPhaseText = "Executing"
                runStartedAt = Date()
                runEndedAt = nil
                activeRunExecutor = latest.executor ?? executor
                try await observeRun(runID: latest.runId)
            } else if isTerminalStatus(latest.status) {
                runEndedAt = Date()
            }
            persistActiveThreadSnapshot()
        } catch {
            // Ignore bootstrap errors to avoid blocking first render.
        }
    }

    func applyPairingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "mobaile" else { return }
        guard let host = url.host?.lowercased(), host == "pair" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        var updatedServer: String?
        var updatedToken: String?
        var pairCode: String?
        var updatedSession: String?

        for item in components.queryItems ?? [] {
            switch item.name {
            case "server_url":
                if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    updatedServer = value
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

        guard let server = updatedServer else {
            errorText = "Invalid pairing QR. Missing server URL."
            return
        }
        let normalizedServer = normalized(server)
        guard let parsedServer = URL(string: normalizedServer),
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
        pendingPairing = nil

        if trustHost {
            setTrustedPairHost(pending.serverHost, trusted: true)
        }

        serverURL = pending.serverURL
        if let session = pending.sessionID, !session.isEmpty {
            sessionID = session
        }
        if let oneTimeCode = pending.pairCode {
            Task {
                await exchangePairCode(
                    serverURL: pending.serverURL,
                    pairCode: oneTimeCode,
                    sessionID: pending.sessionID
                )
            }
            return
        }
        if let token = pending.legacyToken {
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
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
        activeThreadID = threadID
        conversation = threadStore.loadMessages(threadID: threadID)
        runID = thread.runID
        summaryText = thread.summaryText
        transcriptText = thread.transcriptText
        statusText = thread.statusText
        runPhaseText = phaseText(forStatusText: thread.statusText)
        runStartedAt = nil
        runEndedAt = nil
        isLoading = thread.statusText.lowercased().contains("running")
        resolvedWorkingDirectory = thread.resolvedWorkingDirectory
        activeRunExecutor = thread.activeRunExecutor
        errorText = ""
        events = []
        seenEventIDs = []
        seenEventFingerprints = []
        didCompleteRun = isTerminalStatusText(thread.statusText)
        defaults.set(threadID.uuidString, forKey: DefaultsKey.activeThreadID)
    }

    func createNewThread() {
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
            activeRunExecutor: effectiveExecutor
        )
        threads.append(thread)
        activeThreadID = thread.id
        conversation = []
        runID = ""
        summaryText = ""
        transcriptText = ""
        statusText = "Idle"
        runPhaseText = "Idle"
        runStartedAt = nil
        runEndedAt = nil
        errorText = ""
        events = []
        seenEventIDs = []
        seenEventFingerprints = []
        didCompleteRun = false
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

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        speaker.speak(utterance)
    }

    private var normalizedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var hasConfiguredConnection: Bool {
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

    private var effectiveExecutor: String {
        developerMode ? executor : "codex"
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

    private var normalizedRunTimeoutSeconds: TimeInterval {
        let value = runTimeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(value), parsed >= 10 else { return 300 }
        return parsed
    }

    private var normalizedAutoSendAfterSilenceSeconds: TimeInterval {
        let value = autoSendAfterSilenceSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(value) else { return 1.2 }
        return min(5.0, max(0.8, parsed))
    }

    private func isTerminalStatus(_ status: String) -> Bool {
        status == "completed" || status == "failed" || status == "rejected" || status == "cancelled"
    }

    private func applyTerminalRunStateIfNeeded(_ run: RunRecord) {
        if didCompleteRun && summaryText == run.summary {
            return
        }
        summaryText = run.summary
        resolvedWorkingDirectory = run.workingDirectory ?? resolvedWorkingDirectory
        isLoading = false
        didCompleteRun = true
        statusText = "Run status: \(run.status)"
        runPhaseText = phaseText(forRunStatus: run.status)
        if runEndedAt == nil {
            runEndedAt = Date()
        }
        speak(run.summary)
        persistActiveThreadSnapshot()
    }

    private func ingestEvents(_ runEvents: [ExecutionEvent]) {
        for event in runEvents {
            let eventID = event.eventID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !eventID.isEmpty {
                if seenEventIDs.contains(eventID) {
                    continue
                }
                seenEventIDs.insert(eventID)
            } else {
                let fingerprint = "\(event.type)|\(event.actionIndex ?? -1)|\(event.message)"
                if seenEventFingerprints.contains(fingerprint) {
                    continue
                }
                seenEventFingerprints.insert(fingerprint)
            }
            events.append(event)
            updateRunPhase(for: event)
            if let text = conversationText(for: event) {
                appendConversation(role: "assistant", text: text)
            }
        }
    }

    private func updateRunPhase(for event: ExecutionEvent) {
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

    private func conversationText(for event: ExecutionEvent) -> String? {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if isContextLeak(message) { return nil }
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
            if message == lastSubmittedUserText { return nil }
            return message
        case "log.message", "action.stdout", "action.stderr":
            return nil
        case "action.completed":
            if activeRunExecutor == "codex" { return nil }
            if message.isEmpty { return nil }
            return message
        case "run.failed":
            return message
        case "run.cancelled":
            return message
        default:
            return nil
        }
    }

    private func appendConversation(role: String, text: String) {
        let prepared = role == "assistant" ? normalizeAssistantText(text) : text
        let trimmed = prepared.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if role == "assistant",
           shouldCoalesceAssistantProgress(with: trimmed),
           let last = conversation.last,
           last.role == "assistant",
           isProgressAssistantMessage(last.text),
           !isTerminalStatusText(statusText) {
            conversation[conversation.count - 1] = ConversationMessage(role: role, text: trimmed)
            persistConversationMessage(at: conversation.count - 1)
            persistActiveThreadSnapshot()
            return
        }
        if let last = conversation.last, last.role == role {
            if last.text == trimmed {
                return
            }
            if role == "assistant" {
                // Keep assistant updates as separate bubbles for readability.
                conversation.append(ConversationMessage(role: role, text: trimmed))
                persistConversationMessage(at: conversation.count - 1)
                persistActiveThreadSnapshot()
                return
            }
        }
        conversation.append(ConversationMessage(role: role, text: trimmed))
        persistConversationMessage(at: conversation.count - 1)
        if role == "user",
           let idx = activeThreadIndex(),
           threads[idx].title == "New Chat" {
            threads[idx].title = suggestThreadTitle(from: trimmed)
        }
        persistActiveThreadSnapshot()
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
        if let value = defaults.string(forKey: DefaultsKey.serverURL), !value.isEmpty {
            serverURL = value
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
        trustedPairHosts = Set(defaults.stringArray(forKey: DefaultsKey.trustedPairHosts) ?? [])
        if !developerMode {
            executor = "codex"
        }
    }

    private func exchangePairCode(serverURL: String, pairCode: String, sessionID: String?) async {
        do {
            let response = try await client.exchangePairingCode(
                serverURL: normalized(serverURL),
                pairCode: pairCode,
                sessionID: sessionID ?? self.sessionID
            )
            self.apiToken = response.apiToken
            self.sessionID = response.sessionId
            self.backendSecurityMode = response.securityMode
            if let cfg = try? await client.fetchRuntimeConfig(
                serverURL: normalizedServerURL,
                token: response.apiToken
            ) {
                self.backendSecurityMode = cfg.securityMode
                self.backendCodexModel = self.displayModelName(cfg.codexModel)
                self.backendWorkdirRoot = cfg.workdirRoot ?? ""
            }
            self.persistSettings()
            self.errorText = ""
            self.statusText = "Paired successfully (\(response.securityMode))"
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

    private func isLocalOrPrivateHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "::1" || lower.hasSuffix(".local") {
            return true
        }
        if lower.hasPrefix("127.") || lower.hasPrefix("10.") || lower.hasPrefix("192.168.") {
            return true
        }
        if lower.hasPrefix("100.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                return true
            }
        }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
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
        guard let idx = activeThreadIndex() else { return }
        threads[idx].conversation = []
        threads[idx].runID = runID
        threads[idx].summaryText = summaryText
        threads[idx].transcriptText = transcriptText
        threads[idx].statusText = statusText
        threads[idx].resolvedWorkingDirectory = resolvedWorkingDirectory
        threads[idx].activeRunExecutor = activeRunExecutor
        threads[idx].updatedAt = Date()
        threadStore.upsertThread(threads[idx])
    }

    private func persistConversationMessage(at index: Int) {
        guard let idx = activeThreadIndex(),
              conversation.indices.contains(index) else {
            return
        }
        let message = conversation[index]
        threadStore.upsertMessage(
            threadID: threads[idx].id,
            message: message,
            position: index
        )
    }

    private func activeThreadIndex() -> Int? {
        guard let id = activeThreadID else { return nil }
        return threads.firstIndex(where: { $0.id == id })
    }

    private func suggestThreadTitle(from text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 42 {
            return collapsed
        }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: 42)
        return String(collapsed[..<cut]) + "..."
    }

    private func isTerminalStatusText(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("completed") || lower.contains("failed") || lower.contains("cancelled") || lower.contains("rejected")
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
}

private final class ChatThreadStore {
    private let dbURL: URL
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = appSupport.appendingPathComponent("MOBaiLE", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        dbURL = directory.appendingPathComponent("threads.sqlite3")
        setupSchema()
    }

    func migrateLegacyThreadsIfNeeded(defaults: UserDefaults, threadsKey: String) {
        guard loadThreads().isEmpty else {
            defaults.removeObject(forKey: threadsKey)
            return
        }
        guard let data = defaults.data(forKey: threadsKey),
              let decoded = try? JSONDecoder().decode([ChatThread].self, from: data) else {
            return
        }
        for thread in decoded {
            let metadata = ChatThread(
                id: thread.id,
                title: thread.title,
                updatedAt: thread.updatedAt,
                conversation: [],
                runID: thread.runID,
                summaryText: thread.summaryText,
                transcriptText: thread.transcriptText,
                statusText: thread.statusText,
                resolvedWorkingDirectory: thread.resolvedWorkingDirectory,
                activeRunExecutor: thread.activeRunExecutor
            )
            upsertThread(metadata)
            for (position, message) in thread.conversation.enumerated() {
                upsertMessage(threadID: thread.id, message: message, position: position)
            }
        }
        defaults.removeObject(forKey: threadsKey)
    }

    func loadThreads() -> [ChatThread] {
        guard let db = openConnection() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, title, updated_at, run_id, summary_text, transcript_text, status_text, resolved_working_directory, active_run_executor
        FROM threads
        ORDER BY updated_at DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [ChatThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idText = stringColumn(statement, index: 0)
            guard let uuid = UUID(uuidString: idText) else { continue }
            let title = stringColumn(statement, index: 1)
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            rows.append(
                ChatThread(
                    id: uuid,
                    title: title,
                    updatedAt: updatedAt,
                    conversation: [],
                    runID: stringColumn(statement, index: 3),
                    summaryText: stringColumn(statement, index: 4),
                    transcriptText: stringColumn(statement, index: 5),
                    statusText: stringColumn(statement, index: 6),
                    resolvedWorkingDirectory: stringColumn(statement, index: 7),
                    activeRunExecutor: stringColumn(statement, index: 8)
                )
            )
        }
        return rows
    }

    func loadMessages(threadID: UUID) -> [ConversationMessage] {
        guard let db = openConnection() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT message_id, role, text
        FROM thread_messages
        WHERE thread_id = ?
        ORDER BY position ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: threadID.uuidString)

        var rows: [ConversationMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UUID(uuidString: stringColumn(statement, index: 0)) ?? UUID()
            let role = stringColumn(statement, index: 1)
            let text = stringColumn(statement, index: 2)
            rows.append(ConversationMessage(id: id, role: role, text: text))
        }
        return rows
    }

    func upsertThread(_ thread: ChatThread) {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO threads (
            id, title, updated_at, run_id, summary_text, transcript_text, status_text, resolved_working_directory, active_run_executor
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,
            updated_at=excluded.updated_at,
            run_id=excluded.run_id,
            summary_text=excluded.summary_text,
            transcript_text=excluded.transcript_text,
            status_text=excluded.status_text,
            resolved_working_directory=excluded.resolved_working_directory,
            active_run_executor=excluded.active_run_executor
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: thread.id.uuidString)
        bindText(statement, index: 2, value: thread.title)
        sqlite3_bind_double(statement, 3, thread.updatedAt.timeIntervalSince1970)
        bindText(statement, index: 4, value: thread.runID)
        bindText(statement, index: 5, value: thread.summaryText)
        bindText(statement, index: 6, value: thread.transcriptText)
        bindText(statement, index: 7, value: thread.statusText)
        bindText(statement, index: 8, value: thread.resolvedWorkingDirectory)
        bindText(statement, index: 9, value: thread.activeRunExecutor)
        _ = sqlite3_step(statement)
    }

    func upsertMessage(threadID: UUID, message: ConversationMessage, position: Int) {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO thread_messages (thread_id, position, message_id, role, text)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(thread_id, position) DO UPDATE SET
            message_id=excluded.message_id,
            role=excluded.role,
            text=excluded.text
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: threadID.uuidString)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(position))
        bindText(statement, index: 3, value: message.id.uuidString)
        bindText(statement, index: 4, value: message.role)
        bindText(statement, index: 5, value: message.text)
        _ = sqlite3_step(statement)
    }

    func deleteThread(threadID: UUID) {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }
        let sql = "DELETE FROM threads WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: threadID.uuidString)
        _ = sqlite3_step(statement)
    }

    private func setupSchema() {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE IF NOT EXISTS threads (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            updated_at REAL NOT NULL,
            run_id TEXT NOT NULL,
            summary_text TEXT NOT NULL,
            transcript_text TEXT NOT NULL,
            status_text TEXT NOT NULL,
            resolved_working_directory TEXT NOT NULL,
            active_run_executor TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS thread_messages (
            thread_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            message_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (thread_id, position),
            FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_thread_messages_thread ON thread_messages(thread_id, position);
        """
        _ = sqlite3_exec(db, schema, nil, nil, nil)
    }

    private func openConnection() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            return nil
        }
        _ = sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return db
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }
}

private enum KeychainStore {
    static func save(value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
