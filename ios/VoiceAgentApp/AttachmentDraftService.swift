import Foundation
import UniformTypeIdentifiers

struct AttachmentDraftPolicy {
    static let defaultMaxAttachmentBytes: Int64 = 25 * 1024 * 1024
    static let defaultMaxAudioBytes: Int64 = 20 * 1024 * 1024

    let maxAttachmentBytes: Int64
    let maxAudioBytes: Int64

    static let `default` = AttachmentDraftPolicy(
        maxAttachmentBytes: defaultMaxAttachmentBytes,
        maxAudioBytes: defaultMaxAudioBytes
    )
}

enum AttachmentDraftValidationError: Error, LocalizedError, Equatable {
    case emptyFile(fileName: String)
    case fileTooLarge(fileName: String, sizeBytes: Int64, maxBytes: Int64)
    case unsupportedFileType(fileName: String, mimeType: String)
    case missingFile(fileName: String)

    var errorDescription: String? {
        switch self {
        case let .emptyFile(fileName):
            return "\(fileName) is empty. Remove it or choose a file with content."
        case let .fileTooLarge(fileName, sizeBytes, maxBytes):
            return "\(fileName) is \(humanReadableAttachmentSize(sizeBytes)). Attachments must be \(humanReadableAttachmentSize(maxBytes)) or smaller."
        case let .unsupportedFileType(fileName, mimeType):
            return "\(fileName) uses unsupported type \(mimeType). Choose an image, text, PDF, archive, or plain file export."
        case let .missingFile(fileName):
            return "\(fileName) is no longer available. Remove it and attach the file again."
        }
    }
}

struct AttachmentDraftService {
    let draftDirectory: URL
    var policy: AttachmentDraftPolicy = .default

    func stageImportedAttachment(from sourceURL: URL) throws -> DraftAttachment {
        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = sourceURL.lastPathComponent.isEmpty ? "attachment" : sourceURL.lastPathComponent
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        let mimeType = resourceValues?.contentType?.preferredMIMEType
        if resourceValues?.isRegularFile == false {
            throw AttachmentDraftValidationError.unsupportedFileType(
                fileName: fileName,
                mimeType: mimeType ?? "folder"
            )
        }
        if let size = resourceValues?.fileSize {
            try validateFile(fileName: fileName, mimeType: mimeType, sizeBytes: Int64(size))
        }

        let data = try Data(contentsOf: sourceURL)
        return try stageAttachmentData(data, fileName: fileName, mimeType: mimeType)
    }

    func stageAttachmentData(_ data: Data, fileName: String, mimeType: String?) throws -> DraftAttachment {
        try validateFile(fileName: fileName, mimeType: mimeType, sizeBytes: Int64(data.count))
        try FileManager.default.createDirectory(
            at: draftDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let safeName = sanitizeAttachmentFileName(fileName)
        let targetURL = draftDirectory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        try data.write(to: targetURL, options: .atomic)
        let resolvedMimeType = inferAttachmentMimeType(fileName: safeName, fallback: mimeType)
        return DraftAttachment(
            id: UUID(),
            localFileURL: targetURL,
            fileName: safeName,
            mimeType: resolvedMimeType,
            kind: inferAttachmentKind(fileName: safeName, mimeType: resolvedMimeType),
            sizeBytes: Int64(data.count)
        )
    }

    func validateAttachmentsForSend(_ attachments: [DraftAttachment]) throws {
        for attachment in attachments {
            guard FileManager.default.fileExists(atPath: attachment.localFileURL.path) else {
                throw AttachmentDraftValidationError.missingFile(fileName: attachment.fileName)
            }
            try validateFile(
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes
            )
        }
    }

    func validateAudioFileForUpload(_ fileURL: URL) throws {
        let fileName = fileURL.lastPathComponent.isEmpty ? "audio.m4a" : fileURL.lastPathComponent
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let sizeBytes = values?.fileSize.map(Int64.init) else {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                throw AttachmentDraftValidationError.missingFile(fileName: fileName)
            }
            return
        }
        guard sizeBytes > 0 else {
            throw AttachmentDraftValidationError.emptyFile(fileName: fileName)
        }
        guard sizeBytes <= policy.maxAudioBytes else {
            throw AttachmentDraftValidationError.fileTooLarge(
                fileName: fileName,
                sizeBytes: sizeBytes,
                maxBytes: policy.maxAudioBytes
            )
        }
    }

    func summaryText(for attachments: [DraftAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        let totalBytes = attachments.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let kindSummary = summarizedKinds(for: attachments)
        let fileCount = attachments.count == 1 ? "1 file" : "\(attachments.count) files"
        return "\(fileCount) • \(humanReadableAttachmentSize(totalBytes)) • \(kindSummary)"
    }

    private func validateFile(fileName: String, mimeType: String?, sizeBytes: Int64) throws {
        guard sizeBytes > 0 else {
            throw AttachmentDraftValidationError.emptyFile(fileName: displayName(fileName))
        }
        guard sizeBytes <= policy.maxAttachmentBytes else {
            throw AttachmentDraftValidationError.fileTooLarge(
                fileName: displayName(fileName),
                sizeBytes: sizeBytes,
                maxBytes: policy.maxAttachmentBytes
            )
        }

        let resolvedMimeType = inferAttachmentMimeType(fileName: fileName, fallback: mimeType)
        guard isSupportedAttachmentType(fileName: fileName, mimeType: resolvedMimeType) else {
            throw AttachmentDraftValidationError.unsupportedFileType(
                fileName: displayName(fileName),
                mimeType: resolvedMimeType
            )
        }
    }

    private func isSupportedAttachmentType(fileName: String, mimeType: String) -> Bool {
        let lowerMime = mimeType.lowercased()
        guard !lowerMime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if lowerMime.hasPrefix("image/") || lowerMime.hasPrefix("text/") {
            return true
        }
        if [
            "application/json",
            "application/pdf",
            "application/rtf",
            "application/xml",
            "application/yaml",
            "application/x-yaml",
            "application/zip",
            "application/x-zip-compressed",
            "application/octet-stream"
        ].contains(lowerMime) {
            return true
        }

        return inferAttachmentKind(fileName: fileName, mimeType: mimeType) == .code || lowerMime.contains("/")
    }

    private func summarizedKinds(for attachments: [DraftAttachment]) -> String {
        let kinds = Set(attachments.map(\.kind))
        if kinds.count == 1, let kind = kinds.first {
            switch kind {
            case .image:
                return attachments.count == 1 ? "Image" : "Images"
            case .code:
                return attachments.count == 1 ? "Code/text" : "Code/text"
            case .file:
                return attachments.count == 1 ? "File" : "Files"
            }
        }
        return "Mixed"
    }

    private func displayName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Attachment" : trimmed
    }

    private func sanitizeAttachmentFileName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let final = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return final.isEmpty ? "attachment" : final
    }
}
