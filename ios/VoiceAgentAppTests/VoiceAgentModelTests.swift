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

    func testExtractImagePathKeepsAbsolutePathWithSpaces() {
        let raw = "`/Users/test/Mobile Documents/plots/plot_xy_temp.png`"
        let extracted = _test_extractImagePath(raw)
        XCTAssertEqual(extracted, "/Users/test/Mobile Documents/plots/plot_xy_temp.png")
    }

    func testResolveImageURLEncodesAbsolutePathWithSpaces() {
        let raw = "/Users/test/Mobile Documents/plots/plot_xy_temp.png"
        let resolved = _test_resolveImageURL(raw, serverURL: "http://127.0.0.1:8000")
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved?.hasPrefix("http://127.0.0.1:8000/v1/files?path=") == true)
        XCTAssertTrue(resolved?.contains("Mobile%20Documents") == true)
        XCTAssertTrue(resolved?.contains(".png") == true)
    }

    func testResolveImageURLRejectsPlaceholderPath() {
        let resolved = _test_resolveImageURL("/absolute/path/to/file.png", serverURL: "http://127.0.0.1:8000")
        XCTAssertNil(resolved)
    }

    func testConversationMessageDecodingDefaultsAttachmentsToEmpty() throws {
        let json = """
        {
          "id":"2E2B216F-5A6F-4B2D-8FCA-0C109D5C4AC8",
          "role":"user",
          "text":"hello"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertTrue(decoded.attachments.isEmpty)
    }

    func testChatThreadDecodingDefaultsDraftStateToEmpty() throws {
        let json = """
        {
          "id":"2E2B216F-5A6F-4B2D-8FCA-0C109D5C4AC8",
          "title":"Chat",
          "updatedAt":761238000,
          "conversation":[],
          "runID":"",
          "summaryText":"",
          "transcriptText":"",
          "statusText":"Idle",
          "resolvedWorkingDirectory":"",
          "activeRunExecutor":"codex"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ChatThread.self, from: data)
        XCTAssertEqual(decoded.title, "Chat")
        XCTAssertEqual(decoded.draftText, "")
        XCTAssertTrue(decoded.draftAttachments.isEmpty)
    }

    func testRuntimeConfigDecodingSupportsExecutorDiscovery() throws {
        let json = """
        {
          "security_mode":"safe",
          "default_executor":"claude",
          "available_executors":["codex","claude"],
          "executors":[
            {"id":"local","title":"Local fallback","kind":"internal","available":true,"default":false,"internal_only":true},
            {"id":"codex","title":"Codex","kind":"agent","available":true,"default":false,"internal_only":false,"model":"gpt-5.1"},
            {"id":"claude","title":"Claude Code","kind":"agent","available":true,"default":true,"internal_only":false,"model":"claude-sonnet-4-5"}
          ],
          "transcribe_provider":"openai",
          "transcribe_ready":true,
          "codex_model":"gpt-5.1",
          "claude_model":"claude-sonnet-4-5",
          "workdir_root":"/Users/test/work",
          "allow_absolute_file_reads":false,
          "file_roots":["/Users/test/work"]
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(RuntimeConfig.self, from: data)
        XCTAssertEqual(decoded.defaultExecutor, "claude")
        XCTAssertEqual(decoded.availableExecutors, ["codex", "claude"])
        XCTAssertEqual(decoded.executors?.count, 3)
        XCTAssertEqual(decoded.executors?.first(where: { $0.id == "claude" })?.isDefault, true)
        XCTAssertEqual(decoded.transcribeProvider, "openai")
        XCTAssertEqual(decoded.transcribeReady, true)
        XCTAssertEqual(decoded.codexModel, "gpt-5.1")
        XCTAssertEqual(decoded.claudeModel, "claude-sonnet-4-5")
    }

    func testDraftAttachmentRoundTripsThroughCodable() throws {
        let attachment = DraftAttachment(
            id: UUID(uuidString: "2E2B216F-5A6F-4B2D-8FCA-0C109D5C4AC8") ?? UUID(),
            localFileURL: URL(fileURLWithPath: "/tmp/demo.txt"),
            fileName: "demo.txt",
            mimeType: "text/plain",
            kind: .code,
            sizeBytes: 128
        )
        let data = try JSONEncoder().encode([attachment])
        let decoded = try JSONDecoder().decode([DraftAttachment].self, from: data)
        XCTAssertEqual(decoded, [attachment])
    }

    func testExtractInlineArtifactTitlesFindsMarkdownFileLinks() {
        let text = """
        Review these attachments.

        [notes.txt](/Users/test/Mobile Documents/session/notes.txt)
        [report.pdf](/Users/test/Mobile Documents/session/report.pdf)
        """
        let extracted = _test_extractInlineArtifactTitles(text, serverURL: "http://127.0.0.1:8000")
        XCTAssertEqual(extracted, ["notes.txt", "report.pdf"])
    }
}
