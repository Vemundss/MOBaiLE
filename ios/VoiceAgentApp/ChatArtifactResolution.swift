import Foundation
import UniformTypeIdentifiers

enum ChatArtifactResolution {
    struct InlineMediaReference {
        let range: NSRange
        let segment: MessageSegment
    }

    static func messageSegment(for artifact: ChatArtifact, serverURL: String) -> MessageSegment {
        if artifact.type.lowercased() == "image",
           let raw = artifact.url ?? artifact.path,
           let url = resolveImageURL(from: raw, serverURL: serverURL) {
            return MessageSegment(kind: .image(url: url), content: url)
        }
        return MessageSegment(kind: .artifact(item: artifact), content: artifact.title)
    }

    static func resolvedURL(for artifact: ChatArtifact, serverURL: String) -> URL? {
        if let raw = artifact.url, let parsed = URL(string: raw) {
            return parsed
        }
        if let path = artifact.path,
           let resolved = resolveImageURL(from: path, serverURL: serverURL),
           let url = URL(string: resolved) {
            return url
        }
        return nil
    }

    static func extractInlineMediaReferences(from text: String, serverURL: String) -> [InlineMediaReference] {
        var references: [InlineMediaReference] = []
        let nsRange = NSRange(text.startIndex..., in: text)

        if let imageRegex = try? NSRegularExpression(pattern: #"\!\[[^\]]*\]\(([^)]+)\)"#) {
            for match in imageRegex.matches(in: text, options: [], range: nsRange) {
                guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
                let raw = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let resolved = resolveImageURL(from: raw, serverURL: serverURL) else { continue }
                references.append(
                    InlineMediaReference(
                        range: match.range,
                        segment: MessageSegment(kind: .image(url: resolved), content: resolved)
                    )
                )
            }
        }

        if let linkRegex = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\(([^)]+)\)"#) {
            for match in linkRegex.matches(in: text, options: [], range: nsRange) {
                guard let titleRange = Range(match.range(at: 1), in: text),
                      let targetRange = Range(match.range(at: 2), in: text) else {
                    continue
                }
                let title = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let raw = String(text[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let artifact = resolveInlineArtifact(title: title, rawReference: raw, serverURL: serverURL) else {
                    continue
                }
                references.append(
                    InlineMediaReference(
                        range: match.range,
                        segment: MessageSegment(kind: .artifact(item: artifact), content: artifact.title)
                    )
                )
            }
        }

        return references.sorted { $0.range.location < $1.range.location }
    }

    static func removingInlineMediaReferences(from text: String, references: [InlineMediaReference]) -> String {
        guard !references.isEmpty else { return text }
        let sorted = references.sorted { $0.range.location < $1.range.location }
        var output = ""
        var cursor = text.startIndex
        for reference in sorted {
            guard let range = Range(reference.range, in: text) else { continue }
            output += String(text[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        output += String(text[cursor...])
        return collapseNewlines(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveImageURL(from raw: String, serverURL: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("path/to/") || lower.contains("absolute/path") {
            return nil
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard let rawURL = URL(string: trimmed) else {
                return nil
            }
            let url = rewriteProtectedBackendURL(rawURL, serverURL: serverURL) ?? rawURL
            guard isProtectedBackendURL(url, serverURL: serverURL) else {
                return nil
            }
            return url.absoluteString
        }
        let imagePath = extractImagePath(from: trimmed)
        guard let encoded = imagePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return "\(normalizedServerURL(serverURL))/v1/files?path=\(encoded)"
    }

    static func extractArtifactPath(from text: String) -> String {
        normalizeFilesystemPath(
            text
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\" <>"))
                .replacingOccurrences(of: "file://", with: "")
        )
    }

    static func extractImagePath(from text: String) -> String {
        let stripped = normalizeFilesystemPath(
            text
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\" "))
                .replacingOccurrences(of: "file://", with: "")
        )
        let absolutePattern = #"/[^`'\"()\n]+?\.(?:png|jpg|jpeg|gif|webp)"#
        if let regex = try? NSRegularExpression(pattern: absolutePattern, options: [.caseInsensitive]) {
            let range = NSRange(stripped.startIndex..., in: stripped)
            if let match = regex.firstMatch(in: stripped, options: [], range: range),
               let pathRange = Range(match.range, in: stripped) {
                return String(stripped[pathRange])
            }
        }

        let relativePattern = #"[^`'\"()\n]+?\.(?:png|jpg|jpeg|gif|webp)"#
        if let regex = try? NSRegularExpression(pattern: relativePattern, options: [.caseInsensitive]) {
            let range = NSRange(stripped.startIndex..., in: stripped)
            if let match = regex.firstMatch(in: stripped, options: [], range: range),
               let pathRange = Range(match.range, in: stripped) {
                return String(stripped[pathRange])
            }
        }
        return stripped
    }

    static func inferArtifactMimeType(from fileName: String) -> String? {
        let ext = URL(fileURLWithPath: fileName).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return nil }
        return type.preferredMIMEType
    }

