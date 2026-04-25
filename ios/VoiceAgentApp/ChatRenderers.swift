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
        bubbleSurface
        .contextMenu {
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy message", systemImage: "doc.on.doc")
                }
            }
        }
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

    private var isLiveActivity: Bool {
        message.presentation == .liveActivity
    }

    private var segments: [MessageSegment] {
        let parsed = parseSegments(from: message.text, serverURL: serverURL, massageForDisplay: !isUser)
        let explicitAttachments = message.attachments.map { artifact in
            ChatArtifactResolution.messageSegment(for: artifact, serverURL: serverURL)
        }
        guard !explicitAttachments.isEmpty else { return parsed }
        if parsed.isEmpty {
            return explicitAttachments
        }
        return parsed + explicitAttachments
    }

    @ViewBuilder
    private var bubbleSurface: some View {
        if isLiveActivity {
            LiveActivityCard(text: message.text)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(segments) { segment in
                    switch segment.kind {
                    case .markdown:
                        ExpandableMarkdownBlock(text: segment.content, isUser: isUser)
                    case let .code(language):
                        CodeBlock(text: segment.content, language: language)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        isUser
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.17, green: 0.48, blue: 0.96),
                                        Color(red: 0.12, green: 0.39, blue: 0.90)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color(.systemBackground))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isUser ? Color.white.opacity(0.14) : Color(.separator).opacity(0.18),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isUser ? Color.clear : Color.black.opacity(0.04),
                radius: isUser ? 0 : 10,
                y: isUser ? 0 : 3
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func openArtifact(_ artifact: ChatArtifact) async {
        openingArtifactID = artifact.id
        defer { openingArtifactID = nil }

        if let rawURL = artifact.url,
           let parsed = URL(string: rawURL),
           !ChatArtifactResolution.isProtectedBackendURL(parsed, serverURL: serverURL) {
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
}

private struct MarkdownText: View {
    let text: String
    let isUser: Bool

    var body: some View {
        Group {
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
        .textSelection(.enabled)
    }
}

private struct ExpandableMarkdownBlock: View {
    let text: String
    let isUser: Bool
    @State private var expanded: Bool

    init(text: String, isUser: Bool) {
        self.text = text
        self.isUser = isUser
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        _expanded = State(initialValue: !Self.shouldCollapse(trimmed, isUser: isUser))
    }

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.shouldCollapse(trimmed, isUser: isUser) {
            VStack(alignment: .leading, spacing: 10) {
                if expanded {
                    MarkdownText(text: trimmed, isUser: isUser)
                } else {
                    Text(collapsedPreviewText(from: trimmed))
                        .font(.body)
                        .lineSpacing(1.5)
                        .foregroundStyle(isUser ? Color.white : Color.primary)
                        .textSelection(.enabled)
                }

                Button(expanded ? "Show less" : "Show full response") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isUser ? Color.white.opacity(0.92) : Color.blue)
            }
        } else {
            MarkdownText(text: trimmed, isUser: isUser)
        }
    }

    private static func shouldCollapse(_ text: String, isUser: Bool) -> Bool {
        guard !isUser else { return false }
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.count > 900 || lineCount > 16
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

private func collapsedPreviewText(from text: String, limit: Int = 240) -> String {
    let normalized: String
    if let rendered = try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    ) {
        normalized = String(rendered.characters)
    } else {
        normalized = text
    }

    let collapsed = normalized
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")

    guard collapsed.count > limit else { return collapsed }
    let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
    return String(collapsed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}

private struct CodeBlock: View {
    let text: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
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
    @State private var expanded: Bool

    init(title: String, content: String, isUser: Bool) {
        self.title = title
        self.content = content
        self.isUser = isUser

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isLong = trimmed.count > 280 || trimmed.contains("\n\n")
        _expanded = State(initialValue: Self.defaultExpanded(for: lower, isLong: isLong))
    }

    var body: some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLong = trimmed.count > 280 || trimmed.contains("\n\n")
        let style = sectionStyle
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: style.icon)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isUser ? Color.white.opacity(0.9) : style.tint)
            if isLong {
                VStack(alignment: .leading, spacing: 8) {
                    if expanded {
                        MarkdownText(text: trimmed, isUser: isUser)
                    } else {
                        Text(collapsedPreviewText(from: trimmed, limit: 180))
                            .font(.subheadline)
                            .foregroundStyle(isUser ? Color.white.opacity(0.92) : Color.primary.opacity(0.84))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(expanded ? "Hide details" : "Show details") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isUser ? Color.white.opacity(0.9) : style.tint)
                }
            } else {
                MarkdownText(text: trimmed, isUser: isUser)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isUser ? Color.white.opacity(0.08) : Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isUser ? Color.white.opacity(0.08) : style.tint.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static func defaultExpanded(for title: String, isLong: Bool) -> Bool {
        guard isLong else { return true }
        switch title {
        case "result", "output", "next step":
            return true
        default:
            return false
        }
    }

    private var sectionStyle: (icon: String, tint: Color) {
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "what i did":
            return ("wrench.and.screwdriver", Color.gray)
        case "result", "output":
            return ("checkmark.circle", Color.green)
        case "next step":
            return ("arrow.right.circle", Color.blue)
        default:
            return ("text.alignleft", Color.secondary)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(.tertiarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.blue.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LiveActivityCard: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatePulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.18))
                        .frame(width: 18, height: 18)
                        .scaleEffect(reduceMotion ? 1 : (animatePulse ? 1.2 : 0.9))
                        .opacity(reduceMotion ? 1 : (animatePulse ? 0.35 : 0.95))
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
                Text("Live Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .tint(.blue)
            }

            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.blue.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.liveActivity")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                animatePulse = true
            }
        }
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
                if let mime = artifact.mime, !mime.isEmpty {
                    Text(mime)
                        .font(.caption2)
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
        .background(Color(.tertiarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            if let rawReference = artifact.path ?? artifact.url {
                Button {
                    UIPasteboard.general.string = rawReference
                } label: {
                    Label("Copy reference", systemImage: "doc.on.doc")
                }
            }
        }
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
        ChatArtifactResolution.resolvedURL(for: artifact, serverURL: serverURL)
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

struct MessageSegment: Identifiable {
    enum Kind {
        case markdown
        case code(language: String?)
        case status(text: String)
        case image(url: String)
        case section(title: String, body: String)
        case artifact(item: ChatArtifact)
        case agenda(items: [ChatAgendaItem])
        case emailDigest(items: [EmailDigestItem])
    }

    let id: String
    let kind: Kind
    let content: String

    init(kind: Kind, content: String, id: String? = nil) {
        self.kind = kind
        self.content = content
        self.id = id ?? Self.stableIdentity(for: kind, content: content)
    }

    private static func stableIdentity(for kind: Kind, content: String) -> String {
        let kindSeed: String
        switch kind {
        case .markdown:
            kindSeed = "markdown"
        case let .code(language):
            kindSeed = "code:\(language ?? "")"
        case .status:
            kindSeed = "status"
        case let .image(url):
            kindSeed = "image:\(url)"
        case let .section(title, _):
            kindSeed = "section:\(title)"
        case let .artifact(item):
            kindSeed = "artifact:\(item.id)"
        case let .agenda(items):
            kindSeed = "agenda:\(items.map(\.id).joined(separator: "|"))"
        case let .emailDigest(items):
            kindSeed = "email:\(items.map(\.id).joined(separator: "|"))"
        }
        return "\(kindSeed):\(stableHash(content))"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct EmailDigestItem: Identifiable {
    var id: String { "\(receivedAt)|\(subject)|\(sender ?? "")" }
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
            segments.append(ChatArtifactResolution.messageSegment(for: artifact, serverURL: serverURL))
        }
        if !envelope.agendaItems.isEmpty {
            segments.append(MessageSegment(kind: .agenda(items: envelope.agendaItems), content: "agenda"))
        }
        return segmentsWithUniqueStableIDs(segments)
    }

    var remaining = massageForDisplay ? massageAssistantTextForDisplay(text) : text
    var inlineMediaSegments: [MessageSegment] = []

    let inlineMedia = ChatArtifactResolution.extractInlineMediaReferences(from: remaining, serverURL: serverURL)
    if !inlineMedia.isEmpty {
        remaining = ChatArtifactResolution.removingInlineMediaReferences(from: remaining, references: inlineMedia)
        inlineMediaSegments = inlineMedia.map(\.segment)
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
        segments.append(contentsOf: inlineMediaSegments)
        return segmentsWithUniqueStableIDs(segments)
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
        segments.append(contentsOf: inlineMediaSegments)
        return segmentsWithUniqueStableIDs(segments)
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
            segments.append(contentsOf: inlineMediaSegments)
            return segmentsWithUniqueStableIDs(segments)
        }

        var code = String(afterOpen[..<close.lowerBound])
        var language: String?
        if let firstNewline = code.firstIndex(of: "\n") {
            let firstLine = code[..<firstNewline].trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstLine.contains(" "), firstLine.count <= 20 {
                language = firstLine.isEmpty ? nil : String(firstLine)
                code = String(code[code.index(after: firstNewline)...])
            }
        }
        code = code.trimmingCharacters(in: .newlines)
        if !code.isEmpty {
            segments.append(MessageSegment(kind: .code(language: language), content: code))
        }

        remainingSlice = afterOpen[close.upperBound...]
    }

    let tail = String(remainingSlice).trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty {
        segments.append(MessageSegment(kind: .markdown, content: tail))
    }
    segments.append(contentsOf: inlineMediaSegments)
    return segmentsWithUniqueStableIDs(segments)
}

private func segmentsWithUniqueStableIDs(_ segments: [MessageSegment]) -> [MessageSegment] {
    var occurrences: [String: Int] = [:]
    return segments.map { segment in
        let seen = occurrences[segment.id, default: 0]
        occurrences[segment.id] = seen + 1
        guard seen > 0 else { return segment }
        return MessageSegment(kind: segment.kind, content: segment.content, id: "\(segment.id).\(seen + 1)")
    }
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
    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var failureMessage = "Image failed to load"
    @State private var showingPreview = false

    var body: some View {
        Group {
            if let image = loadedImage {
                Button {
                    showingPreview = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                            .padding(10)
                    }
                }
                .buttonStyle(.plain)
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
        .sheet(isPresented: $showingPreview) {
            if let image = loadedImage {
                ImagePreviewSheet(image: image, title: previewTitle)
            }
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
            loadedImage = uiImage
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

    private var previewTitle: String {
        let raw = URL(string: urlString)?.lastPathComponent ?? "Image"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Image" : trimmed
    }
}

private struct ImagePreviewSheet: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
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
        pattern: #"(?m)^\s*(What I Did|Result|Next Step|Output)\s*:\s*(\S.+)$"#,
        with: "## $1\n\n$2"
    )
    out = regexReplace(
        out,
        pattern: #"(?m)^\s*(What I Did|Result|Next Step|Output)\s+([A-Z][^\n]*)$"#,
        with: "## $1\n\n$2"
    )
    out = regexReplace(
        out,
        pattern: #"(?m)^\s*(What I Did|Result|Next Step|Output)([A-Z][^\n]*)$"#,
        with: "## $1\n\n$2"
    )
    out = regexReplace(
        out,
        pattern: #"(?m)^\s*(What I Did|Result|Next Step|Output)\s*:?\s*$"#,
        with: "## $1"
    )
    out = regexReplace(
        out,
        pattern: #"(?m)^(## (?:What I Did|Result|Next Step|Output))\n(?!\n)"#,
        with: "$1\n\n"
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
        "phone ux feedback guidance:",
        "emit short progress updates at meaningful milestones",
        "finish with a compressed final result",
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

func _test_massagedAssistantTextForDisplay(_ text: String) -> String {
    massageAssistantTextForDisplay(text)
}

func _test_messageSegmentIDs(_ text: String, serverURL: String) -> [String] {
    parseSegments(from: text, serverURL: serverURL).map(\.id)
}

func _test_messageSegmentContents(_ text: String, serverURL: String) -> [String] {
    parseSegments(from: text, serverURL: serverURL).map(\.content)
}
