import Foundation
import UniformTypeIdentifiers

struct DraftAttachment: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case image
        case code
        case file
    }

    let id: UUID
    let localFileURL: URL
    let fileName: String
    let mimeType: String
    let kind: Kind
    let sizeBytes: Int64

    var isImage: Bool {
        kind == .image
    }
}

enum DraftAttachmentTransferState: Equatable {
    case idle
    case uploading(progress: Double)
    case failed(message: String)

    var progressValue: Double? {
        if case let .uploading(progress) = self {
            return progress
        }
        return nil
    }

    var failureMessage: String? {
        if case let .failed(message) = self {
            return message
        }
        return nil
    }

    var isUploading: Bool {
        if case .uploading = self {
            return true
        }
        return false
    }
}

func inferAttachmentMimeType(fileName: String, fallback: String? = nil) -> String {
    if let fallback {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty {
            return trimmedFallback
        }
    }
    let ext = URL(fileURLWithPath: fileName).pathExtension
    if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
        return mime
    }
    if let mime = attachmentMimeTypeByExtension[ext.lowercased()] {
        return mime
    }
    return "application/octet-stream"
}

func inferAttachmentKind(fileName: String, mimeType: String) -> DraftAttachment.Kind {
    let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    if attachmentImageExtensions.contains(ext) {
        return .image
    }
    if attachmentCodeExtensions.contains(ext) {
        return .code
    }

    let lowerMime = mimeType.lowercased()
    if lowerMime.hasPrefix("image/") {
        return .image
    }
    if lowerMime.hasPrefix("text/") {
        return .code
    }
    return .file
}

private let attachmentImageExtensions: Set<String> = [
    "gif",
    "heic",
    "heif",
    "jpeg",
    "jpg",
    "png",
    "svg",
    "webp",
]

private let attachmentCodeExtensions: Set<String> = [
    "c",
    "cc",
    "cpp",
    "css",
    "csv",
    "go",
    "h",
    "hpp",
    "htm",
    "html",
    "java",
    "js",
    "json",
    "jsonl",
    "kt",
    "log",
    "markdown",
    "md",
    "mdown",
    "mdtext",
    "mdwn",
    "mkd",
    "mjs",
    "ndjson",
    "php",
    "py",
    "rb",
    "rs",
    "sh",
    "sql",
    "swift",
    "toml",
    "ts",
    "tsv",
    "tsx",
    "txt",
    "xml",
    "yaml",
    "yml",
]

private let attachmentMimeTypeByExtension: [String: String] = [
    "csv": "text/csv",
    "heic": "image/heic",
    "heif": "image/heif",
    "jsonl": "application/x-ndjson",
    "log": "text/plain",
    "markdown": "text/markdown",
    "md": "text/markdown",
    "mdown": "text/markdown",
    "mdtext": "text/markdown",
    "mdwn": "text/markdown",
    "mkd": "text/markdown",
    "ndjson": "application/x-ndjson",
    "pdf": "application/pdf",
    "svg": "image/svg+xml",
    "tsv": "text/tab-separated-values",
]

func humanReadableAttachmentSize(_ sizeBytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: sizeBytes)
}
