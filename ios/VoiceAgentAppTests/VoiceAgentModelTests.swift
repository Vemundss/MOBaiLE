import XCTest
@testable import VoiceAgentApp

final class VoiceAgentModelTests: XCTestCase {
    func testRunRecordDecoding() throws {
        let json = """
        {
          "run_id":"run-123",
          "session_id":"session-1",
          "utterance_text":"hello",
          "status":"blocked",
          "pending_human_unblock":{
            "instructions":"Complete the CAPTCHA, then reply from the phone.",
            "suggested_reply":"I completed the unblock step."
          },
          "summary":"Human unblock required",
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
        XCTAssertEqual(decoded.pendingHumanUnblock?.instructions, "Complete the CAPTCHA, then reply from the phone.")
        XCTAssertEqual(decoded.pendingHumanUnblock?.suggestedReply, "I completed the unblock step.")
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

    func testResolveImageURLRejectsExternalHTTPSURL() {
        let resolved = _test_resolveImageURL("https://example.com/plot.png", serverURL: "http://127.0.0.1:8000")
        XCTAssertNil(resolved)
    }

    func testResolveImageURLAcceptsBackendProtectedURL() {
        let resolved = _test_resolveImageURL(
            "http://127.0.0.1:8000/v1/files?path=%2FUsers%2Ftest%2Fplot.png",
            serverURL: "http://127.0.0.1:8000"
        )
        XCTAssertEqual(resolved, "http://127.0.0.1:8000/v1/files?path=%2FUsers%2Ftest%2Fplot.png")
    }

    func testPendingPairingWarnsForRFC1918HTTP() {
        let pending = VoiceAgentViewModel.PendingPairing(
            serverURL: "http://192.168.1.20:8000",
            sessionID: "iphone-app",
            pairCode: "123456",
            legacyToken: nil
        )
        XCTAssertEqual(pending.badgeText, "LOCAL")
        XCTAssertNotNil(pending.localNetworkWarning)
    }

    func testPendingPairingDoesNotWarnForTailscaleHTTP() {
        let pending = VoiceAgentViewModel.PendingPairing(
            serverURL: "http://mobaile.ts.net:8000",
            sessionID: "iphone-app",
            pairCode: "123456",
            legacyToken: nil
        )
        XCTAssertEqual(pending.badgeText, "LOCAL")
        XCTAssertNil(pending.localNetworkWarning)
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
        XCTAssertNil(decoded.pendingHumanUnblock)
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

    func testSessionContextDecodingSupportsResolvedDefaults() throws {
        let json = """
        {
          "session_id":"iphone-app",
          "executor":"codex",
          "working_directory":"/Users/test/work/project",
          "resolved_working_directory":"/Users/test/work/project",
          "updated_at":"2026-03-26T18:00:00Z"
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SessionContext.self, from: data)
        XCTAssertEqual(decoded.sessionId, "iphone-app")
        XCTAssertEqual(decoded.executor, "codex")
        XCTAssertEqual(decoded.workingDirectory, "/Users/test/work/project")
        XCTAssertEqual(decoded.resolvedWorkingDirectory, "/Users/test/work/project")
    }

