import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import XCTest
@testable import VoiceAgentApp

final class VoiceAgentModelTests: XCTestCase {
    @MainActor
    func testIncomingURLStoreBuffersUntilConsumed() {
        let store = IncomingURLStore()
        let url = URL(string: "mobaile://pair?pair_code=abc&server_url=http%3A%2F%2F127.0.0.1%3A8000")!

        store.receive(url)

        XCTAssertEqual(store.pendingURL, url)
        XCTAssertEqual(store.takePendingURL(), url)
        XCTAssertNil(store.pendingURL)
    }

    @MainActor
    func testApplyPairingURLStagesPendingPairingFromCustomScheme() {
        let vm = VoiceAgentViewModel()
        let url = URL(string: "mobaile://pair?server_url=http%3A%2F%2Fvemunds-macbook-air.tail6a5903.ts.net%3A8000&server_url=http%3A%2F%2F100.111.99.51%3A8000&pair_code=abc123&session_id=iphone-app")!

        vm.applyPairingURL(url)

        XCTAssertEqual(vm.pendingPairing?.serverURL, "http://vemunds-macbook-air.tail6a5903.ts.net:8000")
        XCTAssertEqual(vm.pendingPairing?.serverURLs ?? [], [
            "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
        ])
        XCTAssertEqual(vm.pendingPairing?.pairCode, "abc123")
        XCTAssertEqual(vm.pendingPairing?.sessionID, "iphone-app")
    }

    @MainActor
    func testApplyPairingPayloadStagesPendingPairingFromRawScannerText() {
        let vm = VoiceAgentViewModel()

        let didStage = vm.applyPairingPayload(
            "  mobaile://pair?server_url=http%3A%2F%2F127.0.0.1%3A8000&pair_code=abc123&session_id=iphone-app  "
        )

        XCTAssertTrue(didStage)
        XCTAssertEqual(vm.pendingPairing?.serverURL, "http://127.0.0.1:8000")
        XCTAssertEqual(vm.pendingPairing?.pairCode, "abc123")
        XCTAssertEqual(vm.pendingPairing?.sessionID, "iphone-app")
    }

    @MainActor
    func testApplyPairingPayloadRejectsNonMobailePayload() {
        let vm = VoiceAgentViewModel()

        let didStage = vm.applyPairingPayload("https://example.com/not-a-pairing-link")

        XCTAssertFalse(didStage)
        XCTAssertNil(vm.pendingPairing)
        XCTAssertEqual(vm.errorText, "This QR code is not a MOBaiLE pairing link.")
    }

    @MainActor
    func testApplyPairingPayloadExtractsPairingLinkFromPastedText() {
        let vm = VoiceAgentViewModel()

        let didStage = vm.applyPairingPayload(
            """
            Pair this phone with:
            mobaile://pair?server_url=http%3A%2F%2F127.0.0.1%3A8000&pair_code=abc123&session_id=iphone-app
            """
        )

        XCTAssertTrue(didStage)
        XCTAssertEqual(vm.pendingPairing?.serverURL, "http://127.0.0.1:8000")
        XCTAssertEqual(vm.pendingPairing?.pairCode, "abc123")
        XCTAssertEqual(vm.pendingPairing?.sessionID, "iphone-app")
    }

    @MainActor
    func testRegisterConnectionRepairIfNeededStagesReconnectState() {
        let vm = VoiceAgentViewModel()
        vm.serverURL = "http://vemunds-macbook-air.tail6a5903.ts.net:8000"
        vm.apiToken = "stale-token"

        let message = vm.registerConnectionRepairIfNeeded(
            from: APIError.httpError(401, #"{"detail":"missing or invalid bearer token"}"#)
        )

        XCTAssertEqual(
            message,
            "This phone is no longer paired with vemunds-macbook-air.tail6a5903.ts.net. Open the latest pairing QR on that computer and scan it again here."
        )
        XCTAssertTrue(vm.needsConnectionRepair)
        XCTAssertEqual(vm.connectionRepairTitle, "Reconnect this phone")
        XCTAssertEqual(vm.connectionRepairMessage, message)
        XCTAssertTrue(vm.hasConfiguredConnection)
    }

    @MainActor
    func testRegisterConnectionRepairIfNeededIgnoresNonAuthErrors() {
        let vm = VoiceAgentViewModel()

        let message = vm.registerConnectionRepairIfNeeded(
            from: APIError.httpError(503, #"{"detail":"server auth token is not configured"}"#)
        )

        XCTAssertNil(message)
        XCTAssertFalse(vm.needsConnectionRepair)
    }

    @MainActor
    func testConnectionRepairStatePersistsAcrossViewModelReload() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        vm.serverURL = "http://vemunds-macbook-air.tail6a5903.ts.net:8000"
        vm.apiToken = "stale-token"

        _ = vm.registerConnectionRepairIfNeeded(
            from: APIError.httpError(401, #"{"detail":"missing or invalid bearer token"}"#)
        )

        let reloaded = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )

        XCTAssertTrue(reloaded.needsConnectionRepair)
        XCTAssertEqual(reloaded.connectionRepairTitle, "Reconnect this phone")
        XCTAssertTrue(reloaded.connectionRepairMessage.contains("vemunds-macbook-air.tail6a5903.ts.net"))
    }

    @MainActor
    func testApplyPairedClientCredentialsStoresRefreshTokenAndClearsRepairState() {
        let vm = VoiceAgentViewModel()
        vm.serverURL = "http://127.0.0.1:8000"
        vm.apiToken = "stale-token"
        _ = vm.registerConnectionRepairIfNeeded(
            from: APIError.httpError(401, #"{"detail":"missing or invalid bearer token"}"#)
        )

        vm.applyPairedClientCredentials(
            PairExchangeResponse(
                apiToken: "fresh-token",
                refreshToken: "refresh-token",
                sessionId: "iphone-app",
                securityMode: "safe",
                serverURL: "https://relay.example.com",
                serverURLs: ["https://relay.example.com", "http://100.111.99.51:8000"]
            ),
            fallbackPrimaryServerURL: "http://127.0.0.1:8000"
        )

        XCTAssertEqual(vm.apiToken, "fresh-token")
        XCTAssertEqual(vm.sessionID, "iphone-app")
        XCTAssertEqual(vm.serverURL, "https://relay.example.com")
        XCTAssertEqual(vm.connectionCandidateServerURLsForTesting, [
            "https://relay.example.com",
            "http://100.111.99.51:8000",
        ])
        XCTAssertTrue(vm.hasPairedRefreshCredential)
        XCTAssertFalse(vm.needsConnectionRepair)
    }

    func testPairingQRCodeImageDecoderDecodesGeneratedQRCode() throws {
        let payload = "mobaile://pair?server_url=http%3A%2F%2F127.0.0.1%3A8000&pair_code=abc123"
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        let outputImage = try XCTUnwrap(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)))
        let cgImage = try XCTUnwrap(CIContext().createCGImage(outputImage, from: outputImage.extent))
        let pngData = try XCTUnwrap(UIImage(cgImage: cgImage).pngData())

        let decodedPayload = try PairingQRCodeImageDecoder.decodePayload(from: pngData)

        XCTAssertEqual(decodedPayload, payload)
    }

