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
    func testApplyPairingPayloadStagesPendingPairingFromJSONScannerText() {
        let vm = VoiceAgentViewModel()

        let didStage = vm.applyPairingPayload(
            #"{"server_url":"http://127.0.0.1:8000","server_urls":["http://127.0.0.1:8000","http://100.111.99.51:8000"],"pair_code":"abc123","session_id":"iphone-app"}"#
        )

        XCTAssertTrue(didStage)
        XCTAssertEqual(vm.pendingPairing?.serverURL, "http://100.111.99.51:8000")
        XCTAssertEqual(vm.pendingPairing?.serverURLs ?? [], [
            "http://100.111.99.51:8000",
            "http://127.0.0.1:8000",
        ])
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
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
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
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )

        let message = vm.registerConnectionRepairIfNeeded(
            from: APIError.httpError(503, #"{"detail":"server auth token is not configured"}"#)
        )

        XCTAssertNil(message)
        XCTAssertFalse(vm.needsConnectionRepair)
    }

    func testAPIErrorParsesStructuredBackendDetail() {
        let error = APIError.httpError(
            413,
            #"{"detail":{"code":"audio_too_large","message":"audio payload too large","field":"audio"}}"#
        )

        XCTAssertEqual(error.backendCode, "audio_too_large")
        XCTAssertEqual(error.backendDetail, "Audio payload too large")
        XCTAssertEqual(error.localizedDescription, "Audio payload too large")
    }

    func testCandidateFallbackPreservesReachableBackendErrors() {
        let client = APIClient()

        XCTAssertFalse(client._test_shouldRetryAcrossCandidates(
            APIError.httpError(
                502,
                #"{"detail":{"code":"transcription_failed","message":"OPENAI_API_KEY is not set"}}"#
            )
        ))
        XCTAssertTrue(client._test_shouldRetryAcrossCandidates(APIError.httpError(404, "")))
        XCTAssertTrue(client._test_shouldRetryAcrossCandidates(URLError(.cannotConnectToHost)))
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
            "http://127.0.0.1:8000",
        ])
        XCTAssertTrue(vm.hasPairedRefreshCredential)
        XCTAssertFalse(vm.needsConnectionRepair)
    }

    @MainActor
    func testBackendProfilesRememberMultiplePairingsAndSwitchCredentials() throws {
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )
        var profileIDsToCleanUp: [UUID] = []
        defer {
            for id in profileIDsToCleanUp {
                KeychainStore.delete(service: "MOBaiLE", account: "api_token.\(id.uuidString)")
                KeychainStore.delete(service: "MOBaiLE", account: "refresh_token.\(id.uuidString)")
            }
        }

        vm.applyPairedClientCredentials(
            PairExchangeResponse(
                apiToken: "mac-mini-token",
                refreshToken: "mac-mini-refresh",
                sessionId: "iphone-app",
                securityMode: "full-access",
                serverURL: "http://mac-mini.tail6a5903.ts.net:8000",
                serverURLs: ["http://mac-mini.tail6a5903.ts.net:8000"]
            ),
            fallbackPrimaryServerURL: "http://mac-mini.tail6a5903.ts.net:8000"
        )
        let firstProfileID = try XCTUnwrap(vm.activeBackendProfileID)
        profileIDsToCleanUp.append(firstProfileID)

        vm.applyPairedClientCredentials(
            PairExchangeResponse(
                apiToken: "macbook-token",
                refreshToken: "macbook-refresh",
                sessionId: "iphone-app",
                securityMode: "safe",
                serverURL: "http://macbook.tail6a5903.ts.net:8000",
                serverURLs: ["http://macbook.tail6a5903.ts.net:8000"]
            ),
            fallbackPrimaryServerURL: "http://macbook.tail6a5903.ts.net:8000"
        )
        let secondProfileID = try XCTUnwrap(vm.activeBackendProfileID)
        profileIDsToCleanUp.append(secondProfileID)

        XCTAssertNotEqual(firstProfileID, secondProfileID)
        XCTAssertEqual(vm.backendProfiles.count, 2)
        XCTAssertEqual(vm.apiToken, "macbook-token")

        vm.switchBackendProfile(firstProfileID)

        XCTAssertEqual(vm.serverURL, "http://mac-mini.tail6a5903.ts.net:8000")
        XCTAssertEqual(vm.apiToken, "mac-mini-token")
        XCTAssertEqual(vm.activeBackendProfileID, firstProfileID)
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

    func testDirectoryBrowserBuildsBreadcrumbsForAbsolutePath() {
        let breadcrumbs = VoiceAgentDirectoryBrowser.breadcrumbs(for: "/Users/demo/project")

        XCTAssertEqual(
            breadcrumbs.map(\.path),
            ["/", "/Users", "/Users/demo", "/Users/demo/project"]
        )
        XCTAssertEqual(
            breadcrumbs.map(\.title),
            ["/", "Users", "demo", "project"]
        )
    }

    func testDirectoryBrowserFiltersHiddenDirectoriesButKeepsFilesVisible() {
        let entries = [
            DirectoryEntry(name: ".git", path: "/repo/.git", isDirectory: true),
            DirectoryEntry(name: ".env", path: "/repo/.env", isDirectory: false),
            DirectoryEntry(name: "Sources", path: "/repo/Sources", isDirectory: true),
        ]

        let filtered = VoiceAgentDirectoryBrowser.filteredEntries(entries, hideDotFolders: true)

        XCTAssertEqual(filtered.map(\.name), [".env", "Sources"])
        XCTAssertEqual(VoiceAgentDirectoryBrowser.hiddenDotFolderCount(in: entries), 1)
        XCTAssertTrue(VoiceAgentDirectoryBrowser.canNavigateUp(from: "/repo"))
        XCTAssertFalse(VoiceAgentDirectoryBrowser.canNavigateUp(from: "/"))
    }

    @MainActor
    func testBackgroundDirectoryRefreshPreservesVisibleListingWithoutCredentials() async {
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )
        let entries = [
            DirectoryEntry(name: "Sources", path: "/repo/Sources", isDirectory: true),
            DirectoryEntry(name: "README.md", path: "/repo/README.md", isDirectory: false),
        ]
        vm.serverURL = ""
        vm.apiToken = ""
        vm.directoryBrowserPath = "/repo"
        vm.directoryBrowserEntries = entries
        vm.directoryBrowserTruncated = true

        await vm.refreshDirectoryBrowser(presentation: .background)

        XCTAssertFalse(vm.isLoadingDirectoryBrowser)
        XCTAssertEqual(vm.directoryBrowserPath, "/repo")
        XCTAssertEqual(vm.directoryBrowserEntries.map(\.path), entries.map(\.path))
        XCTAssertTrue(vm.directoryBrowserTruncated)
        XCTAssertEqual(vm.directoryBrowserError, "")
    }

    func testDirectoryEntryDecodesPreviewMetadata() throws {
        let json = #"{"name":"README.md","path":"/repo/README.md","is_directory":false,"size_bytes":42,"mime":"text/markdown","modified_at":"2026-04-28T20:10:00Z"}"#

        let entry = try JSONDecoder().decode(DirectoryEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.name, "README.md")
        XCTAssertEqual(entry.sizeBytes, 42)
        XCTAssertEqual(entry.mime, "text/markdown")
        XCTAssertEqual(entry.modifiedAt, "2026-04-28T20:10:00Z")
        XCTAssertEqual(entry.previewCacheVersion, "2026-04-28T20:10:00Z:42")
        XCTAssertEqual(VoiceAgentDirectoryBrowser.artifactType(for: entry), "code")
    }

    func testAttachmentKindClassifiesInspectableTextFormatsAsCode() {
        let fileNames = [
            "report.csv",
            "table.tsv",
            "server.log",
            "events.jsonl",
            "events.ndjson",
            "README.markdown",
            "CHANGELOG.mdown",
            "notes.mkd",
        ]

        for fileName in fileNames {
            XCTAssertEqual(
                inferAttachmentKind(fileName: fileName, mimeType: "application/octet-stream"),
                .code,
                fileName
            )
        }
    }

    func testAttachmentKindClassifiesCommonPreviewImagesAsImage() {
        let fileNames = [
            "diagram.svg",
            "photo.heic",
            "photo.heif",
        ]

        for fileName in fileNames {
            XCTAssertEqual(
                inferAttachmentKind(fileName: fileName, mimeType: "application/octet-stream"),
                .image,
                fileName
            )
        }
    }

    func testDirectoryBrowserArtifactTypeUsesExtensionWhenMimeIsGeneric() {
        let entries = [
            DirectoryEntry(name: "events.jsonl", path: "/repo/events.jsonl", isDirectory: false, mime: "application/octet-stream"),
            DirectoryEntry(name: "diagram.svg", path: "/repo/diagram.svg", isDirectory: false, mime: "application/octet-stream"),
            DirectoryEntry(name: "brief.pdf", path: "/repo/brief.pdf", isDirectory: false, mime: "application/octet-stream"),
        ]

        XCTAssertEqual(entries.map { VoiceAgentDirectoryBrowser.artifactType(for: $0) }, [
            "code",
            "image",
            "file",
        ])
    }

    func testAttachmentMimeTypeFallsBackByExtensionAndTrimsProvidedMime() {
        XCTAssertEqual(inferAttachmentMimeType(fileName: "events.ndjson"), "application/x-ndjson")
        XCTAssertEqual(inferAttachmentMimeType(fileName: "table.tsv"), "text/tab-separated-values")
        XCTAssertEqual(inferAttachmentMimeType(fileName: "brief.pdf"), "application/pdf")
        XCTAssertEqual(inferAttachmentMimeType(fileName: "photo.heif"), "image/heif")
        XCTAssertEqual(inferAttachmentMimeType(fileName: "unknown.nope"), "application/octet-stream")
        XCTAssertEqual(inferAttachmentMimeType(fileName: "server.log", fallback: "  text/plain  "), "text/plain")
        XCTAssertEqual(inferAttachmentMimeType(fileName: "notes.markdown", fallback: " "), "text/markdown")
    }

    func testFileInspectionResponseDecodesPreviewMetadata() throws {
        let json = """
        {
          "name":"plot.png",
          "path":"/repo/plot.png",
          "size_bytes":128,
          "mime":"image/png",
          "artifact_type":"image",
          "modified_at":"2026-04-28T20:11:00Z",
          "text_preview":null,
          "text_preview_bytes":0,
          "text_preview_offset":32,
          "text_preview_next_offset":96,
          "text_preview_truncated":false,
          "preview_blocked_reason":null,
          "text_search_query":"needle",
          "text_search_match_count":1,
          "text_search_matches":[
            {"line_number":4,"line_text":"needle match"}
          ],
          "image_width":640,
          "image_height":360
        }
        """

        let inspected = try JSONDecoder().decode(FileInspectionResponse.self, from: Data(json.utf8))

        XCTAssertEqual(inspected.name, "plot.png")
        XCTAssertEqual(inspected.sizeBytes, 128)
        XCTAssertEqual(inspected.artifactType, "image")
        XCTAssertEqual(inspected.modifiedAt, "2026-04-28T20:11:00Z")
        XCTAssertEqual(inspected.previewCacheVersion, "2026-04-28T20:11:00Z:128")
        XCTAssertEqual(inspected.imageWidth, 640)
        XCTAssertEqual(inspected.imageHeight, 360)
        XCTAssertEqual(inspected.textPreviewOffset, 32)
        XCTAssertEqual(inspected.textPreviewNextOffset, 96)
        XCTAssertEqual(inspected.textSearchQuery, "needle")
        XCTAssertEqual(inspected.textSearchMatchCount, 1)
        XCTAssertEqual(inspected.textSearchMatches, [
            TextSearchMatch(lineNumber: 4, lineText: "needle match")
        ])
    }

    func testFileInspectionResponseToleratesMissingModifiedAt() throws {
        let json = """
        {
          "name":"notes.txt",
          "path":"/repo/notes.txt",
          "size_bytes":12,
          "mime":"text/plain",
          "artifact_type":"code",
          "text_preview":"hello",
          "text_preview_bytes":5,
          "text_preview_truncated":false,
          "image_width":null,
          "image_height":null
        }
        """

        let inspected = try JSONDecoder().decode(FileInspectionResponse.self, from: Data(json.utf8))

        XCTAssertNil(inspected.modifiedAt)
        XCTAssertEqual(inspected.previewCacheVersion, "size:12")
        XCTAssertEqual(inspected.textPreview, "hello")
    }

    func testTextPreviewHelpersNumberLinesAndCountMatches() {
        let text = "alpha\nbeta\nalpha"

        XCTAssertEqual(_test_numberedPreviewText(text), "1  alpha\n2  beta\n3  alpha")
        XCTAssertEqual(_test_textPreviewMatchCount(text, query: "alpha"), 2)
        XCTAssertEqual(_test_textPreviewMatchedSnippets("Alpha\nbeta\nalpha", query: "alpha"), ["Alpha", "alpha"])
        let lineMatches = _test_textPreviewLineMatches("first\nneedle one\nsecond\nneedle two", query: "needle")
        XCTAssertEqual(lineMatches.map { $0.0 }, [2, 4])
        XCTAssertEqual(lineMatches.map { $0.1 }, ["needle one", "needle two"])
        XCTAssertEqual(_test_textPreviewMatchCount(_test_numberedPreviewText(text), query: "1"), 1)
        XCTAssertEqual(_test_textPreviewMatchCount(text, query: "missing"), 0)
    }

    func testFilePreviewLanguageInfersCommonInspectableFormats() {
        XCTAssertEqual(FilePreviewLanguage.infer(fileName: "script.py", mime: nil), "python")
        XCTAssertEqual(FilePreviewLanguage.infer(fileName: "events.jsonl", mime: "application/octet-stream"), "json")
        XCTAssertEqual(FilePreviewLanguage.infer(fileName: "diagram.svg", mime: nil), "xml")
        XCTAssertEqual(FilePreviewLanguage.infer(fileName: "table.tsv", mime: nil), "csv")
        XCTAssertEqual(FilePreviewLanguage.infer(fileName: "notes.unknown", mime: "text/plain"), "text")
    }

    func testTextPreviewDisplayModeDefaultsToStructuredFormats() {
        XCTAssertEqual(
            TextPreviewDisplayMode.defaultMode(fileName: "README.md", language: "markdown"),
            .renderedMarkdown
        )
        XCTAssertEqual(
            TextPreviewDisplayMode.defaultMode(fileName: "events.jsonl", language: "json"),
            .outline
        )
        XCTAssertEqual(
            TextPreviewDisplayMode.defaultMode(fileName: "table.tsv", language: "csv"),
            .table
        )
        XCTAssertEqual(
            TextPreviewDisplayMode.availableModes(fileName: "script.py", language: "python"),
            [.raw]
        )
    }

    func testDelimitedTextParserHandlesQuotedCommasAndLimitsColumns() {
        let table = DelimitedTextParser.parse(
            "name,count,notes\n\"alpha,beta\",2,\"keeps \"\"quotes\"\"\"\nomega,3,plain\n",
            delimiter: ",",
            maxRows: 10,
            maxColumns: 2
        )

        XCTAssertEqual(table.headers, ["name", "count"])
        XCTAssertEqual(table.rows.first, ["alpha,beta", "2"])
        XCTAssertEqual(table.rows.last, ["omega", "3"])
        XCTAssertEqual(table.totalRowCount, 2)
        XCTAssertEqual(table.totalColumnCount, 3)
        XCTAssertFalse(table.truncatedRows)
        XCTAssertTrue(table.truncatedColumns)
    }

    func testDelimitedTextParserHandlesTSVRows() {
        let table = DelimitedTextParser.parse(
            "name\tvalue\nalpha\t1\nbeta\t2\n",
            delimiter: "\t"
        )

        XCTAssertEqual(table.headers, ["name", "value"])
        XCTAssertEqual(table.rows, [["alpha", "1"], ["beta", "2"]])
        XCTAssertEqual(DelimitedTextParser.delimiter(forFileName: "table.tsv"), "\t")
    }

    func testDelimitedTextParserLimitsLargeTablesAndSizesVisibleColumns() {
        let body = (0..<120)
            .map { "row-\($0),\($0),\(String(repeating: "x", count: 48))" }
            .joined(separator: "\n")
        let table = DelimitedTextParser.parse(
            "name,count,description\n\(body)\n",
            delimiter: ",",
            maxRows: 5,
            maxColumns: 2
        )

        XCTAssertEqual(table.headers, ["name", "count"])
        XCTAssertEqual(table.rows.count, 5)
        XCTAssertEqual(table.totalRowCount, 120)
        XCTAssertEqual(table.totalColumnCount, 3)
        XCTAssertTrue(table.truncatedRows)
        XCTAssertTrue(table.truncatedColumns)
        XCTAssertEqual(table.columnWidths.count, 2)
        XCTAssertGreaterThanOrEqual(table.columnWidths[0], 108)
        XCTAssertGreaterThanOrEqual(table.columnWidths[1], 108)
    }

    func testJSONPreviewParserBuildsOutlineForObjectsAndJSONLines() throws {
        let root = try XCTUnwrap(JSONPreviewParser.parse(#"{"name":"demo","items":[1,true,null]}"#))
        let rows = JSONPreviewParser.flattenedRows(from: root)

        XCTAssertTrue(rows.contains { $0.key == "name" && $0.value == "demo" })
        XCTAssertTrue(rows.contains { $0.key == "items" && $0.value == "3 items" })
        XCTAssertTrue(rows.contains { $0.key == "[0]" && $0.value == "1" })
        XCTAssertTrue(rows.contains { $0.key == "[1]" && $0.value == "true" })
        XCTAssertTrue(rows.contains { $0.key == "[2]" && $0.value == "null" })

        let linesRoot = try XCTUnwrap(JSONPreviewParser.parse("{\"event\":\"start\"}\n{\"event\":\"stop\"}"))
        let lineRows = JSONPreviewParser.flattenedRows(from: linesRoot)
        XCTAssertTrue(lineRows.contains { $0.key == "JSON Lines" && $0.value == "2 items" })
        XCTAssertTrue(lineRows.contains { $0.key == "event" && $0.value == "stop" })
    }

    func testJSONPreviewParserHonorsFlattenedRowLimit() throws {
        let root = try XCTUnwrap(JSONPreviewParser.parse(#"{"items":[0,1,2,3,4,5,6,7,8,9]}"#))
        let rows = JSONPreviewParser.flattenedRows(from: root, maxRows: 4)

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.key), ["Root", "items", "[0]", "[1]"])
    }

    func testMarkdownPreviewRendererPreservesBlocksAndRemovesInlineMarkup() {
        let rendered = MarkdownPreviewRenderer.renderedText(
            """
            # Preview Notes

            Open **files** from [the phone](https://example.com).
            """
        )

        XCTAssertEqual(
            rendered,
            """
            Preview Notes

            Open files from the phone.
            """
        )
    }

    func testFilePreviewMetadataAndUnsupportedMessagesIncludeUsefulDetails() {
        XCTAssertEqual(
            FileMetadataFormatter.previewMetadataText(
                sizeBytes: 128,
                modifiedAt: nil,
                imageWidth: 640,
                imageHeight: 360,
                mime: "image/png"
            ),
            "128 bytes · 640x360 · image/png"
        )
        XCTAssertTrue(
            FilePreviewUnsupportedMessage.message(
                fileName: "archive.zip",
                mime: "application/zip",
                sizeBytes: 42
            ).contains("archive")
        )
        XCTAssertTrue(FilePreviewUnsupportedMessage.prefersInlineUnsupportedMessage(
            fileName: "blob.bin",
            mime: "application/octet-stream"
        ))
        XCTAssertFalse(FilePreviewUnsupportedMessage.prefersInlineUnsupportedMessage(
            fileName: "brief.pdf",
            mime: "application/octet-stream"
        ))
    }

    func testFilePreviewOpenErrorsUseActionableMessages() {
        XCTAssertTrue(
            FilePreviewOpenErrorMessage.message(
                APIError.httpError(403, #"{"detail":"outside allowed roots"}"#),
                fileName: "secret.txt"
            ).contains("safe mode")
        )
        XCTAssertTrue(
            FilePreviewOpenErrorMessage.message(
                CocoaError(.fileReadNoPermission),
                fileName: "private.txt"
            ).contains("permission")
        )
        XCTAssertTrue(
            FilePreviewOpenErrorMessage.message(
                CocoaError(.fileReadCorruptFile),
                fileName: "broken.pdf"
            ).contains("damaged")
        )
    }

    func testTextPreviewLoaderRejectsHugeLocalFilesWithoutReadingThemIntoPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 2 * 1024 * 1024 + 1)
        try handle.close()

        do {
            _ = try await TextPreviewLoader.loadText(from: url)
            XCTFail("Expected large text preview loading to fail")
        } catch TextPreviewError.tooLarge {
            // Expected.
        } catch {
            XCTFail("Expected tooLarge, got \(error)")
        }
    }

    func testLocalFileInspectionSupportsPreviewPaginationAndSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("server.log")
        try "alpha\nneedle one\nbeta\nneedle two\n".write(to: url, atomically: true, encoding: .utf8)

        let firstPage = try await LocalFileInspection.inspect(
            url: url,
            name: "server.log",
            mime: nil,
            textPreviewBytes: 6,
            textSearch: "needle"
        )

        XCTAssertEqual(firstPage.textPreview, "alpha\n")
        XCTAssertEqual(firstPage.textPreviewOffset, 0)
        XCTAssertEqual(firstPage.textPreviewNextOffset, 6)
        XCTAssertTrue(firstPage.textPreviewTruncated)
        XCTAssertEqual(firstPage.textSearchMatchCount, 2)
        XCTAssertEqual(firstPage.textSearchMatches.map(\.lineNumber), [2, 4])
        XCTAssertEqual(firstPage.textSearchMatches.first?.lineText, "needle one")

        let secondPage = try await LocalFileInspection.inspect(
            url: url,
            name: "server.log",
            mime: nil,
            textPreviewBytes: 6,
            textPreviewOffset: 6
        )

        XCTAssertEqual(secondPage.textPreviewOffset, 6)
        XCTAssertEqual(secondPage.textPreview, "needle")
    }

    func testLocalFileInspectionDoesNotSplitUTF8PreviewCharacters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("emoji.txt")
        try "hi \u{1F603} there".write(to: url, atomically: true, encoding: .utf8)

        let firstPage = try await LocalFileInspection.inspect(
            url: url,
            name: "emoji.txt",
            mime: nil,
            textPreviewBytes: 4
        )

        XCTAssertEqual(firstPage.textPreview, "hi ")
        XCTAssertEqual(firstPage.textPreviewBytes, 3)
        XCTAssertEqual(firstPage.textPreviewNextOffset, 3)

        let secondPage = try await LocalFileInspection.inspect(
            url: url,
            name: "emoji.txt",
            mime: nil,
            textPreviewBytes: 4,
            textPreviewOffset: 3
        )

        XCTAssertEqual(secondPage.textPreview, "\u{1F603}")
        XCTAssertEqual(secondPage.textPreviewBytes, 4)
        XCTAssertEqual(secondPage.textPreviewNextOffset, 7)
    }

    func testLocalFileInspectionDecodesUTF16PreviewWithoutEmbeddedNuls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("utf16.txt")
        try XCTUnwrap("ABCD".data(using: .utf16LittleEndian)).write(to: url)

        let firstPage = try await LocalFileInspection.inspect(
            url: url,
            name: "utf16.txt",
            mime: "text/plain",
            textPreviewBytes: 5
        )

        XCTAssertEqual(firstPage.textPreview, "AB")
        XCTAssertEqual(firstPage.textPreviewBytes, 4)
        XCTAssertEqual(firstPage.textPreviewNextOffset, 4)

        let secondPage = try await LocalFileInspection.inspect(
            url: url,
            name: "utf16.txt",
            mime: "text/plain",
            textPreviewBytes: 4,
            textPreviewOffset: 4
        )

        XCTAssertEqual(secondPage.textPreview, "CD")
        XCTAssertEqual(secondPage.textPreviewBytes, 4)
        XCTAssertNil(secondPage.textPreviewNextOffset)
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

    func testRunEventsPageDecoding() throws {
        let json = """
        {
          "run_id":"run-123",
          "events":[
            {"seq":4,"type":"log.message","message":"event 4"},
            {"seq":5,"type":"run.completed","message":"done"}
          ],
          "limit":2,
          "total_count":6,
          "has_more_before":true,
          "has_more_after":false,
          "next_before_seq":4,
          "next_after_seq":5
        }
        """

        let decoded = try JSONDecoder().decode(RunEventsPage.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.runId, "run-123")
        XCTAssertEqual(decoded.events.map(\.seq), [4, 5])
        XCTAssertEqual(decoded.limit, 2)
        XCTAssertEqual(decoded.totalCount, 6)
        XCTAssertTrue(decoded.hasMoreBefore)
        XCTAssertFalse(decoded.hasMoreAfter)
        XCTAssertEqual(decoded.nextBeforeSeq, 4)
        XCTAssertEqual(decoded.nextAfterSeq, 5)
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
          "message_kind":"final",
          "summary":"Done",
          "sections":[{"title":"Result","body":"Created file"}],
          "agenda_items":[],
          "artifacts":[{"type":"file","title":"hello.py","path":"/Users/test/hello.py","mime":"text/x-python"}],
          "file_changes":[{"path":"/Users/test/hello.py","status":"created","summary":"Created hello.py","artifact":{"type":"file","title":"hello.py","path":"/Users/test/hello.py","mime":"text/x-python"}}],
          "commands_run":[{"command":"cd backend && uv run pytest tests/test_chat_envelope.py","status":"passed","summary":"pytest passed"}],
          "tests_run":[{"name":"tests/test_chat_envelope.py","status":"passed","summary":"passed"}],
          "warnings":[{"message":"Screenshot verification was skipped.","level":"warning"}],
          "next_actions":[{"title":"Preview hello.py","detail":"Open the changed file.","kind":"inspect_artifact","path":"/Users/test/hello.py","artifact":{"type":"file","title":"hello.py","path":"/Users/test/hello.py","mime":"text/x-python"}}]
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ChatEnvelope.self, from: data)
        XCTAssertEqual(decoded.summary, "Done")
        XCTAssertEqual(decoded.messageKind, "final")
        XCTAssertEqual(decoded.artifacts.count, 1)
        XCTAssertEqual(decoded.artifacts.first?.path, "/Users/test/hello.py")
        XCTAssertEqual(decoded.fileChanges.first?.status, "created")
        XCTAssertEqual(decoded.commandsRun.first?.status, "passed")
        XCTAssertEqual(decoded.testsRun.first?.name, "tests/test_chat_envelope.py")
        XCTAssertEqual(decoded.warnings.first?.level, "warning")
        XCTAssertEqual(decoded.nextActions.first?.kind, "inspect_artifact")
        XCTAssertEqual(decoded.nextActions.first?.path, "/Users/test/hello.py")
        XCTAssertEqual(decoded.nextActions.first?.artifact?.path, "/Users/test/hello.py")
    }

    func testChatEnvelopeTypedResultSegmentsRenderBeforeFallbackSections() {
        let envelope = """
        {
          "type":"assistant_response",
          "version":"1.0",
          "message_kind":"final",
          "summary":"Done",
          "sections":[
            {"title":"Changed Files","body":"- Updated `backend/app/chat_envelope.py`."},
            {"title":"Verification","body":"- `uv run pytest` passed."},
            {"title":"Result","body":"Phone surface is richer."}
          ],
          "agenda_items":[],
          "artifacts":[],
          "file_changes":[{"path":"backend/app/chat_envelope.py","status":"modified","summary":"Updated envelope metadata."}],
          "commands_run":[{"command":"uv run pytest","status":"passed","summary":"passed"}],
          "tests_run":[{"name":"uv run pytest","status":"passed","summary":"passed"}],
          "warnings":[{"message":"iOS screenshot was skipped.","level":"warning"}],
          "next_actions":[
            {"title":"Preview renderer","detail":"Inspect changed Swift file.","kind":"inspect_artifact","path":"ios/VoiceAgentApp/ChatRenderers.swift"},
            {"title":"Open Run Logs","detail":"Inspect raw output.","kind":"open_logs"}
          ]
        }
        """

        let kinds = _test_messageSegmentKindNames(envelope, serverURL: "http://127.0.0.1:8000")
        let fileURLs = _test_fileChangePreviewURLs(
            envelope,
            serverURL: "http://127.0.0.1:8000",
            workspacePath: "/Users/test/MOBaiLE"
        )
        let nextActionURLs = _test_nextActionPreviewURLs(
            envelope,
            serverURL: "http://127.0.0.1:8000",
            workspacePath: "/Users/test/MOBaiLE"
        )

        XCTAssertEqual(kinds, ["markdown", "warnings", "fileChanges", "verification", "section", "nextActions"])
        XCTAssertEqual(fileURLs.first, "http://127.0.0.1:8000/v1/files?path=/Users/test/MOBaiLE/backend/app/chat_envelope.py")
        XCTAssertEqual(nextActionURLs.first, "http://127.0.0.1:8000/v1/files?path=/Users/test/MOBaiLE/ios/VoiceAgentApp/ChatRenderers.swift")
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

    func testResolveImageURLUsesWorkspaceForRelativePath() {
        let resolved = _test_resolveImageURL(
            "plots/plot.png",
            serverURL: "http://127.0.0.1:8000",
            workspacePath: "/Users/test/project"
        )

        XCTAssertEqual(resolved, "http://127.0.0.1:8000/v1/files?path=/Users/test/project/plots/plot.png")
    }

    func testAssistantHeadingNormalizationKeepsOutputTitleSeparateFromBody() {
        let massaged = _test_massagedAssistantTextForDisplay("OutputHello from the script.")

        XCTAssertEqual(massaged, "## Output\n\nHello from the script.")
    }

    func testMessageSegmentsUseStableUniqueIdentities() {
        let text = """
        Result: Done

        ```swift
        print("hello")
        ```

        ```swift
        print("hello")
        ```
        """

        let firstIDs = _test_messageSegmentIDs(text, serverURL: "http://127.0.0.1:8000")
        let secondIDs = _test_messageSegmentIDs(text, serverURL: "http://127.0.0.1:8000")

        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertEqual(Set(firstIDs).count, firstIDs.count)
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

    func testPendingPairingIdentifiesTailscaleCellularPath() {
        let pending = VoiceAgentViewModel.PendingPairing(
            serverURL: "http://100.111.99.51:8000",
            serverURLs: [
                "http://100.111.99.51:8000",
                "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            ],
            sessionID: "iphone-app",
            pairCode: "123456",
            legacyToken: nil
        )

        XCTAssertTrue(pending.usesTailscalePath)
        XCTAssertTrue(pending.tailscaleNetworkNotice?.contains("5G") ?? false)
    }

    @MainActor
    func testFreshPairCodePairingTrustsServerByDefault() {
        let vm = VoiceAgentViewModel()
        let pending = VoiceAgentViewModel.PendingPairing(
            serverURL: "http://100.111.99.51:8000",
            serverURLs: ["http://100.111.99.51:8000"],
            sessionID: "iphone-app",
            pairCode: "123456",
            legacyToken: nil
        )

        XCTAssertTrue(vm.shouldTrustPendingPairingByDefault(pending))
    }

    @MainActor
    func testTrustingPendingPairingStoresAllAdvertisedHosts() {
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )
        let pending = VoiceAgentViewModel.PendingPairing(
            serverURL: "http://100.111.99.51:8000",
            serverURLs: [
                "http://100.111.99.51:8000",
                "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            ],
            sessionID: "iphone-app",
            pairCode: "123456",
            legacyToken: nil
        )

        vm.setTrustedPairHosts(from: pending, trusted: true)

        XCTAssertTrue(vm.isTrustedPairHost("100.111.99.51"))
        XCTAssertTrue(vm.isTrustedPairHost("vemunds-macbook-air.tail6a5903.ts.net"))
    }

    @MainActor
    func testPairingFailureMessageExplainsUnreachableTailscale() {
        let vm = VoiceAgentViewModel()

        let message = vm._test_pairingFailureMessage(
            for: URLError(.cannotConnectToHost),
            serverURLs: [
                "http://100.111.99.51:8000",
                "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            ]
        )

        XCTAssertTrue(message.contains("Tailscale"))
        XCTAssertTrue(message.contains("same tailnet"))
    }

    @MainActor
    func testPairingRouteMessageExplainsPairCodeWasNotSpent() {
        let vm = VoiceAgentViewModel()

        let message = vm._test_noReachablePairingRouteMessage(
            for: [
                "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
                "http://100.111.99.51:8000",
            ]
        )

        XCTAssertTrue(message.contains("Tailscale"))
        XCTAssertTrue(message.contains("same QR"))
    }

    @MainActor
    func testPairingFailureMessageExplainsUntrustedCertificate() {
        let vm = VoiceAgentViewModel()

        let message = vm._test_pairingFailureMessage(
            for: URLError(.serverCertificateUntrusted),
            serverURLs: ["https://mobaile.example.com"]
        )

        XCTAssertTrue(message.contains("does not trust this server certificate"))
    }

    @MainActor
    func testPromoteResolvedServerURLDoesNotDemoteTailscaleToLan() {
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )

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
    func testPromoteResolvedServerURLDoesNotDemoteTailscaleMagicDNSToRawIP() {
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )

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
                ]
            ),
            fallbackPrimaryServerURL: "http://vemunds-macbook-air.tail6a5903.ts.net:8000"
        )

        vm.promoteResolvedServerURL("http://100.111.99.51:8000")

        XCTAssertEqual(vm.serverURL, "http://vemunds-macbook-air.tail6a5903.ts.net:8000")
        XCTAssertEqual(vm.connectionCandidateServerURLsForTesting, [
            "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
        ])
    }

    @MainActor
    func testPromoteResolvedServerURLRemembersLanFallbackWithoutDemotingTailscale() {
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )

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
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )
        vm.serverURL = "http://192.168.86.122:8000"
        vm.persistSettings()

        vm.promoteResolvedServerURL("http://vemunds-macbook-air.tail6a5903.ts.net:8000")

        XCTAssertEqual(vm.serverURL, "http://vemunds-macbook-air.tail6a5903.ts.net:8000")
        XCTAssertEqual(vm.connectionCandidateServerURLsForTesting, [
            "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            "http://192.168.86.122:8000",
        ])
    }

    @MainActor
    func testLoadSettingsPromotesPersistedLanPrimaryWhenTailscaleCandidateExists() {
        let harness = makeIsolatedPersistenceHarness()
        defer { harness.cleanup() }
        harness.defaults.set("http://192.168.86.122:8000", forKey: "mobaile.server_url")
        harness.defaults.set(
            [
                "http://192.168.86.122:8000",
                "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
                "http://100.111.99.51:8000",
            ],
            forKey: "mobaile.server_url_candidates"
        )

        let vm = VoiceAgentViewModel(
            threadStore: harness.store,
            defaults: harness.defaults,
            draftAttachmentDirectory: harness.draftDirectory
        )

        XCTAssertEqual(vm.serverURL, "http://vemunds-macbook-air.tail6a5903.ts.net:8000")
        XCTAssertEqual(vm.connectionCandidateServerURLsForTesting, [
            "http://vemunds-macbook-air.tail6a5903.ts.net:8000",
            "http://100.111.99.51:8000",
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
        XCTAssertEqual(decoded.runStatus, "")
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

    func testChatThreadPresentationStatusPrefersTerminalStatusOverProgressWords() {
        let completedThread = ChatThread(
            id: UUID(),
            title: "Completed",
            updatedAt: Date(),
            conversation: [],
            runID: "run-completed",
            summaryText: "Completed after executing checks",
            transcriptText: "",
            statusText: "Run status: completed after executing checks",
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex"
        )
        let failedThread = ChatThread(
            id: UUID(),
            title: "Failed",
            updatedAt: Date(),
            conversation: [],
            runID: "run-failed",
            summaryText: "Failed while summarizing",
            transcriptText: "",
            statusText: "Run status: failed while summarizing",
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex"
        )

        XCTAssertEqual(completedThread.presentationStatus, .completed)
        XCTAssertEqual(failedThread.presentationStatus, .failed)
    }

    func testChatThreadPresentationStatusPrefersExplicitRunStatus() {
        let completedThread = ChatThread(
            id: UUID(),
            title: "Completed",
            updatedAt: Date(),
            conversation: [],
            runID: "run-completed",
            summaryText: "",
            transcriptText: "",
            statusText: "Summarizing output...",
            runStatus: "completed",
            pendingHumanUnblock: HumanUnblockRequest(instructions: "Stale unblock"),
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex"
        )
        let runningThread = ChatThread(
            id: UUID(),
            title: "Running",
            updatedAt: Date(),
            conversation: [],
            runID: "run-running",
            summaryText: "",
            transcriptText: "",
            statusText: "Run status: completed",
            runStatus: "running",
            resolvedWorkingDirectory: "",
            activeRunExecutor: "codex"
        )

        XCTAssertEqual(completedThread.presentationStatus, .completed)
        XCTAssertEqual(runningThread.presentationStatus, .running)
    }

    func testChatThreadPresentationStatusMarksConnectionStateAsFailed() {
        let thread = ChatThread(
            id: UUID(),
            title: "Reconnect",
            updatedAt: Date(),
            conversation: [],
            runID: "run-123",
            summaryText: "",
            transcriptText: "",
            statusText: "Connection needs repair",
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

    func testChatThreadStorePersistsRunStatus() {
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
                summaryText: "",
                transcriptText: "",
                statusText: "Summarizing output...",
                runStatus: "blocked",
                resolvedWorkingDirectory: "/Users/test/project",
                activeRunExecutor: "codex"
            )
        )

        let loaded = store.loadThreads()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.runStatus, "blocked")
        XCTAssertEqual(loaded.first?.presentationStatus, .needsInput)
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
                ExecutionEvent(type: "chat.message", message: #"{"type":"assistant_response","version":"1.0","message_kind":"progress","summary":"Checking the workspace…","sections":[],"agenda_items":[],"artifacts":[]}"#),
                ExecutionEvent(type: "chat.message", message: #"{"type":"assistant_response","version":"1.0","message_kind":"progress","summary":"Running the test suite…","sections":[],"agenda_items":[],"artifacts":[]}"#)
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
                ExecutionEvent(type: "chat.message", message: #"{"type":"assistant_response","version":"1.0","message_kind":"progress","summary":"Checking the workspace…","sections":[],"agenda_items":[],"artifacts":[]}"#),
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
    func testReloadDropsPersistedLiveActivityForTerminalThread() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }
        let threadID = UUID()
        let runID = "completed-live-\(UUID().uuidString)"

        store.upsertThread(
            ChatThread(
                id: threadID,
                title: "Completed Live Activity",
                updatedAt: Date(),
                conversation: [],
                runID: runID,
                summaryText: "Done",
                transcriptText: "",
                statusText: "Run status: completed",
                resolvedWorkingDirectory: "",
                activeRunExecutor: "codex"
            )
        )
        store.upsertMessage(
            threadID: threadID,
            message: ConversationMessage(
                role: "assistant",
                text: "Summarizing the final result.",
                presentation: .liveActivity,
                sourceRunID: runID
            ),
            position: 0
        )
        defaults.set(threadID.uuidString, forKey: "mobaile.active_thread_id")

        let reloaded = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )

        XCTAssertEqual(reloaded.activeThreadID, threadID)
        XCTAssertFalse(reloaded.isLoading)
        XCTAssertFalse(reloaded.conversation.contains { $0.presentation == .liveActivity })
        XCTAssertFalse(store.loadMessages(threadID: threadID).contains { $0.presentation == .liveActivity })
    }

    @MainActor
    func testCanRetryThreadUsesPersistedLastUserMessage() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }
        let threadID = UUID()

        store.upsertThread(
            ChatThread(
                id: threadID,
                title: "Failed Prompt",
                updatedAt: Date(),
                conversation: [],
                runID: "failed-run-\(UUID().uuidString)",
                summaryText: "Run failed",
                transcriptText: "",
                statusText: "Run status: failed",
                resolvedWorkingDirectory: "",
                activeRunExecutor: "codex"
            )
        )
        store.upsertMessage(
            threadID: threadID,
            message: ConversationMessage(role: "user", text: "Try the failing task again."),
            position: 0
        )
        defaults.set(threadID.uuidString, forKey: "mobaile.active_thread_id")

        let reloaded = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )

        XCTAssertTrue(reloaded.canRetryThread(threadID))
    }

    @MainActor
    func testReloadedRunningThreadWithoutObservedRunDoesNotLockComposerOffline() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }
        let threadID = UUID()
        let runID = "stale-running-\(UUID().uuidString)"

        store.upsertThread(
            ChatThread(
                id: threadID,
                title: "Stale Running Thread",
                updatedAt: Date(),
                conversation: [],
                runID: runID,
                summaryText: "Run started",
                transcriptText: "",
                statusText: "Running...",
                resolvedWorkingDirectory: "",
                activeRunExecutor: "codex"
            )
        )
        defaults.set(threadID.uuidString, forKey: "mobaile.active_thread_id")

        let reloaded = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )

        XCTAssertEqual(reloaded.activeThreadID, threadID)
        XCTAssertEqual(reloaded.runID, runID)
        XCTAssertFalse(reloaded.isLoading)
        XCTAssertFalse(reloaded._test_hasObservedRunContext(runID: runID, threadID: threadID))
    }

    @MainActor
    func testRunStateRecoveryRequiresBackendConnectionAndNonTerminalRun() {
        let vm = VoiceAgentViewModel()
        vm.serverURL = ""
        vm.apiToken = ""

        XCTAssertFalse(vm._test_shouldRecoverRunState(runID: "run-1", statusText: "Running..."))

        vm.serverURL = "http://127.0.0.1:8000"
        vm.apiToken = "token"

        XCTAssertTrue(vm._test_shouldRecoverRunState(runID: "run-1", statusText: "Running..."))
        XCTAssertFalse(vm._test_shouldRecoverRunState(runID: "run-1", statusText: "Run status: completed"))
        XCTAssertFalse(vm._test_shouldRecoverRunState(runID: "run-1", statusText: "Running...", runStatus: "completed"))
        XCTAssertFalse(vm._test_shouldRecoverRunState(runID: "", statusText: "Running..."))
    }

    @MainActor
    func testUnavailableRunObservationUnlocksThreadButKeepsVisibleEvents() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        let runID = "unavailable-run-\(UUID().uuidString)"
        let event = ExecutionEvent(
            type: "activity.updated",
            message: "Running backend checks.",
            stage: "executing",
            title: "Executing",
            displayMessage: "Running backend checks.",
            level: "info",
            eventID: "evt-\(UUID().uuidString)",
            createdAt: nil
        )

        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Running...",
            activeRunExecutor: "codex"
        )
        vm._test_bindObservedRun(runID: runID, threadID: threadID)
        vm._test_ingestRunEvents([event], runID: runID, threadID: threadID)
        vm.isLoading = true

        vm._test_markRunObservationUnavailable(runID: runID, threadID: threadID)

        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.statusText, "Run state unavailable")
        XCTAssertEqual(vm.events.map(\.message), ["Running backend checks."])
        XCTAssertFalse(vm._test_hasObservedRunContext(runID: runID, threadID: threadID))
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

    @MainActor
    func testProfileRuntimeSettingPresentationExplainsStateAndDefaults() {
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
                        id: "profile_agents",
                        title: "Profile Instructions",
                        kind: "enum",
                        allowCustom: false,
                        value: "enabled",
                        options: ["enabled", "disabled"]
                    ),
                    RuntimeSettingDescriptor(
                        id: "profile_memory",
                        title: "Profile Memory",
                        kind: "enum",
                        allowCustom: false,
                        value: "disabled",
                        options: ["enabled", "disabled"]
                    ),
                ]
            )
        ]
        vm.backendDefaultExecutor = "codex"
        vm.executor = "codex"

        XCTAssertTrue(vm.isProfileContextRuntimeSetting("profile_agents"))
        XCTAssertEqual(
            vm.runtimeSettingDefaultOptionLabel(for: "profile_agents", executor: "codex"),
            "Follow backend default (Include saved instructions)"
        )
        XCTAssertEqual(
            vm.runtimeSettingPickerTitle(for: "disabled", settingID: "profile_agents", executor: "codex"),
            "Ignore saved instructions"
        )
        XCTAssertEqual(
            vm.runtimeSettingEffectSummary(for: "profile_agents", executor: "codex"),
            "New runs include your saved profile instructions on top of the repo and runtime rules."
        )
        XCTAssertEqual(
            vm.runtimeSettingBackendDefaultSummary(for: "profile_memory", executor: "codex"),
            "Backend default: start without saved memory."
        )
        XCTAssertEqual(vm.runtimeSettingToggleTitle(for: "profile_memory"), "Use saved memory in new runs")

        vm.setRuntimeSettingValue("disabled", for: "profile_agents", executor: "codex")

        XCTAssertFalse(vm.runtimeSettingUsesBackendDefault(for: "profile_agents", executor: "codex"))
        XCTAssertEqual(vm.runtimeSettingStateLabel(for: "profile_agents", executor: "codex"), "Skipped")
        XCTAssertEqual(
            vm.runtimeSettingEffectSummary(for: "profile_agents", executor: "codex"),
            "New runs skip your saved profile instructions. Repo and runtime rules still apply."
        )
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

    func testAttachmentDraftServiceRejectsOversizedAttachmentBeforeStaging() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = AttachmentDraftService(
            draftDirectory: directory,
            policy: AttachmentDraftPolicy(maxAttachmentBytes: 8, maxAudioBytes: 8)
        )

        XCTAssertThrowsError(
            try service.stageAttachmentData(
                Data(repeating: 1, count: 9),
                fileName: "large.txt",
                mimeType: "text/plain"
            )
        ) { error in
            XCTAssertEqual(
                error as? AttachmentDraftValidationError,
                .fileTooLarge(fileName: "large.txt", sizeBytes: 9, maxBytes: 8)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAttachmentDraftServiceSummarizesVisibleSizeAndKinds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = AttachmentDraftService(draftDirectory: directory)
        let image = try service.stageAttachmentData(
            Data(repeating: 1, count: 1024),
            fileName: "screen.png",
            mimeType: "image/png"
        )
        let note = try service.stageAttachmentData(
            Data("hello".utf8),
            fileName: "note.md",
            mimeType: "text/markdown"
        )

        let summary = try XCTUnwrap(service.summaryText(for: [image, note]))

        XCTAssertTrue(summary.contains("2 files"))
        XCTAssertTrue(summary.contains("Mixed"))
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

    func testExtractInlineArtifactPathsUsesWorkspaceForRelativeLinks() {
        let text = """
        [notes.txt](notes.txt)
        [nested.md](docs/nested.md)
        """

        let paths = _test_extractInlineArtifactPaths(
            text,
            serverURL: "http://127.0.0.1:8000",
            workspacePath: "/Users/test/project"
        )

        XCTAssertEqual(paths, [
            "/Users/test/project/notes.txt",
            "/Users/test/project/docs/nested.md",
        ])
    }

    func testImageMimeArtifactRendersAsImageSegmentEvenWhenTypeIsFile() {
        let json = """
        {
          "type":"assistant_response",
          "version":"1.0",
          "summary":"Generated preview",
          "sections":[],
          "agenda_items":[],
          "artifacts":[{"type":"file","title":"plot.png","path":"plots/plot.png","mime":"image/png"}]
        }
        """

        let kinds = _test_messageSegmentKindNames(
            json,
            serverURL: "http://127.0.0.1:8000",
            workspacePath: "/Users/test/project"
        )

        XCTAssertTrue(kinds.contains("image"))
    }

    func testExtractInlineArtifactTitlesIgnoresMarkdownLinksInsideCodeFences() {
        let text = """
        Here is the example:

        ```markdown
        [not-an-artifact](/Users/test/Mobile Documents/session/secret.txt)
        ```

        [notes.txt](/Users/test/Mobile Documents/session/notes.txt)
        """

        let extracted = _test_extractInlineArtifactTitles(text, serverURL: "http://127.0.0.1:8000")
        XCTAssertEqual(extracted, ["notes.txt"])
    }

    func testExtractArtifactPathDecodesPercentEncodedAbsolutePaths() {
        let extracted = _test_extractArtifactPath("/Users/test/Mobile%20Documents/session/AGENTS.md")
        XCTAssertEqual(extracted, "/Users/test/Mobile Documents/session/AGENTS.md")
    }

    func testResolveArtifactURLDecodesPercentEncodedAbsolutePaths() {
        let resolved = _test_resolveArtifactURL(
            path: "/Users/test/Mobile%20Documents/session/AGENTS.md",
            serverURL: "http://127.0.0.1:8000"
        )
        XCTAssertEqual(
            resolved,
            "http://127.0.0.1:8000/v1/files?path=/Users/test/Mobile%20Documents/session/AGENTS.md"
        )
        XCTAssertFalse(resolved?.contains("%2520") == true)
    }

    func testArtifactDownloadNameUsesBackendFileQueryPathExtension() {
        let artifact = ChatArtifact(
            type: "file",
            title: "Run report",
            path: nil,
            mime: nil,
            url: "http://old-host.example/v1/files?path=/Users/test/Mobile%20Documents/session/report.pdf"
        )

        let suggested = APIClient()._test_suggestedDownloadFileName(
            serverURL: "http://127.0.0.1:8000",
            artifact: artifact
        )

        XCTAssertEqual(suggested, "Run-report.pdf")
    }

    func testArtifactInspectURLUsesBackendPathAndPreviewLimit() {
        let artifact = ChatArtifact(
            type: "code",
            title: "AGENTS.md",
            path: "/Users/test/Mobile%20Documents/session/AGENTS.md",
            mime: "text/markdown",
            url: nil
        )

        let resolved = APIClient()._test_resolveArtifactInspectURL(
            serverURL: "http://127.0.0.1:8000",
            artifact: artifact,
            textPreviewBytes: 4096,
            textPreviewOffset: 8192,
            textSearch: "needle"
        )

        XCTAssertEqual(resolved?.path, "/v1/files/inspect")
        XCTAssertEqual(
            URLComponents(url: resolved!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "path" })?
                .value,
            "/Users/test/Mobile Documents/session/AGENTS.md"
        )
        XCTAssertEqual(
            URLComponents(url: resolved!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "text_preview_bytes" })?
                .value,
            "4096"
        )
        XCTAssertEqual(
            URLComponents(url: resolved!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "text_preview_offset" })?
                .value,
            "8192"
        )
        XCTAssertEqual(
            URLComponents(url: resolved!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "text_search" })?
                .value,
            "needle"
        )
    }

    func testArtifactPreviewCacheKeyIncludesInspectionVersion() {
        let url = URL(string: "http://127.0.0.1:8000/v1/files?path=/repo/PreviewPlot.png")!

        let key = APIClient()._test_previewDownloadCacheKey(url: url, cacheVersion: "2026-04-28T20:11:00Z:128")

        XCTAssertEqual(
            key,
            "http://127.0.0.1:8000/v1/files?path=/repo/PreviewPlot.png#2026-04-28T20:11:00Z:128"
        )
    }

    func testComposerDisplayLineEstimateAccountsForWrappingAndBlankLines() {
        XCTAssertEqual(_test_estimatedComposerDisplayLineCount("", charactersPerLine: 8), 1)
        XCTAssertEqual(_test_estimatedComposerDisplayLineCount("short", charactersPerLine: 8), 1)
        XCTAssertEqual(_test_estimatedComposerDisplayLineCount("123456789", charactersPerLine: 8), 2)
        XCTAssertEqual(_test_estimatedComposerDisplayLineCount("first\n\nsecond", charactersPerLine: 8), 3)
        XCTAssertEqual(_test_estimatedComposerDisplayLineCount("abc", charactersPerLine: 0), 3)
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
    func testVoiceModeDeactivatesWhenRecorderStartFails() async throws {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory,
            recorder: FailingAudioRecorder()
        )
        vm.serverURL = "http://127.0.0.1:8000"
        vm.apiToken = "token"

        await vm.startVoiceModeIfNeeded()

        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertFalse(vm.isVoiceModeActiveForCurrentThread)
        XCTAssertFalse(vm.isRecording)
        XCTAssertNil(vm.recordingStartedAt)
        XCTAssertEqual(vm.statusText, "Microphone access needed")
    }

    @MainActor
    func testVoiceModeDeactivatesAfterPreRunVoiceInputFailure() throws {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try XCTUnwrap(vm.activeThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: threadID)

        vm._test_deactivateVoiceModeAfterVoiceInputFailure(threadID: threadID)

        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertFalse(vm.isVoiceModeActiveForCurrentThread)
    }

    @MainActor
    func testAutoSendSilenceDelayIsBoundedAndFormatted() {
        let vm = VoiceAgentViewModel()

        vm.autoSendAfterSilenceSeconds = "10"
        XCTAssertEqual(vm.autoSendAfterSilenceDelaySeconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(vm.autoSendAfterSilenceDelayLabel, "5.0 seconds")

        vm.setAutoSendAfterSilenceDelay(0.1)
        XCTAssertEqual(vm.autoSendAfterSilenceSeconds, "0.8")
        XCTAssertEqual(vm.autoSendAfterSilenceDelayLabel, "0.8 seconds")
    }

    @MainActor
    func testPersistSettingsSanitizesInvalidAutoSendSilenceDelay() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        vm.autoSendAfterSilenceSeconds = "abc"

        vm.persistSettings()

        XCTAssertEqual(vm.autoSendAfterSilenceSeconds, "1.2")
        XCTAssertEqual(defaults.string(forKey: "mobaile.auto_send_after_silence_seconds"), "1.2")
    }

    @MainActor
    func testVoiceModeResumeDoesNotWaitForeverWhenSpokenRepliesAreDisabled() async throws {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        let threadID = try XCTUnwrap(vm.activeThreadID)
        vm.speakRepliesEnabled = false
        vm._test_setVoiceModeEnabled(true, threadID: threadID)

        vm._test_scheduleVoiceModeResumeAfterCurrentReply(
            threadID: threadID,
            replyText: "The run completed and the next prompt can start."
        )
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertFalse(vm._test_shouldResumeVoiceModeAfterSpeech())
        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertEqual(
            vm.statusText,
            "Run setup on your computer or enter connection details first."
        )
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
    func testSwitchingThreadsDiscardsActiveRecording() {
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
        vm._test_setIsRecording(true)

        vm.switchToThread(secondThreadID)

        XCTAssertFalse(vm.isRecording)
        XCTAssertNil(vm.recordingStartedAt)
    }

    @MainActor
    func testSwitchingThreadsPublishesVoiceModeEndedNotice() {
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

        XCTAssertEqual(vm._test_voiceInteractionNoticeText(), "Voice mode ended")
    }

    @MainActor
    func testSwitchingThreadsWhileRecordingInVoiceModeDiscardsCaptureAndPublishesNotice() {
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
        vm._test_setIsRecording(true)

        vm.switchToThread(secondThreadID)

        XCTAssertFalse(vm.isRecording)
        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertEqual(vm._test_voiceInteractionNoticeText(), "Voice mode ended")
    }

    @MainActor
    func testSwitchingThreadsClearsVoiceModeEndedNoticeOnLaterThreadChange() {
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
        vm.createNewThread()
        guard let thirdThreadID = vm.activeThreadID else {
            XCTFail("Expected a third thread")
            return
        }

        defer {
            vm.deleteThread(thirdThreadID)
            vm.deleteThread(secondThreadID)
            vm.deleteThread(firstThreadID)
        }

        vm.switchToThread(firstThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
        vm.switchToThread(secondThreadID)
        XCTAssertEqual(vm._test_voiceInteractionNoticeText(), "Voice mode ended")

        vm.switchToThread(thirdThreadID)

        XCTAssertNil(vm._test_voiceInteractionNoticeText())
    }

    @MainActor
    func testSwitchingThreadsKeepsLastVoiceModeThreadForExternalResume() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
        vm.createNewThread()
        let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

        vm.switchToThread(firstThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
        vm.switchToThread(secondThreadID)

        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertEqual(vm._test_lastVoiceModeThreadID(), firstThreadID)
        XCTAssertEqual(vm._test_prepareExternalVoiceResumeTarget(), .existing(firstThreadID))
    }

    @MainActor
    func testDeletingStoredVoiceThreadFallsBackToCurrentThread() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
        vm.createNewThread()
        let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

        vm.switchToThread(firstThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
        vm.switchToThread(secondThreadID)
        vm.deleteThread(firstThreadID)

        XCTAssertEqual(vm._test_prepareExternalVoiceResumeTarget(), .existing(secondThreadID))
    }

    @MainActor
    func testStartVoiceTaskShortcutDoesNotRetargetWhenConnectionMissing() async {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
        vm.createNewThread()
        let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

        vm.switchToThread(firstThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
        vm.switchToThread(secondThreadID)
        vm.serverURL = ""
        vm.apiToken = ""

        await vm.handleStartVoiceTaskShortcut()

        XCTAssertEqual(vm.activeThreadID, secondThreadID)
        XCTAssertEqual(vm.threads.count, 2)
        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertEqual(
            vm.statusText,
            "Run setup on your computer or enter connection details first."
        )
    }

    @MainActor
    func testAirPodsControlResumesLastVoiceThreadAndStartsListening() async throws {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let recorder = SuccessfulAudioRecorder()
        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory,
            recorder: recorder
        )
        vm.serverURL = "http://127.0.0.1:8000"
        vm.apiToken = "token"
        let firstThreadID = try XCTUnwrap(vm.activeThreadID)
        vm.createNewThread()
        let secondThreadID = try XCTUnwrap(vm.activeThreadID)

        vm.switchToThread(firstThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
        vm.switchToThread(secondThreadID)

        await vm.toggleRecordingFromHeadsetControl()

        XCTAssertEqual(vm.activeThreadID, firstThreadID)
        XCTAssertTrue(vm.voiceModeEnabled)
        XCTAssertTrue(vm.isVoiceModeActiveForCurrentThread)
        XCTAssertTrue(vm.isRecording)
        XCTAssertEqual(recorder.startCallCount, 1)
    }

    @MainActor
    func testAirPodsControlStopsVoiceLoopWhileReplyContinues() async throws {
        let vm = VoiceAgentViewModel()
        vm.serverURL = "http://127.0.0.1:8000"
        vm.apiToken = "token"
        let threadID = try XCTUnwrap(vm.activeThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: threadID)
        vm.isLoading = true
        vm.statusText = "Running backend checks"

        await vm.toggleRecordingFromHeadsetControl()

        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertFalse(vm.isVoiceModeActiveForCurrentThread)
        XCTAssertTrue(vm.isLoading)
        XCTAssertEqual(vm.statusText, "Running backend checks")
        XCTAssertEqual(vm._test_voiceInteractionNoticeText(), "Voice mode will stop")
    }

    @MainActor
    func testAirPodsControlDisabledDoesNotStartListening() async {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let recorder = SuccessfulAudioRecorder()
        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory,
            recorder: recorder
        )
        vm.serverURL = "http://127.0.0.1:8000"
        vm.apiToken = "token"
        vm.airPodsClickToRecordEnabled = false

        await vm.toggleRecordingFromHeadsetControl()

        XCTAssertFalse(vm.voiceModeEnabled)
        XCTAssertFalse(vm.isRecording)
        XCTAssertEqual(recorder.startCallCount, 0)
    }

    @MainActor
    func testLastVoiceModeThreadPersistsAcrossReload() {
        let (store, defaults, draftDirectory, cleanup) = makeIsolatedPersistenceHarness()
        defer { cleanup() }

        let vm = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )
        let firstThreadID = try! XCTUnwrap(vm.activeThreadID)
        vm.createNewThread()
        let secondThreadID = try! XCTUnwrap(vm.activeThreadID)

        vm.switchToThread(firstThreadID)
        vm._test_setVoiceModeEnabled(true, threadID: firstThreadID)
        vm.switchToThread(secondThreadID)

        let reloaded = VoiceAgentViewModel(
            threadStore: store,
            defaults: defaults,
            draftAttachmentDirectory: draftDirectory
        )

        XCTAssertEqual(reloaded._test_lastVoiceModeThreadID(), firstThreadID)
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
    func testCompletedRunKeepsVisibleEventsForLogs() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        let runID = "completed-run-\(UUID().uuidString)"
        let event = ExecutionEvent(
            type: "activity.updated",
            message: "Running backend checks.",
            stage: "executing",
            title: "Executing",
            displayMessage: "Running backend checks.",
            level: "info",
            eventID: "evt-\(UUID().uuidString)",
            createdAt: nil
        )

        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Running...",
            activeRunExecutor: "codex"
        )
        vm._test_bindObservedRun(runID: runID, threadID: threadID)
        vm._test_ingestRunEvents([event], runID: runID, threadID: threadID)

        vm._test_applyTerminalRunState(
            runID: runID,
            threadID: threadID,
            status: "completed",
            summary: "Done",
            events: [event]
        )

        XCTAssertFalse(vm._test_hasObservedRunContext(runID: runID, threadID: threadID))
        XCTAssertEqual(vm.events.map(\.message), ["Running backend checks."])
        XCTAssertEqual(vm.currentRunDiagnostics?.eventCount, 1)
    }

    @MainActor
    func testTerminalRunStateStillClearsLiveActivityWhenAlreadyMarkedComplete() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        let runID = "already-complete-\(UUID().uuidString)"
        let event = ExecutionEvent(
            type: "activity.updated",
            message: "Summarizing the final result.",
            stage: "summarizing",
            title: "Summarizing",
            displayMessage: "Summarizing the final result.",
            level: "info",
            eventID: "evt-\(UUID().uuidString)",
            createdAt: nil
        )

        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Running...",
            runStatus: "running",
            activeRunExecutor: "codex"
        )
        vm._test_bindObservedRun(runID: runID, threadID: threadID)
        vm._test_ingestRunEvents([event], runID: runID, threadID: threadID)
        vm.summaryText = "Done"
        vm.didCompleteRun = true

        vm._test_applyTerminalRunState(
            runID: runID,
            threadID: threadID,
            status: "completed",
            summary: "Done",
            events: [event]
        )

        XCTAssertFalse(vm.conversation.contains { $0.presentation == .liveActivity })
        XCTAssertFalse(vm._test_hasObservedRunContext(runID: runID, threadID: threadID))
    }

    @MainActor
    func testCompletedRunIDIsNotCancellableWhileNextRunPrepares() {
        let vm = VoiceAgentViewModel()
        vm.createNewThread()
        let threadID = try! XCTUnwrap(vm.activeThreadID)
        let runID = "old-run-\(UUID().uuidString)"

        vm._test_updateThreadMetadata(
            threadID: threadID,
            runID: runID,
            statusText: "Run status: completed",
            activeRunExecutor: "codex"
        )
        vm.isLoading = true

        XCTAssertFalse(vm.canCancelActiveOperation)
        XCTAssertFalse(vm._test_isRunActivelyObserved(runID))
    }

    @MainActor
    func testVoiceInputPreparationIsCancellableBeforeRunIDExists() {
        let vm = VoiceAgentViewModel()
        vm.isLoading = true
        vm._test_setActiveVoiceInputPhase(.transcribing)

        XCTAssertTrue(vm.canCancelActiveOperation)
        XCTAssertEqual(vm.activeOperationCancelAccessibilityLabel, "Cancel transcription")

        vm.cancelActiveOperation()

        XCTAssertEqual(vm.statusText, "Cancelling voice input...")
        XCTAssertFalse(vm.isPreparingVoiceInput)
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

private final class FailingAudioRecorder: AudioRecording {
    func start(
        silenceConfig: AudioRecorderService.SilenceConfig?,
        onSilenceDetected: (() -> Void)?
    ) async throws {
        throw RecorderError.permissionDenied
    }

    func stop() -> URL? {
        nil
    }
}

private final class SuccessfulAudioRecorder: AudioRecording {
    private(set) var startCallCount = 0

    func start(
        silenceConfig: AudioRecorderService.SilenceConfig?,
        onSilenceDetected: (() -> Void)?
    ) async throws {
        startCallCount += 1
    }

    func stop() -> URL? {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-agent-test-recording-\(UUID().uuidString).m4a")
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
            KeychainStore.delete(service: "MOBaiLE", account: "api_token")
            KeychainStore.delete(service: "MOBaiLE", account: "refresh_token")
            try? FileManager.default.removeItem(at: baseURL)
        }

        return (store, defaults, draftDirectory, cleanup)
    }
}
