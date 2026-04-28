import Foundation

extension VoiceAgentViewModel {
    func toggleDirectoryBrowser() async {
        if showDirectoryBrowser {
            showDirectoryBrowser = false
            return
        }
        await refreshDirectoryBrowser()
        showDirectoryBrowser = true
    }

    func openDirectory(path: String) async {
        await refreshDirectoryBrowser(path: path)
        showDirectoryBrowser = true
    }

    func openDirectoryEntry(_ entry: DirectoryEntry) async {
        guard entry.isDirectory else { return }
        await openDirectory(path: entry.path)
    }

    func downloadDirectoryFileForPreview(
        _ entry: DirectoryEntry,
        cacheVersion: String? = nil
    ) async throws -> URL {
        guard !entry.isDirectory else {
            throw APIError.invalidURL
        }
        if PreviewScenario.current != nil,
           FileManager.default.fileExists(atPath: entry.path) {
            return URL(fileURLWithPath: entry.path)
        }
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else {
            throw APIError.missingCredentials
        }
        let artifact = ChatArtifact(
            type: VoiceAgentDirectoryBrowser.artifactType(for: entry),
            title: entry.name,
            path: entry.path,
            mime: entry.mime,
            url: nil
        )
        return try await client.downloadArtifactToTemporaryFile(
            serverURL: normalizedServerURL,
            token: token,
            artifact: artifact,
            cacheVersion: cacheVersion ?? entry.previewCacheVersion
        )
    }

    func inspectDirectoryFileForPreview(
        _ entry: DirectoryEntry,
        textPreviewBytes: Int = 64 * 1024
    ) async throws -> FileInspectionResponse {
        guard !entry.isDirectory else {
            throw APIError.invalidURL
        }
        if PreviewScenario.current != nil,
           FileManager.default.fileExists(atPath: entry.path) {
            return try await LocalFileInspection.inspect(
                url: URL(fileURLWithPath: entry.path),
                name: entry.name,
                mime: entry.mime,
                textPreviewBytes: textPreviewBytes
            )
        }
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else {
            throw APIError.missingCredentials
        }
        let artifact = ChatArtifact(
            type: VoiceAgentDirectoryBrowser.artifactType(for: entry),
            title: entry.name,
            path: entry.path,
            mime: entry.mime,
            url: nil
        )
        return try await client.inspectArtifactFile(
            serverURL: normalizedServerURL,
            token: token,
            artifact: artifact,
            textPreviewBytes: textPreviewBytes
        )
    }

    func navigateDirectoryUp() async {
        let current = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            await refreshDirectoryBrowser()
            return
        }
        if current == "/" {
            await refreshDirectoryBrowser(path: "/")
            return
        }
        let parent = (current as NSString).deletingLastPathComponent
        if parent.isEmpty {
            await refreshDirectoryBrowser(path: current.hasPrefix("/") ? "/" : current)
        } else {
            await refreshDirectoryBrowser(path: parent)
        }
    }

    func refreshDirectoryBrowser(path: String? = nil) async {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerURL.isEmpty, !token.isEmpty else {
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
            directoryBrowserError = "Set server URL and API token to browse cwd."
            directoryBrowserMissingPath = ""
            directoryBrowserPath = ""
            isLoadingDirectoryBrowser = false
            return
        }

        isLoadingDirectoryBrowser = true
        directoryBrowserError = ""
        directoryBrowserMissingPath = ""
        let explicitPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let browserPath = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredPath: String?
        if !explicitPath.isEmpty {
            preferredPath = explicitPath
        } else if !browserPath.isEmpty {
            preferredPath = browserPath
        } else {
            preferredPath = directoryPathForListing
        }
        do {
            let response = try await client.fetchDirectoryListing(
                serverURL: normalizedServerURL,
                token: token,
                path: preferredPath
            )
            directoryBrowserEntries = response.entries
            directoryBrowserTruncated = response.truncated
            directoryBrowserPath = response.path
        } catch let apiError as APIError {
            if case let .httpError(code, body) = apiError, code == 404 {
                let lower = body.lowercased()
                if lower.contains("not found") && !lower.contains("directory not found") {
                    directoryBrowserError = "Backend does not support folder listing yet. Pull latest backend and restart."
                } else {
                    if let missing = preferredPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !missing.isEmpty {
                        directoryBrowserMissingPath = missing
                        directoryBrowserError = "Directory not found. You can create it from here."
                    } else {
                        directoryBrowserError = "Directory not found. Check the working directory in Settings."
                    }
                }
            } else {
                directoryBrowserError = registerConnectionRepairIfNeeded(from: apiError) ?? apiError.localizedDescription
            }
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
        } catch {
            directoryBrowserEntries = []
            directoryBrowserTruncated = false
            directoryBrowserError = registerConnectionRepairIfNeeded(from: error) ?? error.localizedDescription
            directoryBrowserMissingPath = ""
        }
        isLoadingDirectoryBrowser = false
    }

    func createDirectoryFromBrowser() async {
        let target = directoryBrowserMissingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !normalizedServerURL.isEmpty, !token.isEmpty else { return }
        isLoadingDirectoryBrowser = true
        directoryBrowserError = ""
        do {
            let response = try await client.createDirectory(
                serverURL: normalizedServerURL,
                token: token,
                path: target
            )
            directoryBrowserMissingPath = ""
            await refreshDirectoryBrowser(path: response.path)
        } catch {
            directoryBrowserError = registerConnectionRepairIfNeeded(from: error) ?? error.localizedDescription
            isLoadingDirectoryBrowser = false
        }
    }

    func createDirectoryInCurrentBrowser(name: String) async -> Bool {
        let folderName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty, !normalizedServerURL.isEmpty, !token.isEmpty else { return false }

        let basePath = directoryBrowserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath: String
        if basePath.isEmpty {
            targetPath = folderName
        } else if basePath == "/" {
            targetPath = "/" + folderName
        } else {
            targetPath = basePath + "/" + folderName
        }

        isLoadingDirectoryBrowser = true
        directoryBrowserError = ""
        do {
            let response = try await client.createDirectory(
                serverURL: normalizedServerURL,
                token: token,
                path: targetPath
            )
            await refreshDirectoryBrowser(path: basePath.isEmpty ? response.path : basePath)
            return true
        } catch {
            directoryBrowserError = registerConnectionRepairIfNeeded(from: error) ?? error.localizedDescription
            isLoadingDirectoryBrowser = false
            return false
        }
    }

    func hideDirectoryBrowser() {
        showDirectoryBrowser = false
    }

    var directoryBreadcrumbs: [DirectoryBreadcrumb] {
        VoiceAgentDirectoryBrowser.breadcrumbs(for: directoryBrowserPath)
    }

    var canNavigateDirectoryUp: Bool {
        VoiceAgentDirectoryBrowser.canNavigateUp(from: directoryBrowserPath)
    }

    var filteredDirectoryBrowserEntries: [DirectoryEntry] {
        VoiceAgentDirectoryBrowser.filteredEntries(
            directoryBrowserEntries,
            hideDotFolders: hideDotFoldersInBrowser
        )
    }

    var hiddenDotFolderCount: Int {
        VoiceAgentDirectoryBrowser.hiddenDotFolderCount(in: directoryBrowserEntries)
    }
}

private extension VoiceAgentViewModel {
    var directoryPathForListing: String? {
        let resolved = resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty {
            return resolved
        }
        guard let requested = normalizedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty,
              requested != "~",
              requested != "." else {
            return nil
        }
        return requested
    }
}