    func testPairingQRCodeImageDecoderRejectsImageWithoutQRCode() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let pngData = try XCTUnwrap(image.pngData())

        XCTAssertThrowsError(try PairingQRCodeImageDecoder.decodePayload(from: pngData)) { error in
            XCTAssertEqual(error as? PairingQRCodeImageDecoder.DecodeError, .noCodeFound)
        }
    }

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

    func testExecutionEventDecodingSupportsTypedActivityFields() throws {
        let json = #"{"type":"activity.updated","message":"Running commands.","stage":"executing","title":"Executing","display_message":"Running commands.","level":"info"}"#

        let decoded = try JSONDecoder().decode(ExecutionEvent.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.type, "activity.updated")
        XCTAssertEqual(decoded.stage, "executing")
        XCTAssertEqual(decoded.title, "Executing")
        XCTAssertEqual(decoded.displayMessage, "Running commands.")
        XCTAssertEqual(decoded.level, "info")
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

    func testResolveImageURLRewritesStaleBackendHostToActiveServer() {
        let resolved = _test_resolveImageURL(
            "http://192.168.1.20:8000/v1/files?path=%2FUsers%2Ftest%2Fplot.png",
            serverURL: "https://relay.example.com"
        )
        XCTAssertEqual(resolved, "https://relay.example.com/v1/files?path=%2FUsers%2Ftest%2Fplot.png")
    }

    func testPendingPairingWarnsForRFC1918HTTP() {
        let pending = VoiceAgentViewModel.PendingPairing(
            serverURL: "http://192.168.1.20:8000",
            serverURLs: ["http://192.168.1.20:8000"],
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
            serverURLs: ["http://mobaile.ts.net:8000"],
            sessionID: "iphone-app",
            pairCode: "123456",
            legacyToken: nil
        )
        XCTAssertEqual(pending.badgeText, "LOCAL")
        XCTAssertNil(pending.localNetworkWarning)
    }

    @MainActor
    func testPromoteResolvedServerURLDoesNotDemoteTailscaleToLanFallback() {
        let vm = VoiceAgentViewModel()

        vm.applyPairedClientCredentials(
            PairExchangeResponse(
                apiToken: "fresh-token",
                refreshToken: "refresh-token",
                sessionId: "iphone-app",
                securityMode: "full-access",
                serverURL: "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
                serverURLs: [
                    "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
                    "http://100.111.99.51:8000",
                    "http://192.168.86.122:8000",
                ]
            ),
            fallbackPrimaryServerURL: "http://vemunds-macbook-air.tail6a5903.ts.net:8000"
        )

        vm.promoteResolvedServerURL("http://192.168.86.122:8000")

        XCTAssertEqual(vm.serverURL, "http://vemunds-macbook-air.tail6a5903.ts.net:8000")
        XCTAssertEqual(vm.connectionCandidateServerURLsForTesting, [
            "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
            "http://192.168.86.122:8000",
        ])
    }

    @MainActor
    func testPromoteResolvedServerURLCanUpgradeLanToTailscale() {
        let vm = VoiceAgentViewModel()
        vm.serverURL = "http://192.168.86.122:8000"
        vm.persistSettings()

        vm.promoteResolvedServerURL("http://vemunds-macbook-air.tail6a5903.ts.net:8000")

        XCTAssertEqual(vm.serverURL, "http://vemunds-macbook-air.tail6a5903.ts.net:8000")
        XCTAssertEqual(vm.connectionCandidateServerURLsForTesting, [
            "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            "http://192.168.86.122:8000",
        ])
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
        XCTAssertEqual(decoded.presentation, .standard)
        XCTAssertNil(decoded.sourceRunID)
    }

    func testConversationMessageDecodingSupportsLiveActivityPresentation() throws {
        let json = """
        {
          "id":"2E2B216F-5A6F-4B2D-8FCA-0C109D5C4AC8",
          "role":"assistant",
          "text":"Checking the workspace…",
          "presentation":"liveActivity",
          "source_run_id":"run-123"
        }
        """

        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.presentation, .liveActivity)
        XCTAssertEqual(decoded.sourceRunID, "run-123")
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

    func testChatThreadPresentationStatusMarksFreshThreadReady() {
        let thread = ChatThread(
            id: UUID(),
            title: "New Chat",
            updatedAt: Date(),
            conversation: [],
            runID: "",
            summaryText: "",
            transcriptText: "",
            statusText: "Idle",
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex"
        )

        XCTAssertEqual(thread.presentationStatus, .ready)
    }

    func testChatThreadPresentationStatusPrefersNeedsInputOverDraft() {
        let thread = ChatThread(
            id: UUID(),
            title: "Blocked",
            updatedAt: Date(),
            conversation: [],
            runID: "run-123",
            summaryText: "",
            transcriptText: "",
            statusText: "Blocked on human input",
            pendingHumanUnblock: HumanUnblockRequest(instructions: "Approve login"),
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex",
            draftText: "I completed the login step."
        )

        XCTAssertEqual(thread.presentationStatus, .needsInput)
    }

    func testChatThreadPresentationStatusMarksDraftWhenUnsavedInputExists() {
        let thread = ChatThread(
            id: UUID(),
            title: "Draft",
            updatedAt: Date(),
            conversation: [],
            runID: "",
            summaryText: "",
            transcriptText: "",
            statusText: "Idle",
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex",
            draftText: "review the latest build"
        )

        XCTAssertEqual(thread.presentationStatus, .draft)
    }

    func testChatThreadPresentationStatusTreatsTimedOutRunAsFailed() {
        let thread = ChatThread(
            id: UUID(),
            title: "Timed Out",
            updatedAt: Date(),
            conversation: [],
            runID: "run-123",
            summaryText: "Run timed out after 30s",
            transcriptText: "",
            statusText: "Timed out",
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex"
        )

        XCTAssertEqual(thread.presentationStatus, .failed)
    }

    func testRunDiagnosticsDerivedCapturesActivityAndErrorSignals() {
        let diagnostics = RunDiagnostics.derived(
            runId: "run-123",
            status: "Run status: failed",
            summary: "Calendar query failed before the summary was ready.",
            events: [
                ExecutionEvent(
                    seq: 0,
                    type: "activity.started",
                    message: "Reviewing the request.",
                    stage: "planning",
                    title: "Planning",
                    displayMessage: "Reviewing the request.",
                    level: "info"
                ),
                ExecutionEvent(
                    seq: 1,
                    type: "activity.updated",
                    message: "Calendar query failed.",
                    stage: "executing",
                    title: "Executing",
                    displayMessage: "Calendar query failed.",
                    level: "error"
                ),
            ]
        )

        XCTAssertEqual(diagnostics.runId, "run-123")
        XCTAssertEqual(diagnostics.status, "failed")
        XCTAssertEqual(diagnostics.eventCount, 2)
        XCTAssertEqual(diagnostics.activityStageCounts, ["planning": 1, "executing": 1])
        XCTAssertEqual(diagnostics.latestActivity, "Calendar query failed.")
        XCTAssertFalse(diagnostics.hasStderr)
        XCTAssertEqual(diagnostics.lastError, "Calendar query failed.")
    }

    func testSessionContextDecodingIncludesLatestRunState() throws {
        let json = """
        {
          "session_id":"session-1",
          "executor":"codex",
          "working_directory":"/Users/test/project",
          "resolved_working_directory":"/Users/test/project",
          "latest_run_id":"run-123",
          "latest_run_status":"blocked",
          "latest_run_summary":"Complete the CAPTCHA",
          "latest_run_updated_at":"2026-03-27T12:00:00Z",
          "latest_run_pending_human_unblock":{
            "instructions":"Complete the CAPTCHA, then reply from the phone.",
            "suggested_reply":"I completed the unblock step."
          },
          "updated_at":"2026-03-27T12:00:01Z"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SessionContext.self, from: data)
        XCTAssertEqual(decoded.sessionId, "session-1")
        XCTAssertEqual(decoded.latestRunId, "run-123")
        XCTAssertEqual(decoded.latestRunStatus, "blocked")
        XCTAssertEqual(decoded.latestRunSummary, "Complete the CAPTCHA")
        XCTAssertEqual(decoded.latestRunPendingHumanUnblock?.instructions, "Complete the CAPTCHA, then reply from the phone.")
    }

    func testChatThreadStorePersistsPendingHumanUnblock() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dbURL = baseURL.appendingPathComponent("threads.sqlite3")
        let store = ChatThreadStore(dbURL: dbURL)
        let threadID = UUID()
        store.upsertThread(
            ChatThread(
                id: threadID,
                title: "Blocked Run",
                updatedAt: Date(timeIntervalSince1970: 1_742_000_000),
                conversation: [],
                runID: "run-123",
                summaryText: "Complete the CAPTCHA",
                transcriptText: "",
                statusText: "Run status: blocked",
                pendingHumanUnblock: HumanUnblockRequest(
                    instructions: "Complete the CAPTCHA, then reply from the phone."
                ),
                resolvedWorkingDirectory: "/Users/test/project",
                activeRunExecutor: "codex"
            )
        )

        let loaded = store.loadThreads()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.pendingHumanUnblock?.instructions, "Complete the CAPTCHA, then reply from the phone.")
    }

    func testChatThreadStorePersistsLiveActivityMessageMetadata() {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dbURL = baseURL.appendingPathComponent("threads.sqlite3")
        let store = ChatThreadStore(dbURL: dbURL)
        let threadID = UUID()

        store.upsertThread(
            ChatThread(
                id: threadID,
                title: "Live Activity",
                updatedAt: Date(),
                conversation: [],
                runID: "run-123",
                summaryText: "",
                transcriptText: "",
                statusText: "Running...",
                resolvedWorkingDirectory: "",
                activeRunExecutor: "codex"
            )
        )
        store.upsertMessage(
            threadID: threadID,
            message: ConversationMessage(
                role: "assistant",
                text: "Checking the repo…",
                presentation: .liveActivity,
                sourceRunID: "run-123"
            ),
            position: 0
        )

        let loaded = store.loadMessages(threadID: threadID)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.presentation, .liveActivity)
        XCTAssertEqual(loaded.first?.sourceRunID, "run-123")
    }

    @MainActor
    func testGuidedProgressUpdatesCoalesceIntoSingleLiveActivityMessage() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        vm._test_bindObservedRun(runID: "run-live", threadID: threadID)

        vm._test_ingestRunEvents(
            [
                ExecutionEvent(type: "chat.message", message: #"{"type":"assistant_response","version":"1.0","summary":"Checking the workspace…","sections":[],"agenda_items":[],"artifacts":[]}"#),
                ExecutionEvent(type: "chat.message", message: #"{"type":"assistant_response","version":"1.0","summary":"Running the test suite…","sections":[],"agenda_items":[],"artifacts":[]}"#)
            ],
            runID: "run-live",
            threadID: threadID
        )

        XCTAssertEqual(vm.conversation.count, 1)
        XCTAssertEqual(vm.conversation.first?.presentation, .liveActivity)
        XCTAssertEqual(vm.conversation.first?.text, "Running the test suite…")
    }

    @MainActor
    func testFinalAssistantMessageCompressesPriorLiveActivity() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        vm._test_bindObservedRun(runID: "run-live", threadID: threadID)

        vm._test_ingestRunEvents(
            [
                ExecutionEvent(type: "chat.message", message: #"{"type":"assistant_response","version":"1.0","summary":"Checking the workspace…","sections":[],"agenda_items":[],"artifacts":[]}"#),
                ExecutionEvent(type: "chat.message", message: #"{"type":"assistant_response","version":"1.0","summary":"Done","sections":[{"title":"Result","body":"Implemented the fix and updated the tests."}],"agenda_items":[],"artifacts":[]}"#)
            ],
            runID: "run-live",
            threadID: threadID
        )

        XCTAssertEqual(vm.conversation.count, 1)
        XCTAssertEqual(vm.conversation.first?.presentation, .standard)
        XCTAssertTrue(vm.conversation.first?.text.contains("Implemented the fix") == true)
    }

    @MainActor
    func testReloadRestoresRunningThreadFromPersistedLiveActivity() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        let runID = "run-restore-\(UUID().uuidString)"

        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Running...",
            activeRunExecutor: "codex"
        )
        vm._test_bindObservedRun(runID: runID, threadID: threadID)
        vm._test_ingestRunEvents(
            [
                ExecutionEvent(
                    type: "activity.updated",
                    message: "Running backend checks.",
                    stage: "executing",
                    title: "Executing",
                    displayMessage: "Running backend checks.",
                    level: "info",
                    eventID: "activity-1",
                    createdAt: nil
                )
            ],
            runID: runID,
            threadID: threadID
        )
        vm._test_persistActiveThreadSnapshot()

        let reloaded = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )

        XCTAssertEqual(reloaded.activeThreadID, threadID)
        XCTAssertEqual(reloaded.runID, runID)
        XCTAssertTrue(reloaded.isLoading)
        XCTAssertTrue(
            reloaded.conversation.contains {
                $0.presentation == .liveActivity
                    && $0.sourceRunID == runID
                    && $0.text.contains("Running backend checks.")
            }
        )
        XCTAssertTrue(reloaded._test_hasObservedRunContext(runID: runID, threadID: threadID))
    }

    @MainActor
    func testTypedActivityEventUpdatesLiveActivityCardWithoutAssistantBubble() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: "run-typed",
            statusText: "Running...",
            activeRunExecutor: "codex"
        )
        vm._test_bindObservedRun(runID: "run-typed", threadID: threadID)

        vm._test_ingestRunEvents(
            [
                ExecutionEvent(
                    type: "activity.updated",
                    message: "Running commands.",
                    stage: "executing",
                    title: "Executing",
                    displayMessage: "Running commands.",
                    level: "info"
                )
            ],
            runID: "run-typed",
            threadID: threadID
        )

        let liveActivityMessages = vm.conversation.filter { $0.presentation == .liveActivity && $0.sourceRunID == "run-typed" }
        let standardAssistantMessages = vm.conversation.filter {
            $0.role == "assistant" && $0.presentation == .standard && $0.sourceRunID == "run-typed"
        }

        XCTAssertEqual(liveActivityMessages.count, 1)
        XCTAssertEqual(liveActivityMessages.first?.text, "Running commands.")
        XCTAssertTrue(standardAssistantMessages.isEmpty)
        XCTAssertEqual(vm.events.count, 1)
    }

    @MainActor
    func testActionStartedEventStillUsesLegacyLiveActivityFallback() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        vm._test_bindObservedRun(runID: "run-fallback", threadID: threadID)

        vm._test_ingestRunEvents(
            [
                ExecutionEvent(
                    type: "action.started",
                    actionIndex: 0,
                    message: "starting run_command"
                )
            ],
            runID: "run-fallback",
            threadID: threadID
        )

        XCTAssertEqual(vm.conversation.count, 1)
        XCTAssertEqual(vm.conversation.first?.presentation, .liveActivity)
        XCTAssertEqual(vm.conversation.first?.text, "Running commands…")
    }

    func testRuntimeConfigDecodingSupportsExecutorDiscovery() throws {
        let json = """
        {
          "security_mode":"safe",
          "default_executor":"claude",
          "available_executors":["codex","claude"],
          "executors":[
            {"id":"local","title":"Local fallback","kind":"internal","available":true,"default":false,"internal_only":true},
            {
              "id":"codex",
              "title":"Codex",
              "kind":"agent",
              "available":true,
              "default":false,
              "internal_only":false,
              "model":"gpt-5.1",
              "settings":[
                {"id":"model","title":"Model","kind":"enum","allow_custom":true,"value":"gpt-5.1","options":["gpt-5.4","gpt-5.4-mini","gpt-5.1"]},
                {"id":"reasoning_effort","title":"Reasoning Effort","kind":"enum","allow_custom":false,"value":"high","options":["minimal","low","medium","high","xhigh"]}
              ]
            },
            {
              "id":"claude",
              "title":"Claude Code",
              "kind":"agent",
              "available":true,
              "default":true,
              "internal_only":false,
              "model":"claude-sonnet-4-5",
              "settings":[
                {"id":"model","title":"Model","kind":"enum","allow_custom":true,"value":"claude-sonnet-4-5","options":["claude-sonnet-4-5"]}
              ]
            }
          ],
          "transcribe_provider":"openai",
          "transcribe_ready":true,
          "codex_model":"gpt-5.1",
          "codex_model_options":["gpt-5.4","gpt-5.4-mini","gpt-5.1"],
          "claude_model":"claude-sonnet-4-5",
          "claude_model_options":["claude-sonnet-4-5"],
          "workdir_root":"/Users/test/work",
          "allow_absolute_file_reads":false,
          "file_roots":["/Users/test/work"],
          "server_url":"https://relay.example.com",
          "server_urls":["https://relay.example.com","http://100.111.99.51:8000"]
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(RuntimeConfig.self, from: data)
        XCTAssertEqual(decoded.defaultExecutor, "claude")
        XCTAssertEqual(decoded.availableExecutors, ["codex", "claude"])
        XCTAssertEqual(decoded.executors?.count, 3)
        XCTAssertEqual(decoded.executors?.first(where: { $0.id == "claude" })?.isDefault, true)
        XCTAssertEqual(decoded.executors?.first(where: { $0.id == "codex" })?.settings?.first?.allowCustom, true)
        XCTAssertEqual(decoded.executors?.first(where: { $0.id == "codex" })?.settings?.last?.options ?? [], ["minimal", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(decoded.transcribeProvider, "openai")
        XCTAssertEqual(decoded.transcribeReady, true)
        XCTAssertEqual(decoded.codexModel, "gpt-5.1")
        XCTAssertEqual(decoded.codexModelOptions ?? [], ["gpt-5.4", "gpt-5.4-mini", "gpt-5.1"])
        XCTAssertEqual(decoded.claudeModel, "claude-sonnet-4-5")
        XCTAssertEqual(decoded.claudeModelOptions ?? [], ["claude-sonnet-4-5"])
        XCTAssertEqual(decoded.serverURL, "https://relay.example.com")
        XCTAssertEqual(decoded.serverURLs ?? [], ["https://relay.example.com", "http://100.111.99.51:8000"])
    }

    func testRuntimeConfigurationCatalogBuildsLegacyFallbackDescriptors() {
        let config = RuntimeConfig(
            securityMode: "workspace-write",
            defaultExecutor: "claude",
            availableExecutors: ["codex", "claude"],
            executors: nil,
            transcribeProvider: nil,
            transcribeReady: nil,
            codexModel: "gpt-5.4",
            codexModelOptions: nil,
            codexReasoningEffort: "high",
            codexReasoningEffortOptions: nil,
            claudeModel: "claude-sonnet-4-5",
            claudeModelOptions: nil,
            workdirRoot: nil,
            allowAbsoluteFileReads: nil,
            fileRoots: nil,
            serverURL: nil,
            serverURLs: nil
        )
        let descriptors = RuntimeConfigurationCatalog.normalizedRuntimeExecutors(
            nil,
            config: config,
            defaultExecutor: "claude",
            inputs: RuntimeLegacySettingInputs(
                codexModel: "gpt-5.4",
                codexModelOptions: [],
                codexReasoningEffort: "high",
                codexReasoningEffortOptions: [],
                claudeModel: "claude-sonnet-4-5",
                claudeModelOptions: []
            ),
            defaults: RuntimeCatalogDefaults(
                codexReasoningEffortOptions: ["minimal", "low", "medium", "high", "xhigh"],
                codexModelOptions: ["gpt-5.4", "gpt-5.4-mini"],
                claudeModelOptions: ["claude-sonnet-4-5"]
            )
        )

        XCTAssertEqual(descriptors.map(\.id), ["codex", "claude", "local"])
        XCTAssertEqual(descriptors.first(where: { $0.id == "claude" })?.isDefault, true)
        XCTAssertEqual(descriptors.first(where: { $0.id == "codex" })?.settings?.map(\.id) ?? [], ["model", "reasoning_effort"])
        XCTAssertEqual(descriptors.first(where: { $0.id == "local" })?.internalOnly, true)
    }

    func testRuntimeConfigurationCatalogFiltersUnsupportedExecutorsAndKeepsDefaultVisible() {
        let descriptors = RuntimeConfigurationCatalog.normalizedRuntimeExecutors(
            [
                RuntimeExecutorDescriptor(
                    id: "codex",
                    title: "Codex",
                    kind: "agent",
                    available: true,
                    isDefault: false,
                    internalOnly: false,
                    model: "gpt-5.4",
                    settings: []
                ),
                RuntimeExecutorDescriptor(
                    id: "remote-agent",
                    title: "Remote",
                    kind: "agent",
                    available: true,
                    isDefault: false,
                    internalOnly: false,
                    model: "ignored",
                    settings: []
                ),
            ],
            config: RuntimeConfig(
                securityMode: "workspace-write",
                defaultExecutor: "codex",
                availableExecutors: ["codex", "remote-agent"],
                executors: nil,
                transcribeProvider: nil,
                transcribeReady: nil,
                codexModel: nil,
                codexModelOptions: nil,
                codexReasoningEffort: nil,
                codexReasoningEffortOptions: nil,
                claudeModel: nil,
                claudeModelOptions: nil,
                workdirRoot: nil,
                allowAbsoluteFileReads: nil,
                fileRoots: nil,
                serverURL: nil,
                serverURLs: nil
            ),
            defaultExecutor: "codex",
            inputs: RuntimeLegacySettingInputs(
                codexModel: "",
                codexModelOptions: [],
                codexReasoningEffort: "",
                codexReasoningEffortOptions: [],
                claudeModel: "",
                claudeModelOptions: []
            ),
            defaults: RuntimeCatalogDefaults(
                codexReasoningEffortOptions: ["medium", "high"],
                codexModelOptions: ["gpt-5.4"],
                claudeModelOptions: ["claude-sonnet-4-5"]
            )
        )
        let available = RuntimeConfigurationCatalog.normalizedAvailableExecutors(
            ["codex", "remote-agent", "codex"],
            descriptors: descriptors,
            defaultExecutor: "claude"
        )

        XCTAssertEqual(descriptors.map(\.id), ["codex", "local"])
        XCTAssertEqual(available, ["codex", "claude"])
    }

    @MainActor
    func testCodexRuntimeModelOptionsKeepBackendAndCustomValuesVisible() {
        let vm = VoiceAgentViewModel()
        vm.backendExecutorDescriptors = [
            RuntimeExecutorDescriptor(
                id: "codex",
                title: "Codex",
                kind: "agent",
                available: true,
                isDefault: true,
                internalOnly: false,
                model: "gpt-5.1",
                settings: [
                    RuntimeSettingDescriptor(
                        id: "model",
                        title: "Model",
                        kind: "enum",
                        allowCustom: true,
                        value: "gpt-5.1",
                        options: ["gpt-5.4", "gpt-5.4-mini"]
                    )
                ]
            )
        ]
        vm.codexModelOverride = "gpt-5.2-custom"

        XCTAssertEqual(vm.codexRuntimeModelOptions, ["gpt-5.1", "gpt-5.2-custom", "gpt-5.4", "gpt-5.4-mini"])
        XCTAssertEqual(vm.codexBackendDefaultOptionLabel, "Backend default (gpt-5.1)")
        XCTAssertTrue(vm.runtimeSettingAllowsCustom("model", executor: "codex"))
    }

    func testSessionContextDecodingSupportsResolvedDefaults() throws {
        let json = """
        {
          "session_id":"iphone-app",
          "executor":"codex",
          "working_directory":"/Users/test/work/project",
          "runtime_settings":[
            {"executor":"codex","id":"model","value":"gpt-5.4-mini"},
            {"executor":"codex","id":"reasoning_effort","value":"high"},
            {"executor":"claude","id":"model","value":null}
          ],
          "resolved_working_directory":"/Users/test/work/project",
          "updated_at":"2026-03-26T18:00:00Z"
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SessionContext.self, from: data)
        XCTAssertEqual(decoded.sessionId, "iphone-app")
        XCTAssertEqual(decoded.executor, "codex")
        XCTAssertEqual(decoded.workingDirectory, "/Users/test/work/project")
        XCTAssertEqual(decoded.runtimeSettings?.count, 3)
        XCTAssertEqual(decoded.runtimeSettings?.first?.settingID, "model")
        XCTAssertEqual(decoded.runtimeSettings?.first?.value, "gpt-5.4-mini")
        XCTAssertEqual(decoded.resolvedWorkingDirectory, "/Users/test/work/project")
    }

    @MainActor
    func testRuntimeSessionContextUpdateRequestIncludesGenericRuntimeSettings() {
        let vm = VoiceAgentViewModel()
        vm.backendExecutorDescriptors = [
            RuntimeExecutorDescriptor(
                id: "codex",
                title: "Codex",
                kind: "agent",
                available: true,
                isDefault: true,
                internalOnly: false,
                model: "gpt-5.4",
                settings: [
                    RuntimeSettingDescriptor(
                        id: "model",
                        title: "Model",
                        kind: "enum",
                        allowCustom: true,
                        value: "gpt-5.4",
                        options: ["gpt-5.4", "gpt-5.4-mini"]
                    ),
                    RuntimeSettingDescriptor(
                        id: "reasoning_effort",
                        title: "Reasoning Effort",
                        kind: "enum",
                        allowCustom: false,
                        value: "medium",
                        options: ["medium", "high"]
                    ),
                    RuntimeSettingDescriptor(
                        id: "approval_mode",
                        title: "Approval Mode",
                        kind: "enum",
                        allowCustom: false,
                        value: "balanced",
                        options: ["balanced", "strict"]
                    ),
                ]
            ),
            RuntimeExecutorDescriptor(
                id: "claude",
                title: "Claude",
                kind: "agent",
                available: true,
                isDefault: false,
                internalOnly: false,
                model: "claude-sonnet-4-5",
                settings: [
                    RuntimeSettingDescriptor(
                        id: "model",
                        title: "Model",
                        kind: "enum",
                        allowCustom: true,
                        value: "claude-sonnet-4-5",
                        options: ["claude-sonnet-4-5", "claude-opus-4"]
                    )
                ]
            ),
        ]
        vm.backendDefaultExecutor = "codex"
        vm.executor = "codex"
        vm.codexModelOverride = "gpt-5.4-mini"
        vm.codexReasoningEffort = ""
        vm.claudeModelOverride = "claude-opus-4"
        vm.setRuntimeSettingValue("strict", for: "approval_mode", executor: "codex")

        let request = vm.runtimeSessionContextUpdateRequest()
        let runtimeSettings = Dictionary(
            uniqueKeysWithValues: (request.runtimeSettings ?? []).map { ("\($0.executor).\($0.settingID)", $0.value) }
        )

        XCTAssertEqual(runtimeSettings.count, 4)
        XCTAssertEqual(runtimeSettings["codex.model"]!, "gpt-5.4-mini")
        XCTAssertNil(runtimeSettings["codex.reasoning_effort"]!)
        XCTAssertEqual(runtimeSettings["codex.approval_mode"]!, "strict")
        XCTAssertEqual(runtimeSettings["claude.model"]!, "claude-opus-4")
    }

    func testSessionContextUpdateRequestEncodesExplicitNullClears() throws {
        let request = SessionContextUpdateRequest(
            executor: nil,
            workingDirectory: nil,
            runtimeSettings: [
                SessionRuntimeSetting(executor: "codex", settingID: "model", value: nil)
            ],
            codexModel: nil,
            codexReasoningEffort: nil,
            claudeModel: nil
        )

        let data = try JSONEncoder().encode(request)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runtimeSettings = try XCTUnwrap(payload["runtime_settings"] as? [[String: Any]])
        let firstSetting = try XCTUnwrap(runtimeSettings.first)

        XCTAssertTrue(payload.keys.contains("executor"))
        XCTAssertTrue(payload.keys.contains("working_directory"))
        XCTAssertTrue(payload.keys.contains("codex_model"))
        XCTAssertTrue(payload.keys.contains("codex_reasoning_effort"))
        XCTAssertTrue(payload.keys.contains("claude_model"))
        XCTAssertEqual(firstSetting["executor"] as? String, "codex")
        XCTAssertEqual(firstSetting["id"] as? String, "model")
        XCTAssertTrue(firstSetting.keys.contains("value"))
        XCTAssertTrue(firstSetting["value"] is NSNull)
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

    func testPairExchangeResponseDecodingIncludesConnectionCandidates() throws {
        let json = """
        {
          "api_token":"paired-token",
          "refresh_token":"refresh-token",
          "session_id":"iphone-app",
          "security_mode":"safe",
          "server_url":"https://relay.example.com",
          "server_urls":["https://relay.example.com","http://100.111.99.51:8000"]
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(PairExchangeResponse.self, from: data)
        XCTAssertEqual(decoded.apiToken, "paired-token")
        XCTAssertEqual(decoded.refreshToken, "refresh-token")
        XCTAssertEqual(decoded.serverURL, "https://relay.example.com")
        XCTAssertEqual(decoded.serverURLs ?? [], ["https://relay.example.com", "http://100.111.99.51:8000"])
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
    func testComposeVoiceUtteranceTextKeepsTypedNoteAheadOfTranscript() {
        let vm = VoiceAgentViewModel()

        let combined = vm._test_composeVoiceUtteranceText(
            draftText: "Run the smoke test again.",
            transcriptText: "Compare it with the last pass too."
        )

        XCTAssertEqual(
            combined,
            "Run the smoke test again.\n\nCompare it with the last pass too."
        )
    }

    @MainActor
    func testComposeVoiceUtteranceTextFallsBackToTranscriptWhenNoTypedNoteExists() {
        let vm = VoiceAgentViewModel()

        let combined = vm._test_composeVoiceUtteranceText(
            draftText: "   ",
            transcriptText: "Summarize the current repo status."
        )

        XCTAssertEqual(combined, "Summarize the current repo status.")
    }

    @MainActor
    func testVoiceModeUsesAutoSendEvenWhenManualModeIsConfigured() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        guard let threadID = vm.activeThreadID else {
            XCTFail("Expected an active thread")
            return
        }

        vm.autoSendAfterSilenceEnabled = false
        vm._test_setVoiceModeEnabled(true, threadID: threadID)

        XCTAssertTrue(vm._test_usesAutoSendForCurrentTurn())
    }

    @MainActor
    func testVoiceModeUsesMoreEagerSilenceProfileThanManualAutoSend() throws {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        guard let threadID = vm.activeThreadID else {
            XCTFail("Expected an active thread")
            return
        }

        vm.autoSendAfterSilenceEnabled = true
        vm.autoSendAfterSilenceSeconds = "1.8"
        let manualConfig = try XCTUnwrap(vm._test_activeSilenceConfig())

        vm._test_setVoiceModeEnabled(true, threadID: threadID)
        let voiceModeConfig = try XCTUnwrap(vm._test_activeSilenceConfig())

        XCTAssertEqual(Double(manualConfig.thresholdDB), -42, accuracy: 0.001)
        XCTAssertEqual(manualConfig.requiredSilenceDuration, 1.8, accuracy: 0.001)
        XCTAssertEqual(manualConfig.minimumRecordDuration, 0.7, accuracy: 0.001)

        XCTAssertEqual(Double(voiceModeConfig.thresholdDB), -39, accuracy: 0.001)
        XCTAssertEqual(voiceModeConfig.requiredSilenceDuration, 1.0, accuracy: 0.001)
        XCTAssertEqual(voiceModeConfig.minimumRecordDuration, 0.6, accuracy: 0.001)
    }

    @MainActor
    func testSwitchingThreadsDisablesVoiceModeLoop() {
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

        vm.switchToThread(firstThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
        vm.switchToThread(secondThreadID)

        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertFalse(vm.isVoiceModeActiveForCurrentThread)
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
    func testResolvedSpokenReplyTextUsesFinalAssistantMessageForVoiceRun() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        guard let threadID = vm.activeThreadID else {
            XCTFail("Expected an active thread")
            return
        }

        let runID = "voice-run-\(UUID().uuidString)"
        vm.speakRepliesEnabled = true
        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Running...",
            activeRunExecutor: "codex",
            lastSubmittedInputOrigin: .voice
        )
        vm._test_bindObservedRun(runID: runID, threadID: threadID)
        vm._test_ingestRunEvents(
            [
                ExecutionEvent(
                    type: "assistant.message",
                    actionIndex: nil,
                    message: "Here is the detailed answer.",
                    eventID: "evt-\(UUID().uuidString)",
                    createdAt: nil
                )
            ],
            runID: runID,
            threadID: threadID
        )

        XCTAssertEqual(
            vm._test_resolvedSpokenReplyText(
                runID: runID,
                threadID: threadID,
                summary: "Short summary",
                status: "completed"
            ),
            "Here is the detailed answer."
        )
    }

    @MainActor
    func testResolvedSpokenReplyTextFallsBackToSummaryForVoiceRunWithoutAssistantBubble() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        guard let threadID = vm.activeThreadID else {
            XCTFail("Expected an active thread")
            return
        }

        let runID = "voice-summary-\(UUID().uuidString)"
        vm.speakRepliesEnabled = true
        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Running...",
            activeRunExecutor: "codex",
            lastSubmittedInputOrigin: .voice
        )
        vm._test_bindObservedRun(runID: runID, threadID: threadID)

        XCTAssertEqual(
            vm._test_resolvedSpokenReplyText(
                runID: runID,
                threadID: threadID,
                summary: "Fallback spoken summary",
                status: "completed"
            ),
            "Fallback spoken summary"
        )
    }

    @MainActor
    func testResolvedSpokenReplyTextStaysSilentForTypedRuns() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        guard let threadID = vm.activeThreadID else {
            XCTFail("Expected an active thread")
            return
        }

        let runID = "typed-run-\(UUID().uuidString)"
        vm.speakRepliesEnabled = true
        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Running...",
            activeRunExecutor: "codex",
            lastSubmittedInputOrigin: .text
        )
        vm._test_bindObservedRun(runID: runID, threadID: threadID)
        vm._test_ingestRunEvents(
            [
                ExecutionEvent(
                    type: "assistant.message",
                    actionIndex: nil,
                    message: "Typed reply should stay silent.",
                    eventID: "evt-\(UUID().uuidString)",
                    createdAt: nil
                )
            ],
            runID: runID,
            threadID: threadID
        )

        XCTAssertNil(
            vm._test_resolvedSpokenReplyText(
                runID: runID,
                threadID: threadID,
                summary: "Typed summary",
                status: "completed"
            )
        )
    }

    @MainActor
    func testSpokenTextForPlaybackCleansMarkdownAndCodeNoise() {
        let vm = VoiceAgentViewModel()

        let spoken = vm._test_spokenTextForPlayback(
            """
            ## Result
            I updated [the docs](https://example.com/docs) and verified the fix.

            ```swift
            print("hello")
            ```
            """
        )

        XCTAssertEqual(spoken, "Result I updated the docs and verified the fix. Code omitted.")
    }

    @MainActor
    func testSpokenTextForPlaybackTruncatesLongRepliesAtNaturalBoundary() {
        let vm = VoiceAgentViewModel()

        let spoken = vm._test_spokenTextForPlayback(
            """
            First sentence explains the result clearly. Second sentence adds a bit more context for the voice summary. Third sentence still matters for someone listening hands-free. Fourth sentence should stay on screen instead of being read in full.
            """
        )

        XCTAssertEqual(
            spoken,
            "First sentence explains the result clearly. Second sentence adds a bit more context for the voice summary. Third sentence still matters for someone listening hands-free. There's more on screen."
        )
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

    func testAppAppearancePreferenceResolvesKnownValuesAndFallsBackToSystem() {
        XCTAssertEqual(AppAppearancePreference.resolve(from: nil), .system)
        XCTAssertEqual(AppAppearancePreference.resolve(from: ""), .system)
        XCTAssertEqual(AppAppearancePreference.resolve(from: "dark"), .dark)
        XCTAssertEqual(AppAppearancePreference.resolve(from: "LIGHT"), .light)
        XCTAssertEqual(AppAppearancePreference.resolve(from: "unknown"), .system)
    }

    func testAppAppearancePreferenceMapsToExpectedColorScheme() {
        XCTAssertNil(AppAppearancePreference.system.colorScheme)
        XCTAssertEqual(AppAppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppAppearancePreference.dark.colorScheme, .dark)
    }
}

private extension VoiceAgentModelTests {
    func makeIsolatedPersistenceHarness() -> (
        store: ChatThreadStore,
        defaults: UserDefaults,
        draftDirectory: URL,
        cleanup: () -> Void
    ) {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ChatThreadStore(dbURL: baseURL.appendingPathComponent("threads.sqlite3"))
        let draftDirectory = baseURL.appendingPathComponent("draft-attachments", isDirectory: true)
        let suiteName = "VoiceAgentModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }

        return (store, defaults, draftDirectory, cleanup)
    }
}
