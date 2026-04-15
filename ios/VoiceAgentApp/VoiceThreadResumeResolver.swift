import Foundation

enum VoiceThreadResumeTarget: Equatable {
    case existing(UUID)
    case createNewThread
}

enum VoiceThreadResumeResolver {
    static func resolve(
        activeVoiceModeThreadID: UUID?,
        lastVoiceModeThreadID: UUID?,
        currentThreadID: UUID?,
        existingThreadIDs: Set<UUID>
    ) -> VoiceThreadResumeTarget {
        if let activeVoiceModeThreadID, existingThreadIDs.contains(activeVoiceModeThreadID) {
            return .existing(activeVoiceModeThreadID)
        }
        if let lastVoiceModeThreadID, existingThreadIDs.contains(lastVoiceModeThreadID) {
            return .existing(lastVoiceModeThreadID)
        }
        if let currentThreadID, existingThreadIDs.contains(currentThreadID) {
            return .existing(currentThreadID)
        }
        return .createNewThread
    }
}
