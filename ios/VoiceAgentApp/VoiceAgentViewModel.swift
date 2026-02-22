import AVFoundation
import Foundation

@MainActor
final class VoiceAgentViewModel: ObservableObject {
    @Published var serverURL: String = "http://127.0.0.1:8000"
    @Published var apiToken: String = ""
    @Published var sessionID: String = "iphone-app"
    @Published var executor: String = "local"
    @Published var promptText: String = "create a hello python script and run it"
    @Published var isLoading: Bool = false
    @Published var statusText: String = "Idle"
    @Published var runID: String = ""
    @Published var summaryText: String = ""
    @Published var transcriptText: String = ""
    @Published var errorText: String = ""
    @Published var events: [ExecutionEvent] = []
    @Published var isRecording: Bool = false

    private let client = APIClient()
    private let speaker = AVSpeechSynthesizer()
    private let recorder = AudioRecorderService()

    func sendPrompt() async {
        errorText = ""
        summaryText = ""
        events = []
        isLoading = true
        statusText = "Starting run..."

        do {
            let response = try await client.createUtterance(
                serverURL: normalizedServerURL,
                token: apiToken,
                requestBody: UtteranceRequest(
                    sessionId: sessionID,
                    utteranceText: promptText,
                    mode: "execute",
                    executor: executor
                )
            )
            runID = response.runId
            statusText = "Run started (\(response.runId))"
            try await pollRunUntilDone(runID: response.runId)
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

    func stopRecordingAndSend() async {
        guard isRecording else { return }
        isRecording = false
        statusText = "Uploading audio..."
        errorText = ""
        summaryText = ""
        transcriptText = ""
        events = []
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
                audioFileURL: audioFile
            )
            runID = response.runId
            transcriptText = response.transcriptText
            statusText = "Audio run started (\(response.runId))"
            try await pollRunUntilDone(runID: response.runId)
        } catch {
            errorText = error.localizedDescription
            statusText = "Failed"
            isLoading = false
        }
    }

    private func pollRunUntilDone(runID: String) async throws {
        for _ in 0..<120 {
            let run = try await client.fetchRun(
                serverURL: normalizedServerURL,
                token: apiToken,
                runID: runID
            )
            statusText = "Run status: \(run.status)"
            summaryText = run.summary
            events = run.events

            if run.status != "running" {
                isLoading = false
                speak(run.summary)
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        isLoading = false
        errorText = "Timed out waiting for run completion."
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
}
