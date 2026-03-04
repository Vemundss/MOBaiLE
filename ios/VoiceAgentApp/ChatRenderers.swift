import Foundation
import QuickLook
import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: ConversationMessage
    let serverURL: String
    let apiToken: String
    @State private var artifactOpenError: String = ""
    @State private var openingArtifactID: String?
    @State private var previewDocument: PreviewDocument?
    private let client = APIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .markdown:
                    MarkdownText(text: segment.content, isUser: isUser)
                case .code:
                    CodeBlock(text: segment.content)
                case let .status(text):
                    AgentStatusCard(text: text)
                case let .image(url):
                    RemoteImageView(urlString: url, serverURL: serverURL, apiToken: apiToken)
                case let .section(title, body):
                    SectionCard(title: title, content: body, isUser: isUser)
                case let .artifact(item):
                    ArtifactCard(
                        artifact: item,
                        serverURL: serverURL,
                        isOpening: openingArtifactID == item.id,
                        onOpen: {
                            Task {
                                await openArtifact(item)
                            }
                        }
                    )
                case let .agenda(items):
                    AgendaCard(items: items)
                case let .emailDigest(items):
                    EmailDigestCard(items: items)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .foregroundStyle(isUser ? Color.white : Color.primary)
        .background(
            isUser
                ? Color.blue
                : Color(.secondarySystemBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .alert("Open failed", isPresented: Binding(
            get: { !artifactOpenError.isEmpty },
            set: { if !$0 { artifactOpenError = "" } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(artifactOpenError)
        }
        .sheet(item: $previewDocument) { preview in
            QuickLookPreview(url: preview.url)
        }
    }

    private var isUser: Bool {
        message.role == "user"
    }

    private var segments: [MessageSegment] {
        parseSegments(from: message.text, serverURL: serverURL, massageForDisplay: !isUser)
    }

    private func openArtifact(_ artifact: ChatArtifact) async {
        openingArtifactID = artifact.id
        defer { openingArtifactID = nil }

        if let rawURL = artifact.url,
           let parsed = URL(string: rawURL),
           !isBackendProtectedURL(parsed) {
            await MainActor.run {
                UIApplication.shared.open(parsed)
            }
            return
        }

        do {
            let localURL = try await client.downloadArtifactToTemporaryFile(
                serverURL: serverURL,
                token: apiToken,
                artifact: artifact
            )
            await MainActor.run {
                previewDocument = PreviewDocument(url: localURL)
            }
        } catch {
            await MainActor.run {
                artifactOpenError = error.localizedDescription
            }
        }
    }

    private func isBackendProtectedURL(_ url: URL) -> Bool {
        guard let backend = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            return false
        }
        return url.host == backend.host &&
            (url.port ?? defaultPort(for: url.scheme)) == (backend.port ?? defaultPort(for: backend.scheme)) &&
            url.scheme == backend.scheme &&
            url.path.hasPrefix("/v1/")
    }

    private func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https":
            return 443
        default:
            return 80
        }
    }
}

private struct MarkdownText: View {
    let text: String
    let isUser: Bool

    var body: some View {
        if shouldRenderAsMarkdown(text),
           let rendered = try? AttributedString(
               markdown: text,
               options: AttributedString.MarkdownParsingOptions(
                   interpretedSyntax: .full,
                   failurePolicy: .returnPartiallyParsedIfPossible
               )
           ) {
            Text(rendered)
                .font(.body)
                .lineSpacing(1.5)
                .foregroundStyle(isUser ? Color.white : Color.primary)
        } else {
            Text(verbatim: text)
                .font(.body)
                .lineSpacing(1.5)
                .foregroundStyle(isUser ? Color.white : Color.primary)
        }
    }
}

private func shouldRenderAsMarkdown(_ text: String) -> Bool {
    if text.contains("```") || text.contains("](") || text.contains("![") {
        return true
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
            return true
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return true
        }
        if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
            return true
        }
    }
    return false
}

private struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .foregroundStyle(Color(red: 0.86, green: 0.91, blue: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SectionCard: View {
    let title: String
    let content: String
    let isUser: Bool
    @State private var expanded = false

    var body: some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLong = trimmed.count > 280 || trimmed.contains("\n\n")
        let style = sectionStyle
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: style.icon)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isUser ? Color.white.opacity(0.9) : style.tint)
            if isLong {
                DisclosureGroup(expanded ? "Hide details" : "Show details", isExpanded: $expanded) {
                    MarkdownText(text: trimmed, isUser: isUser)
                }
                .font(.footnote)
            } else {
                MarkdownText(text: trimmed, isUser: isUser)
            }
        }
        .padding(10)
        .background(isUser ? Color.white.opacity(0.08) : style.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sectionStyle: (icon: String, tint: Color, background: Color) {
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "what i did":
            return ("wrench.and.screwdriver", Color.gray, Color(.tertiarySystemBackground))
        case "result", "output":
            return ("checkmark.circle", Color.green, Color(red: 0.90, green: 0.97, blue: 0.92))
        case "next step":
            return ("arrow.right.circle", Color.blue, Color(red: 0.90, green: 0.95, blue: 1.0))
        default:
            return ("text.alignleft", Color.secondary, Color(.tertiarySystemBackground))
        }
    }
}

