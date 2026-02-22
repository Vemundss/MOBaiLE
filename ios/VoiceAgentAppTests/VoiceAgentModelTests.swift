import XCTest
@testable import VoiceAgentApp

final class VoiceAgentModelTests: XCTestCase {
    func testRunRecordDecoding() throws {
        let json = """
        {
          "run_id":"run-123",
          "session_id":"session-1",
          "utterance_text":"hello",
          "status":"completed",
          "summary":"Run completed successfully",
          "events":[
            {"type":"action.started","action_index":0,"message":"starting run"}
          ]
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: data)
        XCTAssertEqual(decoded.runId, "run-123")
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events.first?.type, "action.started")
    }
}
