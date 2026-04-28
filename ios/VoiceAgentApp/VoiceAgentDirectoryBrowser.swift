import Foundation

struct DirectoryBreadcrumb: Identifiable, Equatable {
    let id: String
    let title: String
    let path: String
}

enum VoiceAgentDirectoryBrowser {
    static func breadcrumbs(for rawPath: String) -> [DirectoryBreadcrumb] {
        let current = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return [] }
        if current == "/" {
            return [DirectoryBreadcrumb(id: "/", title: "/", path: "/")]
        }

        let isAbsolute = current.hasPrefix("/")
        let parts = current.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var crumbs: [DirectoryBreadcrumb] = []
        var running = isAbsolute ? "/" : ""
        if isAbsolute {
            crumbs.append(DirectoryBreadcrumb(id: "/", title: "/", path: "/"))
        }
        for part in parts {
            if running.isEmpty {
                running = part
            } else if running == "/" {
                running = "/" + part
            } else {
                running += "/" + part
            }
            crumbs.append(DirectoryBreadcrumb(id: running, title: part, path: running))
        }
        return crumbs
    }

    static func canNavigateUp(from rawPath: String) -> Bool {
        let current = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !current.isEmpty && current != "/"
    }

    static func filteredEntries(
        _ entries: [DirectoryEntry],
        hideDotFolders: Bool,
    ) -> [DirectoryEntry] {
        guard hideDotFolders else { return entries }
        return entries.filter { entry in
            !(entry.isDirectory && entry.name.hasPrefix("."))
        }
    }

    static func hiddenDotFolderCount(in entries: [DirectoryEntry]) -> Int {
        entries.reduce(0) { partial, entry in
            if entry.isDirectory && entry.name.hasPrefix(".") {
                return partial + 1
            }
            return partial
        }
    }

    static func artifactType(for entry: DirectoryEntry) -> String {
        guard !entry.isDirectory else { return "file" }
        switch inferAttachmentKind(fileName: entry.name, mimeType: resolvedMimeType(for: entry)) {
        case .image:
            return "image"
        case .code:
            return "code"
        case .file:
            return "file"
        }
    }

    static func resolvedMimeType(for entry: DirectoryEntry) -> String {
        inferAttachmentMimeType(fileName: entry.name, fallback: entry.mime)
    }
}
