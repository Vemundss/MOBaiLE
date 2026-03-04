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
    struct SilenceConfig {
        let thresholdDB: Float
        let requiredSilenceDuration: TimeInterval
        let minimumRecordDuration: TimeInterval

        init(
            thresholdDB: Float = -42,
            requiredSilenceDuration: TimeInterval = 1.2,
            minimumRecordDuration: TimeInterval = 0.7
        ) {
            self.thresholdDB = thresholdDB
            self.requiredSilenceDuration = requiredSilenceDuration
            self.minimumRecordDuration = minimumRecordDuration
        }
    }

    private var recorder: AVAudioRecorder?
    private(set) var currentFileURL: URL?
    private var meteringTimer: Timer?
    private var silenceConfig: SilenceConfig?
    private var onSilenceDetected: (() -> Void)?
    private var silenceStartAt: Date?
    private var recordingStartAt: Date?
    private var hasDeliveredSilenceEvent = false

    func start(
        silenceConfig: SilenceConfig? = nil,
        onSilenceDetected: (() -> Void)? = nil
    ) async throws {
        let allowed = try await requestPermission()
        guard allowed else { throw RecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
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
        recorder?.isMeteringEnabled = silenceConfig != nil
        guard recorder?.record() == true else {
            throw RecorderError.recorderUnavailable
        }
        self.silenceConfig = silenceConfig
        self.onSilenceDetected = onSilenceDetected
        recordingStartAt = Date()
        silenceStartAt = nil
        hasDeliveredSilenceEvent = false
        startSilenceMonitoringIfNeeded()
    }

    func stop() -> URL? {
        stopSilenceMonitoring()
        recorder?.stop()
        silenceConfig = nil
        onSilenceDetected = nil
        recordingStartAt = nil
        silenceStartAt = nil
        hasDeliveredSilenceEvent = false
        return currentFileURL
    }

    private func requestPermission() async throws -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
    }

    private func startSilenceMonitoringIfNeeded() {
        guard silenceConfig != nil else { return }
        stopSilenceMonitoring()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.evaluateSilence()
        }
        meteringTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSilenceMonitoring() {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    private func evaluateSilence() {
        guard let recorder, recorder.isRecording, let config = silenceConfig else { return }
        guard !hasDeliveredSilenceEvent else { return }
        guard let recordingStartAt else { return }

        recorder.updateMeters()
        let elapsed = Date().timeIntervalSince(recordingStartAt)
        if elapsed < config.minimumRecordDuration {
            return
        }

        let avgPower = recorder.averagePower(forChannel: 0)
        if avgPower <= config.thresholdDB {
            if let silenceStartAt {
                let silenceElapsed = Date().timeIntervalSince(silenceStartAt)
                if silenceElapsed >= config.requiredSilenceDuration {
                    hasDeliveredSilenceEvent = true
                    stopSilenceMonitoring()
                    onSilenceDetected?()
                }
            } else {
                silenceStartAt = Date()
            }
        } else {
            silenceStartAt = nil
        }
    }
}