    func testSlashCommandDescriptorDecodingSupportsDynamicCatalog() throws {
        let json = """
        {
          "id":"executor",
          "title":"Executor",
          "description":"Show or switch the active executor.",
          "usage":"/executor [codex|claude|local]",
          "group":"Runtime",
          "aliases":["exec","agent"],
          "symbol":"bolt.horizontal.circle",
          "argument_kind":"enum",
          "argument_options":["codex","claude","local"],
          "argument_placeholder":"executor"
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SlashCommandDescriptor.self, from: data)
        let command = ComposerSlashCommand(descriptor: decoded)
        XCTAssertEqual(command.id, "executor")
        XCTAssertEqual(command.group, "Runtime")
        XCTAssertEqual(command.argumentOptions, ["codex", "claude", "local"])
        XCTAssertTrue(command.acceptsArguments)
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

    func testSlashCommandStateForBareSlashShowsCatalog() {
        let state = _test_resolveComposerSlashCommandState("/")
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.query, "")
        XCTAssertEqual(state?.arguments, "")
        XCTAssertEqual(state?.suggestions.first?.id, "new")
        XCTAssertTrue(state?.suggestions.contains(where: { $0.id == "browse" }) == true)
    }

    func testSlashCommandStateParsesArguments() {
        let state = _test_resolveComposerSlashCommandState("/browse ios/VoiceAgentApp")
        XCTAssertEqual(state?.exactMatch?.id, "browse")
        XCTAssertEqual(state?.arguments, "ios/VoiceAgentApp")
    }

    func testSlashCommandStateTreatsUnknownAlphaInputAsCommandContext() {
        let state = _test_resolveComposerSlashCommandState("/unknown-command")
        XCTAssertNotNil(state)
        XCTAssertNil(state?.exactMatch)
        XCTAssertTrue(state?.hasUnknownCommand == true)
    }

    func testSlashCommandStateIgnoresAbsolutePaths() {
        let state = _test_resolveComposerSlashCommandState("/Users/test/Mobile Documents/repo")
        XCTAssertNil(state)
    }

    func testSlashCommandStateUsesBackendCatalogEntries() {
        let commands = ComposerSlashCommand.mergedCatalog(
            backend: [
                ComposerSlashCommand(
                    descriptor: SlashCommandDescriptor(
                    id: "executor",
                    title: "Executor",
                    description: "Show or switch the active executor.",
                    usage: "/executor [codex|claude|local]",
                    group: "Runtime",
                    aliases: ["exec"],
                    symbol: "bolt.horizontal.circle",
                    argumentKind: "enum",
                        argumentOptions: ["codex", "claude", "local"],
                        argumentPlaceholder: "executor"
                    )
                )
            ]
        )
        let state = _test_resolveComposerSlashCommandState("/exec", commands: commands)
        XCTAssertEqual(state?.exactMatch?.id, "executor")
        XCTAssertEqual(state?.suggestions.first?.id, "executor")
    }

    @MainActor
    func testRunEventsStayBoundToOriginThreadAfterSwitch() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        guard let originThreadID = vm.activeThreadID else {
            XCTFail("Expected an origin thread")
            return
        }
        vm.createNewThread()
        guard let otherThreadID = vm.activeThreadID else {
            XCTFail("Expected a second thread")
            return
        }

        defer {
            vm.deleteThread(otherThreadID)
            vm.deleteThread(originThreadID)
        }

        vm.switchToThread(originThreadID)
        let runID = "test-run-\(UUID().uuidString)"
        vm._test_updateThreadMetadata(
            threadID: originThreadID,
            runID: runID,
            statusText: "Running...",
            activeRunExecutor: "codex"
        )
        vm._test_bindObservedRun(runID: runID, threadID: originThreadID)

        vm.switchToThread(otherThreadID)
        let event = ExecutionEvent(
            type: "assistant.message",
            actionIndex: nil,
            message: "Bound to the origin thread",
            eventID: "evt-\(UUID().uuidString)",
            createdAt: nil
        )
        vm._test_ingestRunEvents([event], runID: runID, threadID: originThreadID)

        XCTAssertTrue(vm.conversation.isEmpty)
        XCTAssertTrue(vm.events.isEmpty)

        vm.switchToThread(originThreadID)

        XCTAssertEqual(vm.conversation.last?.text, "Bound to the origin thread")
        XCTAssertEqual(vm.events.last?.message, "Bound to the origin thread")
    }

    @MainActor
    func testConcurrentObservedRunsKeepPerThreadEventState() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        guard let firstThreadID = vm.activeThreadID else {
            XCTFail("Expected a first thread")
            return
        }
        vm.createNewThread()
        guard let secondThreadID = vm.activeThreadID else {
            XCTFail("Expected a second thread")
            return
        }

        defer {
            vm.deleteThread(secondThreadID)
            vm.deleteThread(firstThreadID)
        }

        let firstRunID = "test-run-a-\(UUID().uuidString)"
        let secondRunID = "test-run-b-\(UUID().uuidString)"

        vm._test_updateThreadMetadata(
            threadID: firstThreadID,
            runID: firstRunID,
            statusText: "Running...",
            activeRunExecutor: "codex"
        )
        vm._test_updateThreadMetadata(
            threadID: secondThreadID,
            runID: secondRunID,
            statusText: "Running...",
            activeRunExecutor: "codex"
        )
        vm._test_bindObservedRun(runID: firstRunID, threadID: firstThreadID)
        vm._test_bindObservedRun(runID: secondRunID, threadID: secondThreadID)

        let firstEvent = ExecutionEvent(
            type: "assistant.message",
            actionIndex: nil,
            message: "First thread response",
            eventID: "evt-a-\(UUID().uuidString)",
            createdAt: nil
        )
        let secondEvent = ExecutionEvent(
            type: "assistant.message",
            actionIndex: nil,
            message: "Second thread response",
            eventID: "evt-b-\(UUID().uuidString)",
            createdAt: nil
        )

        vm._test_ingestRunEvents([firstEvent], runID: firstRunID, threadID: firstThreadID)
        vm._test_ingestRunEvents([secondEvent], runID: secondRunID, threadID: secondThreadID)

        XCTAssertEqual(vm.conversation.last?.text, "Second thread response")
        XCTAssertEqual(vm.events.last?.message, "Second thread response")

        vm.switchToThread(firstThreadID)
        XCTAssertEqual(vm.conversation.last?.text, "First thread response")
        XCTAssertEqual(vm.events.last?.message, "First thread response")

        vm.switchToThread(secondThreadID)
        XCTAssertEqual(vm.conversation.last?.text, "Second thread response")
        XCTAssertEqual(vm.events.last?.message, "Second thread response")
    }
}
