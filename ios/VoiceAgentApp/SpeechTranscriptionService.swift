import Foundation
import Speech

struct SpeechTranscriptionResult {
    let text: String
    let usedOnDeviceRecognition: Bool
}

enum SpeechTranscriptionError: Error, LocalizedError {
    case authorizationDenied
    case authorizationRestricted
    case recognizerUnavailable
    case fileMissing
    case emptyTranscript
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech Recognition access is off. Enable it in Settings and try again."
        case .authorizationRestricted:
            return "Speech Recognition is restricted on this device."
        case .recognizerUnavailable:
            return "Speech Recognition is unavailable for the current device or language."
        case .fileMissing:
            return "Recorded audio file is missing."
        case .emptyTranscript:
            return "Speech Recognition returned an empty transcript."
        case let .unavailable(message):
            return message
        }
    }
}

final class SpeechTranscriptionService {
    func warmupAuthorization() async {
        _ = await authorizationStatus()
    }

    func transcribeFile(
        at fileURL: URL,
        registerCancellation: ((@escaping () -> Void) -> Void)? = nil
    ) async throws -> SpeechTranscriptionResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SpeechTranscriptionError.fileMissing
        }

        let authorization = await authorizationStatus()
        switch authorization {
        case .authorized:
            break
        case .denied:
            throw SpeechTranscriptionError.authorizationDenied
        case .restricted:
            throw SpeechTranscriptionError.authorizationRestricted
        case .notDetermined:
            throw SpeechTranscriptionError.authorizationDenied
        @unknown default:
            throw SpeechTranscriptionError.unavailable("Speech Recognition authorization failed.")
        }

        guard let recognizer = preferredRecognizer() else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }

        if recognizer.supportsOnDeviceRecognition {
            do {
                return try await transcribe(
                    fileURL: fileURL,
                    with: recognizer,
                    requiresOnDeviceRecognition: true,
                    registerCancellation: registerCancellation
                )
            } catch {
                // Retry without forcing on-device recognition so Apple's native service
                // can still succeed on devices/locales without an installed offline asset.
            }
        }

        return try await transcribe(
            fileURL: fileURL,
            with: recognizer,
            requiresOnDeviceRecognition: false,
            registerCancellation: registerCancellation
        )
    }

    private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func preferredRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer()
    }

    private func transcribe(
        fileURL: URL,
        with recognizer: SFSpeechRecognizer,
        requiresOnDeviceRecognition: Bool,
        registerCancellation: ((@escaping () -> Void) -> Void)?
    ) async throws -> SpeechTranscriptionResult {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        if requiresOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        var recognitionTask: SFSpeechRecognitionTask?
        defer {
            recognitionTask?.cancel()
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            func resume(with result: Result<SpeechTranscriptionResult, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resume(with: .failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    resume(with: .failure(SpeechTranscriptionError.emptyTranscript))
                    return
                }
                resume(
                    with: .success(
                        SpeechTranscriptionResult(
                            text: text,
                            usedOnDeviceRecognition: requiresOnDeviceRecognition
                        )
                    )
                )
            }
            recognitionTask = task
            registerCancellation? {
                task.cancel()
            }
        }
    }
}
