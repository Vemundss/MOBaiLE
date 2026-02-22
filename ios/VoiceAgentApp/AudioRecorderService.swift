import AVFoundation
import Foundation

enum RecorderError: Error, LocalizedError {
    case permissionDenied
    case recorderUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied."
        case .recorderUnavailable:
            return "Audio recorder unavailable."
        }
    }
}

final class AudioRecorderService: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var currentFileURL: URL?

    func start() async throws {
        let allowed = try await requestPermission()
        guard allowed else { throw RecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voice_agent_recording.m4a")
        currentFileURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        guard recorder?.record() == true else {
            throw RecorderError.recorderUnavailable
        }
    }

    func stop() -> URL? {
        recorder?.stop()
        return currentFileURL
    }

    private func requestPermission() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }
}
