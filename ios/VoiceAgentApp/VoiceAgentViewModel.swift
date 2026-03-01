import AVFoundation
import Foundation
import Security

@MainActor
final class VoiceAgentViewModel: ObservableObject {
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
    @Published var backendWorkdirRoot: String = ""
    @Published var showDirectoryBrowser: Bool = false
    @Published var isLoadingDirectoryBrowser: Bool = false
    @Published var directoryBrowserEntries: [DirectoryEntry] = []
    @Published var directoryBrowserTruncated: Bool = false
    @Published var directoryBrowserError: String = ""

    private let client = APIClient()
    private let speaker = AVSpeechSynthesizer()
    private let recorder = AudioRecorderService()
    private let defaults = UserDefaults.standard
    private var seenEventIDs: Set<String> = []
    private var seenEventFingerprints: Set<String> = []
    private var lastSubmittedUserText: String = ""
    private var didBootstrapSession = false

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
    }

    init() {
        loadSettings()
        loadThreads()
    }

    func sendPrompt() async {
        didCompleteRun = false
        errorText = ""
        summaryText = ""
        events = []
        seenEventIDs = []
        seenEventFingerprints = []
        resolvedWorkingDirectory = normalizedWorkingDirectory ?? ""
        isLoading = true
        statusText = "Starting run..."
        let sentPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            persistActiveThreadSnapshot()
        }
    }

    func startRecording() async {
        errorText = ""
        do {
            try await recorder.start()
            isRecording = true
            statusText = "Recording..."
        } catch {
            errorText = error.localizedDescription
            statusText = "Failed to start recording"
        }
    }

    func cancelCurrentRun() async {
        let activeRun = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activeRun.isEmpty else { return }
        errorText = ""
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
        statusText = "Uploading audio..."
        errorText = ""
        summaryText = ""
        transcriptText = ""
        events = []
        seenEventIDs = []
        seenEventFingerprints = []
        resolvedWorkingDirectory = normalizedWorkingDirectory ?? ""
        isLoading = true

        guard let audioFile = recorder.stop() else {
            isLoading = false
            errorText = "No recorded audio file found."
            statusText = "Failed"
            return
        }

        do {
            let response = try await client.createAudioRun(
                serverURL: normalizedServerURL,
                token: apiToken,
                sessionID: sessionID,
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
            persistActiveThreadSnapshot()
            try await observeRun(runID: response.runId)
        } catch {
            maybeAutoFixWorkingDirectory(from: error)
            errorText = error.localizedDescription
            statusText = "Failed"
            isLoading = false
            persistActiveThreadSnapshot()
        }
    }

    private func observeRun(runID: String) async throws {
        statusText = "Running..."
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
            ingestEvents(run.events)

            if isTerminalStatus(run.status) {
                applyTerminalRunStateIfNeeded(run)
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        isLoading = false
        errorText = "Timed out waiting for run completion."
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

    func refreshDirectoryBrowser() async {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else {
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
            directoryBrowserError = "Set server URL and API token to browse cwd."
            isLoadingDirectoryBrowser = false
            return
        }

        isLoadingDirectoryBrowser = true
        directoryBrowserError = ""
        do {
            let response = try await client.fetchDirectoryListing(
                serverURL: normalizedServerURL,
                token: token,
                path: directoryPathForListing
            )
            directoryBrowserEntries = response.entries
            directoryBrowserTruncated = response.truncated
            resolvedWorkingDirectory = response.path
        } catch {
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
            directoryBrowserError = error.localizedDescription
        }
        isLoadingDirectoryBrowser = false
    }

    func hideDirectoryBrowser() {
        showDirectoryBrowser = false
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
        }
        defaults.set(sessionID, forKey: DefaultsKey.sessionID)
        defaults.set(workingDirectory, forKey: DefaultsKey.workingDirectory)
        defaults.set(runTimeoutSeconds, forKey: DefaultsKey.runTimeoutSeconds)
        defaults.set(executor, forKey: DefaultsKey.executor)
        defaults.set("concise", forKey: DefaultsKey.responseMode)
        defaults.set(agentGuidanceMode, forKey: DefaultsKey.agentGuidanceMode)
        defaults.set(developerMode, forKey: DefaultsKey.developerMode)
    }

    func bootstrapSessionIfNeeded() async {
        guard !didBootstrapSession else { return }
        didBootstrapSession = true
        guard !normalizedServerURL.isEmpty, !apiToken.isEmpty, !sessionID.isEmpty else { return }
        do {
            if let cfg = try? await client.fetchRuntimeConfig(
                serverURL: normalizedServerURL,
                token: apiToken
            ) {
                backendSecurityMode = cfg.securityMode
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
            if latest.status == "running" {
                isLoading = true
                activeRunExecutor = latest.executor ?? executor
                try await observeRun(runID: latest.runId)
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

        serverURL = server
        if let session = updatedSession {
            sessionID = session
        }
        if let oneTimeCode = pairCode {
            Task {
                await exchangePairCode(serverURL: server, pairCode: oneTimeCode, sessionID: updatedSession)
            }
            return
        }
        if let token = updatedToken {
            apiToken = token
            persistSettings()
            errorText = ""
            statusText = "Paired successfully"
            persistActiveThreadSnapshot()
            return
        }
        errorText = "Invalid pairing QR. Missing pairing code or API token."
    }

    var sortedThreads: [ChatThread] {
        threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func switchToThread(_ threadID: UUID) {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
        activeThreadID = threadID
        conversation = thread.conversation
        runID = thread.runID
        summaryText = thread.summaryText
        transcriptText = thread.transcriptText
        statusText = thread.statusText
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
        defaults.set(thread.id.uuidString, forKey: DefaultsKey.activeThreadID)
        persistThreads()
    }

    func renameThread(_ threadID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].title = trimmed
        threads[idx].updatedAt = Date()
        persistThreads()
    }

    func deleteThread(_ threadID: UUID) {
        threads.removeAll { $0.id == threadID }
        if threads.isEmpty {
            createNewThread()
            switchToThread(activeThreadID ?? threads[0].id)
            return
        }
        if activeThreadID == threadID {
            let next = sortedThreads.first?.id ?? threads[0].id
            switchToThread(next)
        }
        persistThreads()
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
            if let text = conversationText(for: event) {
                appendConversation(role: "assistant", text: text)
            }
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
                persistActiveThreadSnapshot()
                return
            }
        }
        conversation.append(ConversationMessage(role: role, text: trimmed))
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

    private func loadThreads() {
        if let data = defaults.data(forKey: DefaultsKey.threads),
           let decoded = try? JSONDecoder().decode([ChatThread].self, from: data),
           !decoded.isEmpty {
            threads = decoded
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

    private func persistThreads() {
        guard let encoded = try? JSONEncoder().encode(threads) else { return }
        defaults.set(encoded, forKey: DefaultsKey.threads)
    }

    private func persistActiveThreadSnapshot() {
        guard let idx = activeThreadIndex() else { return }
        threads[idx].conversation = conversation
        threads[idx].runID = runID
        threads[idx].summaryText = summaryText
        threads[idx].transcriptText = transcriptText
        threads[idx].statusText = statusText
        threads[idx].resolvedWorkingDirectory = resolvedWorkingDirectory
        threads[idx].activeRunExecutor = activeRunExecutor
        threads[idx].updatedAt = Date()
        persistThreads()
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
}