private struct AgentStatusCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.top, 2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ArtifactCard: View {
    let artifact: ChatArtifact
    let serverURL: String
    let isOpening: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = subtitleText, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if resolvedURL != nil {
                Button {
                    onOpen()
                } label: {
                    if isOpening {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Open")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isOpening)
            } else {
                Text("N/A")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var iconName: String {
        switch artifact.type.lowercased() {
        case "image":
            return "photo"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }

    private var subtitleText: String? {
        artifact.path ?? artifact.url ?? artifact.mime
    }

    private var resolvedURL: URL? {
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
}

private struct PreviewDocument: Identifiable {
    let id = UUID()
    let url: URL
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct MessageSegment: Identifiable {
    enum Kind {
        case markdown
        case code
        case status(text: String)
        case image(url: String)
        case section(title: String, body: String)
        case artifact(item: ChatArtifact)
        case agenda(items: [ChatAgendaItem])
        case emailDigest(items: [EmailDigestItem])
    }

    let id = UUID()
    let kind: Kind
    let content: String
}

private struct EmailDigestItem: Identifiable {
    let id = UUID()
    let receivedAt: String
    let subject: String
    let sender: String?
}

private func parseSegments(from text: String, serverURL: String, massageForDisplay: Bool = true) -> [MessageSegment] {
    var segments: [MessageSegment] = []

    if let envelope = parseChatEnvelope(from: text) {
        let summaryRaw = massageForDisplay ? massageAssistantTextForDisplay(envelope.summary) : envelope.summary
        let summary = summaryRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSectionRaw = envelope.sections.first?.body ?? ""
        let firstSectionBody = (massageForDisplay ? massageAssistantTextForDisplay(firstSectionRaw) : firstSectionRaw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty,
           summary.lowercased() != "run completed successfully",
           summary != firstSectionBody {
            if looksLikeAgentStatus(summary) {
                segments.append(MessageSegment(kind: .status(text: summary), content: summary))
            } else {
                segments.append(MessageSegment(kind: .markdown, content: summary))
            }
        }
        for section in envelope.sections {
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || isContextLeakLine(title) {
                continue
            }
            let bodyRaw = massageForDisplay ? massageAssistantTextForDisplay(section.body) : section.body
            let body = bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                continue
            }
            let specialized = parseSpecializedSectionSegments(title: title, body: body)
            if !specialized.isEmpty {
                segments.append(contentsOf: specialized)
                continue
            }
            if title.lowercased() == "result", looksLikeAgentStatus(body) {
                segments.append(MessageSegment(kind: .status(text: body), content: body))
                continue
            }
            segments.append(MessageSegment(kind: .section(title: title, body: body), content: body))
        }
        for artifact in envelope.artifacts {
            if artifact.type.lowercased() == "image",
               let raw = artifact.url ?? artifact.path,
               let url = resolveImageURL(from: raw, serverURL: serverURL) {
                segments.append(MessageSegment(kind: .image(url: url), content: url))
                continue
            }
            segments.append(MessageSegment(kind: .artifact(item: artifact), content: artifact.title))
        }
        if !envelope.agendaItems.isEmpty {
            segments.append(MessageSegment(kind: .agenda(items: envelope.agendaItems), content: "agenda"))
        }
        return segments
    }

    var remaining = massageForDisplay ? massageAssistantTextForDisplay(text) : text

    if let imageURL = extractImageURL(from: remaining, serverURL: serverURL) {
        remaining = removeImageMarkdown(from: remaining)
        segments.append(MessageSegment(kind: .image(url: imageURL), content: imageURL))
    }

    if let agendaItems = parseAgendaItemsLoosely(from: remaining), !agendaItems.isEmpty {
        let nonAgenda = stripAgendaLines(from: remaining)
        if !nonAgenda.isEmpty {
            if looksLikeAgentStatus(nonAgenda) {
                segments.append(MessageSegment(kind: .status(text: nonAgenda), content: nonAgenda))
            } else {
                segments.append(MessageSegment(kind: .markdown, content: nonAgenda))
            }
        }
        segments.append(MessageSegment(kind: .agenda(items: agendaItems), content: "agenda"))
        return segments
    }

    if let emails = parseEmailDigestItems(from: remaining), !emails.isEmpty {
        let nonEmail = stripEmailDigestLines(from: remaining)
        if !nonEmail.isEmpty {
            if looksLikeAgentStatus(nonEmail) {
                segments.append(MessageSegment(kind: .status(text: nonEmail), content: nonEmail))
            } else {
                segments.append(MessageSegment(kind: .markdown, content: nonEmail))
            }
        }
        segments.append(MessageSegment(kind: .emailDigest(items: emails), content: "emails"))
        return segments
    }

    var remainingSlice = remaining[...]

    while let open = remainingSlice.range(of: "```") {
        let before = String(remainingSlice[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty {
            segments.append(MessageSegment(kind: .markdown, content: before))
        }

        let afterOpen = remainingSlice[open.upperBound...]
        guard let close = afterOpen.range(of: "```") else {
            let tail = String(remainingSlice).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                segments.append(MessageSegment(kind: .markdown, content: tail))
            }
            return segments
        }

        var code = String(afterOpen[..<close.lowerBound])
        if let firstNewline = code.firstIndex(of: "\n") {
            let firstLine = code[..<firstNewline]
            if !firstLine.contains(" ") && firstLine.count <= 20 {
                code = String(code[code.index(after: firstNewline)...])
            }
        }
        code = code.trimmingCharacters(in: .newlines)
        if !code.isEmpty {
            segments.append(MessageSegment(kind: .code, content: code))
        }

        remainingSlice = afterOpen[close.upperBound...]
    }

    let tail = String(remainingSlice).trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty {
        segments.append(MessageSegment(kind: .markdown, content: tail))
    }
    return segments
}

private func parseSpecializedSectionSegments(title: String, body: String) -> [MessageSegment] {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedTitle == "result" || normalizedTitle == "output" else {
        return []
    }

    if let agenda = parseAgendaItemsLoosely(from: body), !agenda.isEmpty {
        var segments: [MessageSegment] = []
        let preface = stripAgendaLines(from: body)
        if !preface.isEmpty {
            if looksLikeAgentStatus(preface) {
                segments.append(MessageSegment(kind: .status(text: preface), content: preface))
            } else {
                segments.append(MessageSegment(kind: .section(title: title, body: preface), content: preface))
            }
        }
        segments.append(MessageSegment(kind: .agenda(items: agenda), content: "agenda"))
        return segments
    }

    if let emails = parseEmailDigestItems(from: body), !emails.isEmpty {
        var segments: [MessageSegment] = []
        let preface = stripEmailDigestLines(from: body)
        if !preface.isEmpty {
            if looksLikeAgentStatus(preface) {
                segments.append(MessageSegment(kind: .status(text: preface), content: preface))
            } else {
                segments.append(MessageSegment(kind: .section(title: title, body: preface), content: preface))
            }
        }
        segments.append(MessageSegment(kind: .emailDigest(items: emails), content: "emails"))
        return segments
    }

    return []
}

private func massageAssistantTextForDisplay(_ text: String) -> String {
    var out = text.replacingOccurrences(of: "\r\n", with: "\n")
    out = out.replacingOccurrences(of: "\r", with: "\n")
    out = out.replacingOccurrences(of: "\t", with: "    ")
    out = stripContextLeakLines(out)
    out = normalizeCommonSectionHeadings(out)
    return collapseNewlines(out).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseChatEnvelope(from text: String) -> ChatEnvelope? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let direct = decodeChatEnvelopeJSON(trimmed) {
        return direct
    }
    if trimmed.contains("\\\"") {
        let unescaped = trimmed
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
        if let recovered = decodeChatEnvelopeJSON(unescaped) {
            return recovered
        }
    }
    if let unescaped = decodeJSONStringLiteral(trimmed),
       let fromLiteral = decodeChatEnvelopeJSON(unescaped) {
        return fromLiteral
    }

    if let start = trimmed.firstIndex(of: "{"),
       let end = trimmed.lastIndex(of: "}"),
       start < end {
        let rangeSlice = String(trimmed[start...end])
        if let embedded = decodeChatEnvelopeJSON(rangeSlice) {
            return embedded
        }
        if rangeSlice.contains("\\\"") {
            let unescaped = rangeSlice
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
            if let recovered = decodeChatEnvelopeJSON(unescaped) {
                return recovered
            }
        }
        if let unescaped = decodeJSONStringLiteral(rangeSlice),
           let embeddedLiteral = decodeChatEnvelopeJSON(unescaped) {
            return embeddedLiteral
        }
    }
    return nil
}

private func parseAgendaItems(from text: String) -> [ChatAgendaItem]? {
    let lines = text.split(separator: "\n").map(String.init)
    var items: [ChatAgendaItem] = []
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^-?\s*\d{2}:\d{2}\s*[\-–]\s*\d{2}:\d{2}\s*\|"#, options: .regularExpression) != nil else {
            continue
        }
        let stripped = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
        let parts = stripped.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            let times = parts[0].split(whereSeparator: { $0 == "-" || $0 == "–" }).map { $0.trimmingCharacters(in: .whitespaces) }
            let start = times.first ?? ""
            let end = times.count > 1 ? times[1] : ""
            items.append(
                ChatAgendaItem(
                    start: start,
                    end: end,
                    title: parts[1],
                    calendar: parts[2],
                    location: parts.count > 3 ? parts[3] : nil
                )
            )
        }
    }
    return items.isEmpty ? nil : items
}

private func parseAgendaItemsLoosely(from text: String) -> [ChatAgendaItem]? {
    parseAgendaItems(from: normalizeCalendarListText(text))
}

private func normalizeCalendarListText(_ text: String) -> String {
    var out = text
    out = regexReplace(
        out,
        pattern: #"(?<!^)(\d{2}:\d{2}\s*[\-–]\s*\d{2}:\d{2}\s*\|)"#,
        with: "\n$1"
    )
    out = regexReplace(
        out,
        pattern: #"(?m)(Today\s*\([^)]+\)\s*:)\s*(\d{2}:\d{2})"#,
        with: "$1\n$2"
    )
    return out
}

private func stripAgendaLines(from text: String) -> String {
    let normalized = normalizeCalendarListText(text)
    let kept = normalized
        .split(separator: "\n")
        .map(String.init)
        .filter { line in
            line.range(of: #"^\s*-?\s*\d{2}:\d{2}\s*[\-–]\s*\d{2}:\d{2}\s*\|"#, options: .regularExpression) == nil
        }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseEmailDigestItems(from text: String) -> [EmailDigestItem]? {
    let normalized = normalizeEmailListText(text)
    var items: [EmailDigestItem] = []
    for line in normalized.split(separator: "\n").map(String.init) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s*\|"#, options: .regularExpression) != nil else {
            continue
        }
        let parts = trimmed
            .split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2 else { continue }
        let sender = parts.count >= 3 ? parts[2] : nil
        items.append(
            EmailDigestItem(
                receivedAt: parts[0],
                subject: parts[1],
                sender: sender
            )
        )
    }
    return items.isEmpty ? nil : items
}

private func normalizeEmailListText(_ text: String) -> String {
    regexReplace(
        text,
        pattern: #"(?<!^)(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s*\|)"#,
        with: "\n$1"
    )
}

private func stripEmailDigestLines(from text: String) -> String {
    let normalized = normalizeEmailListText(text)
    let kept = normalized
        .split(separator: "\n")
        .map(String.init)
        .filter { line in
            line.range(of: #"^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s*\|"#, options: .regularExpression) == nil
        }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func looksLikeAgentStatus(_ text: String) -> Bool {
    let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !lower.isEmpty else { return false }
    if lower.contains("run completed successfully") || lower.contains("run failed") {
        return false
    }
    if lower.contains("```") {
        return false
    }
    let progressMarkers = [
        "checking ",
        "querying ",
        "pulling ",
        "reading ",
        "fetching ",
        "reformatting ",
        "processing ",
        "running ",
        "trying ",
        "retrying ",
        "i'll ",
        "i will ",
        "i'm ",
        "working on",
    ]
    return progressMarkers.contains { lower.contains($0) }
}

private struct AgendaCard: View {
    let items: [ChatAgendaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text("Calendar")
            }
            .font(.subheadline.weight(.semibold))
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.start + "-" + item.end)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.body.weight(.medium))
                    Text(item.calendar + (item.location.map { " • \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .background(Color(red: 0.92, green: 0.97, blue: 0.93))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EmailDigestCard: View {
    let items: [EmailDigestItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                Text("Unread Mail")
            }
            .font(.subheadline.weight(.semibold))

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.subject)
                        .font(.subheadline.weight(.semibold))
                    Text(item.receivedAt + (item.sender.map { " • \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .background(Color(red: 0.94, green: 0.95, blue: 1.0))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RemoteImageView: View {
    let urlString: String
    let serverURL: String
    let apiToken: String

    private let client = APIClient()
    @State private var loadedImage: Image?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var failureMessage = "Image failed to load"

    var body: some View {
        Group {
            if let image = loadedImage {
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if isLoading {
                ProgressView()
            } else if didFail {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxHeight: 260)
        .task(id: urlString) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url = URL(string: urlString) else {
            failureMessage = "Invalid image URL."
            didFail = true
            return
        }
        isLoading = true
        didFail = false
        failureMessage = "Image failed to load"
        do {
            let data = try await client.fetchURLData(
                serverURL: serverURL,
                token: apiToken,
                url: url,
                timeout: 20
            )
            guard let uiImage = UIImage(data: data) else {
                failureMessage = "Downloaded file is not a valid image."
                didFail = true
                isLoading = false
                return
            }
            loadedImage = Image(uiImage: uiImage)
            isLoading = false
        } catch let apiError as APIError {
            switch apiError {
            case let .httpError(code, body):
                let lower = body.lowercased()
                if code == 403 && lower.contains("outside allowed roots") {
                    failureMessage = "Image blocked by safe mode: file is outside allowed roots."
                } else if code == 403 {
                    failureMessage = "Image access denied by backend."
                } else if code == 404 {
                    failureMessage = "Image file not found on backend."
                } else {
                    failureMessage = "Image failed to load (HTTP \(code))."
                }
            default:
                failureMessage = apiError.localizedDescription
            }
            didFail = true
            isLoading = false
        } catch {
            failureMessage = error.localizedDescription
            didFail = true
            isLoading = false
        }
    }
}

private func extractImageURL(from text: String, serverURL: String) -> String? {
    let pattern = #"\!\[[^\]]*\]\(([^)]+)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsRange = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    return resolveImageURL(from: raw, serverURL: serverURL)
}

private func removeImageMarkdown(from text: String) -> String {
    let pattern = #"\!\[[^\]]*\]\([^)]+\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func resolveImageURL(from raw: String, serverURL: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.contains("path/to/") || lower.contains("absolute/path") {
        return nil
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed
    }
    let imagePath = extractImagePath(from: trimmed)
    guard let encoded = imagePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
        return nil
    }
    let normalizedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return "\(normalizedServer)/v1/files?path=\(encoded)"
}

private func extractImagePath(from text: String) -> String {
    let stripped = text
        .trimmingCharacters(in: CharacterSet(charactersIn: "`'\" "))
        .replacingOccurrences(of: "file://", with: "")
    let absolutePattern = #"/[^\s`'\"()]+?\.(?:png|jpg|jpeg|gif|webp)"#
    if let regex = try? NSRegularExpression(pattern: absolutePattern, options: [.caseInsensitive]) {
        let range = NSRange(stripped.startIndex..., in: stripped)
        if let match = regex.firstMatch(in: stripped, options: [], range: range),
           let pathRange = Range(match.range, in: stripped) {
            return String(stripped[pathRange])
        }
    }

    let relativePattern = #"[^\s`'\"()]+?\.(?:png|jpg|jpeg|gif|webp)"#
    if let regex = try? NSRegularExpression(pattern: relativePattern, options: [.caseInsensitive]) {
        let range = NSRange(stripped.startIndex..., in: stripped)
        if let match = regex.firstMatch(in: stripped, options: [], range: range),
           let pathRange = Range(match.range, in: stripped) {
            return String(stripped[pathRange])
        }
    }
    return stripped
}

private func decodeChatEnvelopeJSON(_ value: String) -> ChatEnvelope? {
    guard let data = value.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ChatEnvelope.self, from: data)
}

private func decodeJSONStringLiteral(_ value: String) -> String? {
    guard value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
    guard let data = value.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(String.self, from: data) else {
        return nil
    }
    return decoded
}

private func normalizeCommonSectionHeadings(_ text: String) -> String {
    var out = text
    out = regexReplace(
        out,
        pattern: #"(?m)(What I Did|Result|Next Step|Output)\s*:?\s*([A-Z])"#,
        with: "$1\n$2"
    )
    out = regexReplace(
        out,
        pattern: #"(?m)^(What I Did|Result|Next Step|Output)\s*:\s*(.+)$"#,
        with: "## $1\n$2"
    )
    out = regexReplace(
        out,
        pattern: #"(?m)^(What I Did|Result|Next Step|Output)\s*:?\s*$"#,
        with: "## $1"
    )
    return out
}

private func stripContextLeakLines(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let filtered = lines.filter { !isContextLeakLine(String($0)) }
    return filtered.joined(separator: "\n")
}

private func isContextLeakLine(_ line: String) -> Bool {
    let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !lower.isEmpty else { return false }
    let markers = [
        "you are the coding agent used by mobaile",
        "you run on the user's server/computer",
        "your stdout is streamed to a phone ui",
        "keep responses concise and grouped",
        "avoid verbose step-by-step chatter",
        "mobaile runtime context",
        "runtime:",
        "product intent:",
        "mobaile makes a user's computer available from their phone",
        "output style for phone ux:",
        "task-specific formatting:",
        "environment notes:",
        "do not repeat or summarize this runtime context",
    ]
    return markers.contains { lower.contains($0) }
}

private func collapseNewlines(_ text: String) -> String {
    var out = text
    while out.contains("\n\n\n") {
        out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return out
}

private func regexReplace(
    _ input: String,
    pattern: String,
    with template: String,
    options: NSRegularExpression.Options = []
) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return input
    }
    let range = NSRange(input.startIndex..., in: input)
    return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
}
