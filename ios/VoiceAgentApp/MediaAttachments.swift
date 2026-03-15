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
    if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return fallback
    }
    let ext = URL(fileURLWithPath: fileName).pathExtension
    if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
        return mime
    }
    return "application/octet-stream"
}

func inferAttachmentKind(fileName: String, mimeType: String) -> DraftAttachment.Kind {
    let lowerMime = mimeType.lowercased()
    if lowerMime.hasPrefix("image/") {
        return .image
    }
    if lowerMime.hasPrefix("text/") {
        return .code
    }

    let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    if [
        "c",
        "cc",
        "cpp",
        "css",
        "go",
        "h",
        "hpp",
        "html",
        "java",
        "js",
        "json",
        "kt",
        "md",
        "mjs",
        "php",
        "py",
        "rb",
        "rs",
        "sh",
        "sql",
        "swift",
        "toml",
        "ts",
        "tsx",
        "txt",
        "xml",
        "yaml",
        "yml"
    ].contains(ext) {
        return .code
    }
    return .file
}

func humanReadableAttachmentSize(_ sizeBytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: sizeBytes)
}