    static func isProtectedBackendURL(_ url: URL, serverURL: String) -> Bool {
        guard let backend = URL(string: normalizedServerURL(serverURL)) else {
            return false
        }
        return url.host == backend.host &&
            (url.port ?? defaultPort(for: url.scheme)) == (backend.port ?? defaultPort(for: backend.scheme)) &&
            url.scheme == backend.scheme &&
            url.path.hasPrefix("/v1/")
    }

    private static func resolveInlineArtifact(title: String, rawReference: String, serverURL: String) -> ChatArtifact? {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("path/to/") || lower.contains("absolute/path") {
            return nil
        }

        let resolvedTitle = title.isEmpty ? fallbackArtifactTitle(from: trimmed) : title
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard let rawURL = URL(string: trimmed) else {
                return nil
            }
            let url = rewriteProtectedBackendURL(rawURL, serverURL: serverURL) ?? rawURL
            guard isBackendFileURL(url, serverURL: serverURL) else {
                return nil
            }
            let mime = inferArtifactMimeType(from: url.lastPathComponent)
            return ChatArtifact(
                type: inferArtifactType(fileName: url.lastPathComponent, mimeType: mime),
                title: resolvedTitle,
                path: nil,
                mime: mime,
                url: url.absoluteString
            )
        }

        let path = extractArtifactPath(from: trimmed)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let mime = inferArtifactMimeType(from: fileName)
        return ChatArtifact(
            type: inferArtifactType(fileName: fileName, mimeType: mime),
            title: resolvedTitle,
            path: path,
            mime: mime,
            url: nil
        )
    }

    private static func fallbackArtifactTitle(from reference: String) -> String {
        let name = URL(fileURLWithPath: extractArtifactPath(from: reference)).lastPathComponent
        return name.isEmpty ? "file" : name
    }

    private static func normalizeFilesystemPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%") else {
            return trimmed
        }
        return trimmed.removingPercentEncoding ?? trimmed
    }

    private static func inferArtifactType(fileName: String, mimeType: String?) -> String {
        let lowerMime = (mimeType ?? "").lowercased()
        if lowerMime.hasPrefix("image/") {
            return "image"
        }
        if lowerMime.hasPrefix("text/") {
            return "code"
        }
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json", "kt", "md", "mjs",
             "php", "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml":
            return "code"
        default:
            return "file"
        }
    }

    private static func isBackendFileURL(_ url: URL, serverURL: String) -> Bool {
        guard let backend = URL(string: normalizedServerURL(serverURL)) else {
            return false
        }
        return url.host == backend.host &&
            (url.port ?? defaultPort(for: url.scheme)) == (backend.port ?? defaultPort(for: backend.scheme)) &&
            url.scheme == backend.scheme &&
            url.path.hasPrefix("/v1/files")
    }

    private static func rewriteProtectedBackendURL(_ url: URL, serverURL: String) -> URL? {
        guard url.path.hasPrefix("/v1/"),
              let backend = URL(string: normalizedServerURL(serverURL)) else {
            return nil
        }
        let originalComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var components = URLComponents()
        components.scheme = backend.scheme
        components.host = backend.host
        components.port = backend.port
        components.path = url.path
        components.percentEncodedQuery = originalComponents?.percentEncodedQuery
        components.fragment = url.fragment
        return components.url
    }

    private static func normalizedServerURL(_ serverURL: String) -> String {
        serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https":
            return 443
        default:
            return 80
        }
    }

    private static func collapseNewlines(_ text: String) -> String {
        var out = text
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out
    }
}

#if DEBUG
func _test_extractArtifactPath(_ text: String) -> String {
    ChatArtifactResolution.extractArtifactPath(from: text)
}

func _test_extractImagePath(_ text: String) -> String {
    ChatArtifactResolution.extractImagePath(from: text)
}

func _test_resolveImageURL(_ raw: String, serverURL: String) -> String? {
    ChatArtifactResolution.resolveImageURL(from: raw, serverURL: serverURL)
}

func _test_resolveArtifactURL(path: String, serverURL: String) -> String? {
    let artifact = ChatArtifact(type: "file", title: "file", path: path, mime: nil, url: nil)
    return APIClient()._test_resolveArtifactURL(serverURL: serverURL, artifact: artifact)?.absoluteString
}

func _test_extractInlineArtifactTitles(_ text: String, serverURL: String) -> [String] {
    ChatArtifactResolution.extractInlineMediaReferences(from: text, serverURL: serverURL).map { reference in
        switch reference.segment.kind {
        case let .artifact(item):
            return item.title
        case let .image(url):
            return url
        default:
            return reference.segment.content
        }
    }
}
#endif
