import XCTest
@testable import VoiceAgentApp

final class VoiceThreadResumeResolverTests: XCTestCase {
    func testResolverPrefersActiveVoiceModeThread() {
        let active = UUID()
        let last = UUID()
        let current = UUID()

        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: active,
            lastVoiceModeThreadID: last,
            currentThreadID: current,
            existingThreadIDs: [active, last, current]
        )

        XCTAssertEqual(resolved, .existing(active))
    }

    func testResolverFallsBackToLastVoiceModeThreadBeforeCurrentThread() {
        let last = UUID()
        let current = UUID()

        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: nil,
            lastVoiceModeThreadID: last,
            currentThreadID: current,
            existingThreadIDs: [last, current]
        )

        XCTAssertEqual(resolved, .existing(last))
    }

    func testResolverIgnoresDeletedStoredThreads() {
        let deleted = UUID()
        let current = UUID()

        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: nil,
            lastVoiceModeThreadID: deleted,
            currentThreadID: current,
            existingThreadIDs: [current]
        )

        XCTAssertEqual(resolved, .existing(current))
    }

    func testResolverRequestsNewThreadWhenNothingReusableExists() {
        let resolved = VoiceThreadResumeResolver.resolve(
            activeVoiceModeThreadID: nil,
            lastVoiceModeThreadID: nil,
            currentThreadID: nil,
            existingThreadIDs: []
        )

        XCTAssertEqual(resolved, .createNewThread)
    }
}
