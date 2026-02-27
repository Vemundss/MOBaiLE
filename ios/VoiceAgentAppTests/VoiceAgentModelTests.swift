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

    func testChatEnvelopeDecodingWithArtifacts() throws {
        let json = """
        {
          "type":"assistant_response",
          "version":"1.0",
          "message_id":"msg-1",
          "created_at":"2026-02-27T09:00:00Z",
          "summary":"Done",
          "sections":[{"title":"Result","body":"Created file"}],
          "agenda_items":[],
          "artifacts":[{"type":"file","title":"hello.py","path":"/Users/test/hello.py","mime":"text/x-python"}]
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ChatEnvelope.self, from: data)
        XCTAssertEqual(decoded.summary, "Done")
        XCTAssertEqual(decoded.artifacts.count, 1)
        XCTAssertEqual(decoded.artifacts.first?.path, "/Users/test/hello.py")
    }
}
