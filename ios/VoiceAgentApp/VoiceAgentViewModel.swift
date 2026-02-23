import AVFoundation
import Foundation

@MainActor
final class VoiceAgentViewModel: ObservableObject {
    @Published var serverURL: String = "http://127.0.0.1:8000"
    @Published var apiToken: String = ""
    @Published var sessionID: String = "iphone-app"
    @Published var workingDirectory: String = "~"
    @Published var runTimeoutSeconds: String = "300"
    @Published var executor: String = "local"
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

    private let client = APIClient()
    private let speaker = AVSpeechSynthesizer()
    private let recorder = AudioRecorderService()
    private var processedEventCount: Int = 0
    private var lastSubmittedUserText: String = ""

    func sendPrompt() async {
        didCompleteRun = false
        errorText = ""
        summaryText = ""
        events = []
        processedEventCount = 0
        resolvedWorkingDirectory = normalizedWorkingDirectory ?? ""
        isLoading = true
        statusText = "Starting run..."
        appendConversation(role: "user", text: promptText)
        lastSubmittedUserText = promptText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let response = try await client.createUtterance(
                serverURL: normalizedServerURL,
                token: apiToken,
                requestBody: UtteranceRequest(
                    sessionId: sessionID,
                    utteranceText: promptText,
                    mode: "execute",
                    executor: executor,
                    workingDirectory: normalizedWorkingDirectory
                )
            )
            runID = response.runId
            statusText = "Run started (\(response.runId))"
            try await observeRun(runID: response.runId)
        } catch {
            errorText = error.localizedDescription
            statusText = "Failed"
            isLoading = false
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
        processedEventCount = 0
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
                executor: executor,
                workingDirectory: normalizedWorkingDirectory,
                audioFileURL: audioFile
            )
            runID = response.runId
            transcriptText = response.transcriptText
            appendConversation(role: "user", text: response.transcriptText)
            lastSubmittedUserText = response.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            statusText = "Audio run started (\(response.runId))"
            try await observeRun(runID: response.runId)
        } catch {
            errorText = error.localizedDescription
            statusText = "Failed"
            isLoading = false
        }
    }

    private func observeRun(runID: String) async throws {
        statusText = "Streaming events..."
        do {
            try await streamRunUntilDone(runID: runID, timeoutSec: normalizedRunTimeoutSeconds)
        } catch {
            statusText = "Stream interrupted, polling..."
            try await pollRunUntilDone(runID: runID, timeoutSec: normalizedRunTimeoutSeconds)
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
            events = run.events
            resolvedWorkingDirectory = run.workingDirectory ?? resolvedWorkingDirectory
            appendNewEventMessages(from: run.events)

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
            events.append(event)
            if let text = conversationText(for: event) {
                appendConversation(role: "assistant", text: text)
            }
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
        runID = ""
        summaryText = ""
        transcriptText = ""
        errorText = ""
        statusText = "Idle"
        events = []
        conversation = []
        processedEventCount = 0
        didCompleteRun = false
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
        return value.isEmpty ? nil : value
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
        summaryText = run.summary
        resolvedWorkingDirectory = run.workingDirectory ?? resolvedWorkingDirectory
        isLoading = false
        didCompleteRun = true
        statusText = "Run status: \(run.status)"
        appendConversation(role: "assistant", text: run.summary)
        speak(run.summary)
    }

    private func appendNewEventMessages(from runEvents: [ExecutionEvent]) {
        guard runEvents.count > processedEventCount else { return }
        for idx in processedEventCount..<runEvents.count {
            let event = runEvents[idx]
            if let text = conversationText(for: event) {
                appendConversation(role: "assistant", text: text)
            }
        }
        processedEventCount = runEvents.count
    }

    private func conversationText(for event: ExecutionEvent) -> String? {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch event.type {
        case "assistant.message":
            if message.isEmpty { return nil }
            if message == lastSubmittedUserText { return nil }
            return message
        case "action.stdout":
            if message.isEmpty { return nil }
            if isCodexNoise(message) { return nil }
            if message == lastSubmittedUserText { return nil }
            return message
        case "action.stderr":
            return "stderr: \(message)"
        case "run.failed":
            return message
        case "run.cancelled":
            return message
        default:
            return nil
        }
    }

    private func appendConversation(role: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let last = conversation.last, last.role == role, last.text == trimmed {
            return
        }
        conversation.append(ConversationMessage(role: role, text: trimmed))
    }

    private func isCodexNoise(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower == "user" || lower == "codex" || lower == "exec" || lower == "thinking" {
            return true
        }
        if lower == "output:" || lower == "tokens used" || lower == "--------" {
            return true
        }
        if lower.hasPrefix("openai codex v") ||
            lower.hasPrefix("workdir:") ||
            lower.hasPrefix("model:") ||
            lower.hasPrefix("provider:") ||
            lower.hasPrefix("approval:") ||
            lower.hasPrefix("sandbox:") ||
            lower.hasPrefix("reasoning effort:") ||
            lower.hasPrefix("reasoning summaries:") ||
            lower.hasPrefix("session id:") ||
            lower.hasPrefix("mcp startup:") {
            return true
        }
        if message.hasPrefix("**") && message.hasSuffix("**") {
            return true
        }
        return false
    }
}
