import Foundation
import ImageIO
import QuickLook
import SwiftUI
import UIKit

struct ComposerSlashCommandMenu: View {
    let state: ComposerSlashCommandState
    let onSelect: (ComposerSlashCommand) -> Void

    private var visibleCommands: [ComposerSlashCommand] {
        Array(state.suggestions.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Slash Commands", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(state.exactMatch == nil ? "Tap to insert" : "Tap to run")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if state.hasUnknownCommand {
                Text("No slash command matches /\(state.query).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleCommands) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        ComposerSlashCommandRow(
                            command: command,
                            arguments: state.arguments,
                            isReadyToRun: state.exactMatch == command
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 10, y: 3)
    }
}

struct ComposerMetaPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.14), lineWidth: 1)
            )
    }
}

struct ComposerActionButtonLabel: View {
    let systemImage: String
    let tint: Color
    let fill: Color
    let size: CGFloat
    let iconSize: CGFloat
    let weight: Font.Weight

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: weight))
            .frame(width: size, height: size)
            .foregroundStyle(tint)
            .background(
                Circle()
                    .fill(fill)
            )
    }
}

struct ComposerPrimaryActionConfiguration {
    let systemImage: String
    let tint: Color
    let fill: Color
    let size: CGFloat
    let iconSize: CGFloat
    let weight: Font.Weight
    let accessibilityLabel: String
    let isDisabled: Bool
    let opacity: Double
    let action: () -> Void
}

struct ComposerTrayButtonLabel: View {
    let systemImage: String
    let tint: Color
    let fill: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(fill)
            )
            .overlay(
                Circle()
                    .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
            )
    }
}

struct RuntimeStatusBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(tint.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

struct RuntimeProfileContextOverviewCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Personal context for new runs")
                        .font(.subheadline.weight(.semibold))
                    Text("Project instructions and MOBaiLE runtime rules are always included. These controls only decide whether your saved profile files are added on top.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                RuntimeProfileContextExplanationRow(
                    systemImage: "person.text.rectangle",
                    title: "Profile Instructions",
                    detail: "Saved AGENTS guidance for how you like the agent to work."
                )
                RuntimeProfileContextExplanationRow(
                    systemImage: "brain",
                    title: "Profile Memory",
                    detail: "Saved MEMORY notes that carry durable facts across sessions."
                )
            }

            Label("Applies to new runs in this session.", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
        )
    }
}

struct RuntimeProfileContextSettingCard: View {
    let systemImage: String
    let title: String
    let summary: String
    let toggleTitle: String
    let stateLabel: String
    let stateDetail: String
    let backendDefaultSummary: String
    let isUsingBackendDefault: Bool
    let tint: Color
    let accessibilityIdentifier: String
    @Binding var isEnabled: Bool
    let onUseBackendDefault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(tint.opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                RuntimeProfileContextStateBadge(
                    text: stateLabel,
                    tint: isEnabled ? tint : .secondary
                )
            }

            Toggle(toggleTitle, isOn: $isEnabled)
                .tint(tint)
                .accessibilityIdentifier(accessibilityIdentifier)

            Text(stateDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    RuntimeProfileContextMetaLabel(
                        systemImage: "server.rack",
                        text: backendDefaultSummary
                    )
                    Spacer(minLength: 8)
                    backendDefaultAction
                }

                VStack(alignment: .leading, spacing: 8) {
                    RuntimeProfileContextMetaLabel(
                        systemImage: "server.rack",
                        text: backendDefaultSummary
                    )
                    backendDefaultAction
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var backendDefaultAction: some View {
        if isUsingBackendDefault {
            RuntimeProfileContextMetaLabel(
                systemImage: "checkmark.circle",
                text: "Following backend default"
            )
        } else {
            Button("Use Backend Default") {
                onUseBackendDefault()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

struct SettingsRuntimeDetailItem: Identifiable {
    let icon: String
    let label: String
    let value: String

    var id: String { label }
}

private struct RuntimeProfileContextExplanationRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RuntimeProfileContextStateBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct RuntimeProfileContextMetaLabel: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DraftAttachmentChip: View {
    let attachment: DraftAttachment
    let transferState: DraftAttachmentTransferState
    let isBusy: Bool
    let onPreview: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onPreview()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tintColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if showsDetailText {
                            Text(detailText)
                                .font(detailFont)
                                .foregroundStyle(detailColor)
                                .lineLimit(1)
                        }
                    }
                    if let progress = transferState.progressValue {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(tintColor)
                            .frame(width: 44)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(attachment.fileName)")

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.fileName)")
            .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var iconName: String {
        switch attachment.kind {
        case .image:
            return "photo"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .file:
            return "doc"
        }
    }

    private var tintColor: Color {
        if case .failed = transferState {
            return .red
        }
        if transferState.isUploading {
            return .accentColor
        }
        switch attachment.kind {
        case .image:
            return .blue
        case .code:
            return .green
        case .file:
            return .secondary
        }
    }

    private var detailText: String {
        switch transferState {
        case .idle:
            return ""
        case let .uploading(progress):
            return "Uploading \(Int((min(1, max(0, progress)) * 100).rounded()))%"
        case let .failed(message):
            return message
        }
    }

    private var showsDetailText: Bool {
        switch transferState {
        case .idle:
            return false
        case .uploading, .failed:
            return true
        }
    }

    private var detailFont: Font {
        switch transferState {
        case .idle:
            return .caption2
        case .uploading:
            return .caption2.weight(.semibold)
        case .failed:
            return .caption2.weight(.medium)
        }
    }

    private var detailColor: Color {
        switch transferState {
        case .idle:
            return .secondary
        case .uploading:
            return tintColor
        case .failed:
            return .red
        }
    }

    private var backgroundColor: Color {
        switch transferState {
        case .idle:
            return Color(.tertiarySystemGroupedBackground)
        case .uploading:
            return tintColor.opacity(0.12)
        case .failed:
            return Color.red.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch transferState {
        case .idle:
            return Color(.separator).opacity(0.10)
        case .uploading:
            return tintColor.opacity(0.16)
        case .failed:
            return Color.red.opacity(0.16)
        }
    }
}

struct FilePreviewSheet: View {
    let url: URL
    let title: String?
    let originalPath: String?
    let metadataText: String?
    @Environment(\.dismiss) private var dismiss
    @State private var copiedPath = false

    init(url: URL, title: String?, originalPath: String? = nil, metadataText: String? = nil) {
        self.url = url
        self.title = title
        self.originalPath = originalPath
        self.metadataText = metadataText
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let metadataText {
                    Text(metadataText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                }

                FileQuickLookPreview(url: url)
            }
            .navigationTitle((title ?? url.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share \(title ?? url.lastPathComponent)")

                    if let pathForActions {
                        Button {
                            UIPasteboard.general.string = pathForActions
                            copiedPath = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                copiedPath = false
                            }
                        } label: {
                            Image(systemName: copiedPath ? "checkmark" : "link")
                        }
                        .accessibilityLabel(copiedPath ? "Copied path" : "Copy file path")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var pathForActions: String? {
        let raw = (originalPath ?? url.path).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

struct PreviewDocument: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let originalPath: String?
    let metadataText: String?

    init(url: URL, title: String, originalPath: String? = nil, metadataText: String? = nil) {
        self.url = url
        self.title = title
        self.originalPath = originalPath
        self.metadataText = metadataText
    }
}

struct TextPreviewSource {
    let serverURL: String
    let token: String
    let artifact: ChatArtifact

    var originalPath: String? {
        artifact.path ?? artifact.url
    }
}

struct TextPreviewDocument: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let text: String
    let isTruncated: Bool
    let sizeBytes: Int64?
    let modifiedAt: String?
    let previewOffset: Int
    let nextOffset: Int?
    let previewBlockedReason: String?
    let searchMatches: [TextSearchMatch]
    let searchMatchCount: Int?
    let language: String?
    let source: TextPreviewSource?
    let originalPath: String?

    init(
        url: URL,
        title: String,
        text: String,
        isTruncated: Bool = false,
        sizeBytes: Int64? = nil,
        modifiedAt: String? = nil,
        previewOffset: Int = 0,
        nextOffset: Int? = nil,
        previewBlockedReason: String? = nil,
        searchMatches: [TextSearchMatch] = [],
        searchMatchCount: Int? = nil,
        language: String? = nil,
        source: TextPreviewSource? = nil,
        originalPath: String? = nil
    ) {
        self.url = url
        self.title = title
        self.text = text
        self.isTruncated = isTruncated
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.previewOffset = previewOffset
        self.nextOffset = nextOffset
        self.previewBlockedReason = previewBlockedReason
        self.searchMatches = searchMatches
        self.searchMatchCount = searchMatchCount
        self.language = language ?? FilePreviewLanguage.infer(fileName: title, mime: nil)
        self.source = source
        self.originalPath = originalPath ?? source?.originalPath
    }
}

struct TextFilePreviewSheet: View {
    let document: TextPreviewDocument
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var copiedPath = false
    @State private var showsLineNumbers = false
    @State private var wrapsLines = true
    @State private var searchText = ""
    @State private var previewText: String
    @State private var nextOffset: Int?
    @State private var previewIsTruncated: Bool
    @State private var serverSearchQuery: String?
    @State private var serverSearchMatches: [TextSearchMatch]
    @State private var serverSearchMatchCount: Int?
    @State private var isLoadingMore = false
    @State private var isSearchingFullFile = false
    @State private var previewActionError: String?
    @State private var displayMode: TextPreviewDisplayMode

    init(document: TextPreviewDocument) {
        self.document = document
        _previewText = State(initialValue: document.text)
        _nextOffset = State(initialValue: document.nextOffset)
        _previewIsTruncated = State(initialValue: document.isTruncated || document.nextOffset != nil)
        _serverSearchQuery = State(initialValue: nil)
        _serverSearchMatches = State(initialValue: document.searchMatches)
        _serverSearchMatchCount = State(initialValue: document.searchMatchCount)
        _displayMode = State(initialValue: TextPreviewDisplayMode.defaultMode(
            fileName: document.title,
            language: document.language
        ))
    }

    private var displayText: String {
        showsLineNumbers ? TextPreviewFormatter.numberedText(previewText) : previewText
    }

    private var visibleSearchText: String {
        displayMode == .raw ? displayText : previewText
    }

    private var searchMatchCount: Int {
        TextPreviewFormatter.matchCount(in: visibleSearchText, query: searchText)
    }

    private var metadataText: String? {
        FileMetadataFormatter.previewMetadataText(
            sizeBytes: document.sizeBytes,
            modifiedAt: document.modifiedAt
        )
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasServerSearchForCurrentQuery: Bool {
        guard let serverSearchQuery else { return false }
        return serverSearchQuery.caseInsensitiveCompare(trimmedSearchText) == .orderedSame
    }

    private var canSearchFullFile: Bool {
        document.source != nil && !trimmedSearchText.isEmpty
    }

    private var searchSummaryText: String {
        if hasServerSearchForCurrentQuery, let serverSearchMatchCount {
            if serverSearchMatchCount > serverSearchMatches.count {
                return "Showing \(serverSearchMatches.count) of \(serverSearchMatchCount) full-file matches"
            }
            return "\(serverSearchMatchCount) full-file \(serverSearchMatchCount == 1 ? "match" : "matches")"
        }
        return "\(searchMatchCount) visible \(searchMatchCount == 1 ? "match" : "matches")"
    }

    private var availableDisplayModes: [TextPreviewDisplayMode] {
        TextPreviewDisplayMode.availableModes(
            fileName: document.title,
            language: document.language
        )
    }

    private var pathForActions: String? {
        let raw = (document.originalPath ?? document.url.path).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let metadataText {
                    Text(metadataText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                }

                if let blockedReason = document.previewBlockedReason {
                    Label(blockedReason == "sensitive_path" ? "Sensitive path preview blocked" : "Text preview blocked", systemImage: "lock.shield")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                } else if previewIsTruncated {
                    HStack(spacing: 10) {
                        Label("Preview loaded \(humanReadableAttachmentSize(Int64(previewText.utf8.count)))", systemImage: "text.page.badge.magnifyingglass")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if nextOffset != nil {
                            Button {
                                Task { await loadMorePreview() }
                            } label: {
                                if isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Load More")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(document.source == nil || isLoadingMore)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground))
                }

                previewModePicker
                previewContent

                if !trimmedSearchText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(searchSummaryText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if canSearchFullFile {
                                Button {
                                    Task { await searchFullFile() }
                                } label: {
                                    if isSearchingFullFile {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("Search Full File")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isSearchingFullFile)
                            }
                        }

                        if hasServerSearchForCurrentQuery, !serverSearchMatches.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(serverSearchMatches.prefix(8))) { match in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(match.lineNumber)")
                                            .font(.caption2.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(minWidth: 28, alignment: .trailing)
                                        Text(TextPreviewFormatter.highlightedText(match.lineText, query: searchText, language: document.language))
                                            .font(.caption.monospaced())
                                            .lineLimit(2)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground))
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find in file")
            .onChange(of: searchText) {
                let trimmed = trimmedSearchText
                if trimmed.isEmpty || serverSearchQuery?.caseInsensitiveCompare(trimmed) != .orderedSame {
                    serverSearchMatches = []
                    serverSearchMatchCount = nil
                    serverSearchQuery = nil
                }
            }
            .alert("Preview failed", isPresented: Binding(
                get: { previewActionError != nil },
                set: { if !$0 { previewActionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(previewActionError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if displayMode == .raw {
                            Toggle("Line Numbers", isOn: $showsLineNumbers)
                            Toggle("Wrap Lines", isOn: $wrapsLines)
                        }
                        if availableDisplayModes.count > 1 {
                            Picker("Preview Mode", selection: $displayMode) {
                                ForEach(availableDisplayModes) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "text.alignleft")
                    }
                    .accessibilityLabel("Text preview options")
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: document.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            UIPasteboard.general.string = previewText
                            copied = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied Text" : "Copy Text", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }

                        if let pathForActions {
                            Button {
                                UIPasteboard.general.string = pathForActions
                                copiedPath = true
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                                    copiedPath = false
                                }
                            } label: {
                                Label(copiedPath ? "Copied Path" : "Copy File Path", systemImage: copiedPath ? "checkmark" : "link")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("File actions")

                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var previewModePicker: some View {
        if availableDisplayModes.count > 1 {
            Picker("Preview mode", selection: $displayMode) {
                ForEach(availableDisplayModes) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch displayMode {
        case .raw:
            ScrollView(wrapsLines ? [.vertical] : [.vertical, .horizontal]) {
                Text(TextPreviewFormatter.highlightedText(displayText, query: searchText, language: document.language))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: wrapsLines ? .infinity : nil,
                        alignment: .leading
                    )
                    .padding()
            }
            .background(Color(.systemBackground))
        case .renderedMarkdown:
            MarkdownRenderedPreview(text: previewText, query: searchText)
                .background(Color(.systemBackground))
        case .table:
            DelimitedTablePreview(
                text: previewText,
                delimiter: DelimitedTextParser.delimiter(forFileName: document.title),
                query: searchText
            )
            .background(Color(.systemBackground))
        case .outline:
            JSONOutlinePreview(text: previewText, query: searchText)
                .background(Color(.systemBackground))
        }
    }

    @MainActor
    private func loadMorePreview() async {
        guard let source = document.source, let nextOffset else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let inspection = try await APIClient().inspectArtifactFile(
                serverURL: source.serverURL,
                token: source.token,
                artifact: source.artifact,
                textPreviewOffset: nextOffset
            )
            previewText += inspection.textPreview ?? ""
            self.nextOffset = inspection.textPreviewNextOffset
            previewIsTruncated = inspection.textPreviewNextOffset != nil || inspection.textPreviewTruncated
        } catch {
            previewActionError = error.localizedDescription
        }
    }

    @MainActor
    private func searchFullFile() async {
        guard let source = document.source else { return }
        let query = trimmedSearchText
        guard !query.isEmpty else { return }

        isSearchingFullFile = true
        defer { isSearchingFullFile = false }

        do {
            let inspection = try await APIClient().inspectArtifactFile(
                serverURL: source.serverURL,
                token: source.token,
                artifact: source.artifact,
                textSearch: query
            )
            serverSearchQuery = inspection.textSearchQuery ?? query
            serverSearchMatchCount = inspection.textSearchMatchCount
            serverSearchMatches = inspection.textSearchMatches
        } catch {
            previewActionError = error.localizedDescription
        }
    }
}

enum FilePreviewLanguage {
    static func infer(fileName: String, mime: String?) -> String? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "c", "cc", "cpp", "h", "hpp":
            return "c"
        case "css":
            return "css"
        case "csv", "tsv":
            return "csv"
        case "go":
            return "go"
        case "htm", "html":
            return "html"
        case "java", "kt":
            return "java"
        case "js", "mjs", "ts", "tsx":
            return "javascript"
        case "json", "jsonl", "ndjson":
            return "json"
        case "log":
            return "log"
        case "markdown", "md", "mdown", "mdtext", "mdwn", "mkd":
            return "markdown"
        case "php":
            return "php"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "sh", "bash", "zsh":
            return "shell"
        case "sql":
            return "sql"
        case "swift":
            return "swift"
        case "toml", "yaml", "yml":
            return "yaml"
        case "xml", "svg":
            return "xml"
        default:
            break
        }

        let lowerMime = (mime ?? "").lowercased()
        if lowerMime.contains("json") { return "json" }
        if lowerMime.contains("markdown") { return "markdown" }
        if lowerMime.contains("csv") || lowerMime.contains("tab-separated") { return "csv" }
        if lowerMime.contains("xml") || lowerMime.contains("svg") { return "xml" }
        if lowerMime.hasPrefix("text/") { return "text" }
        return nil
    }

    static func highlightedText(_ text: String, language: String?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let language else { return attributed }

        switch language {
        case "json":
            applyPattern(#""[^"\n]+"(?=\s*:)"#, in: text, to: &attributed, color: .purple)
            applyPattern(#""(?:\\.|[^"\\])*""#, in: text, to: &attributed, color: .red)
            applyPattern(#"\b(true|false|null)\b"#, in: text, to: &attributed, color: .blue)
            applyPattern(#"\b\d+(?:\.\d+)?\b"#, in: text, to: &attributed, color: .orange)
        case "markdown":
            applyPattern(#"(?m)^#{1,6}\s.+$"#, in: text, to: &attributed, color: .blue)
            applyPattern(#"`[^`\n]+`"#, in: text, to: &attributed, color: .purple)
            applyPattern(#"\*\*[^*\n]+\*\*"#, in: text, to: &attributed, color: .primary)
            applyPattern(#"(?m)^\s*[-*+]\s+"#, in: text, to: &attributed, color: .secondary)
        case "csv", "log", "text":
            break
        case "yaml":
            applyPattern(#"(?m)^[A-Za-z0-9_.-]+(?=\s*:)"#, in: text, to: &attributed, color: .purple)
            applyPattern(#"(?m)#.*$"#, in: text, to: &attributed, color: .secondary)
            applyPattern(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, in: text, to: &attributed, color: .red)
        case "shell", "python", "ruby":
            applyPattern(#"(?m)#.*$"#, in: text, to: &attributed, color: .secondary)
            applyPattern(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, in: text, to: &attributed, color: .red)
            applyPattern(commonKeywordPattern, in: text, to: &attributed, color: .blue)
        case "html", "xml":
            applyPattern(#"</?[A-Za-z0-9_.:-]+"#, in: text, to: &attributed, color: .blue)
            applyPattern(#"\b[A-Za-z0-9_.:-]+(?=\=)"#, in: text, to: &attributed, color: .purple)
            applyPattern(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, in: text, to: &attributed, color: .red)
        case "css":
            applyPattern(#"(?m)/\*[\s\S]*?\*/"#, in: text, to: &attributed, color: .secondary)
            applyPattern(#"[.#]?[A-Za-z0-9_-]+(?=\s*\{)"#, in: text, to: &attributed, color: .blue)
            applyPattern(#"\b[A-Za-z-]+(?=\s*:)"#, in: text, to: &attributed, color: .purple)
        default:
            applyPattern(#"(?m)//.*$"#, in: text, to: &attributed, color: .secondary)
            applyPattern(#"(?m)#.*$"#, in: text, to: &attributed, color: .secondary)
            applyPattern(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, in: text, to: &attributed, color: .red)
            applyPattern(commonKeywordPattern, in: text, to: &attributed, color: .blue)
            applyPattern(#"\b\d+(?:\.\d+)?\b"#, in: text, to: &attributed, color: .orange)
        }

        return attributed
    }

    private static let commonKeywordPattern = #"\b(async|await|break|case|catch|class|const|continue|def|do|else|enum|except|extension|false|final|for|from|func|function|guard|if|import|in|let|nil|null|private|public|return|self|static|struct|switch|throw|throws|true|try|var|while)\b"#

    private static func applyPattern(
        _ pattern: String,
        in text: String,
        to attributed: inout AttributedString,
        color: Color
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: nsRange) {
            guard let textRange = Range(match.range, in: text),
                  let attributedRange = Range(textRange, in: attributed) else {
                continue
            }
            attributed[attributedRange].foregroundColor = color
        }
    }
}

enum FileMetadataFormatter {
    static func previewMetadataText(
        sizeBytes: Int64?,
        modifiedAt: String?,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        mime: String? = nil
    ) -> String? {
        var parts: [String] = []
        if let sizeBytes {
            parts.append(humanReadableAttachmentSize(sizeBytes))
        }
        if let imageWidth, let imageHeight {
            parts.append("\(imageWidth)x\(imageHeight)")
        }
        if let mime = mime?.trimmingCharacters(in: .whitespacesAndNewlines), !mime.isEmpty {
            parts.append(mime)
        }
        if let modified = modifiedLabel(modifiedAt, compact: false) {
            parts.append(modified)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func modifiedShortLabel(_ modifiedAt: String?) -> String? {
        modifiedLabel(modifiedAt, compact: true)
    }

    private static func modifiedLabel(_ modifiedAt: String?, compact: Bool) -> String? {
        guard let modifiedAt,
              let date = parseISODate(modifiedAt) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        if compact {
            let template = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                ? "dMMMHHmm"
                : "dMMMyyyyHHmm"
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        formatter.dateStyle = .medium
        return "Modified \(formatter.string(from: date))"
    }

    private static func parseISODate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum FilePreviewUnsupportedMessage {
    static func message(fileName: String, mime: String?, sizeBytes: Int64?) -> String {
        var details: [String] = []
        if let mime = mime?.trimmingCharacters(in: .whitespacesAndNewlines), !mime.isEmpty {
            details.append(mime)
        }
        if let sizeBytes {
            details.append(humanReadableAttachmentSize(sizeBytes))
        }

        let descriptor = details.isEmpty ? "This file" : "\(fileName) (\(details.joined(separator: ", ")))"
        if isArchive(fileName: fileName, mime: mime) {
            return "\(descriptor) is an archive, which cannot be previewed inline on iPhone yet. Inspect or extract it on the host."
        }
        if isLikelyBinary(mime: mime) {
            return "\(descriptor) is a binary file that cannot be rendered inline on iPhone yet. Inspect it on the host."
        }
        return "\(descriptor) cannot be previewed inline on iPhone. Inspect it from the host."
    }

    private static func isArchive(fileName: String, mime: String?) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let lowerMime = (mime ?? "").lowercased()
        return ["zip", "gz", "tgz", "tar", "rar", "7z", "xz"].contains(ext) ||
            lowerMime.contains("zip") ||
            lowerMime.contains("tar") ||
            lowerMime.contains("archive") ||
            lowerMime.contains("compressed")
    }

    private static func isLikelyBinary(mime: String?) -> Bool {
        let lowerMime = (mime ?? "").lowercased()
        guard !lowerMime.isEmpty else { return false }
        return lowerMime == "application/octet-stream" ||
            lowerMime.hasPrefix("audio/") ||
            lowerMime.hasPrefix("video/") ||
            lowerMime.hasPrefix("font/")
    }
}

enum TextPreviewLoader {
    private static let maxPreviewBytes = 2 * 1024 * 1024
    private static let previewTextPrefix = "mobaile-text-preview-"
    private static let stalePreviewFileAge: TimeInterval = 24 * 60 * 60

    static func canPreview(fileName: String, mimeType: String?) -> Bool {
        let lowerMime = (mimeType ?? "").lowercased()
        if lowerMime.hasPrefix("text/") || lowerMime.contains("json") || lowerMime.contains("xml") {
            return true
        }
        return inferAttachmentKind(
            fileName: fileName,
            mimeType: inferAttachmentMimeType(fileName: fileName, fallback: mimeType)
        ) == .code
    }

    static func loadText(from url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize, size > maxPreviewBytes {
                throw TextPreviewError.tooLarge
            }
            let data = try Data(contentsOf: url)
            if data.count > maxPreviewBytes {
                throw TextPreviewError.tooLarge
            }
            if let text = TextPreviewDataDecoder.decodedText(from: data) {
                return text
            }
            throw TextPreviewError.unsupportedEncoding
        }.value
    }

    static func writePreviewTextToTemporaryFile(title: String, text: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            cleanupStalePreviewTextFiles()
            let titleURL = URL(fileURLWithPath: title)
            let rawExtension = titleURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            let fileExtension = rawExtension.isEmpty ? ".txt" : ".\(rawExtension)"
            let rawStem = titleURL.deletingPathExtension().lastPathComponent
            let fileName = "\(previewTextPrefix)\(sanitizePreviewFileName(rawStem))-\(UUID().uuidString)\(fileExtension)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        }.value
    }

    private static func sanitizePreviewFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "file" : trimmed
    }

    private static func cleanupStalePreviewTextFiles() {
        let directory = FileManager.default.temporaryDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let now = Date()
        for url in urls where url.lastPathComponent.hasPrefix(previewTextPrefix) {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modifiedAt) > stalePreviewFileAge {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

enum LocalFileInspection {
    static func inspect(
        url: URL,
        name: String,
        mime: String?,
        textPreviewBytes: Int,
        textPreviewOffset: Int = 0,
        textSearch: String? = nil
    ) async throws -> FileInspectionResponse {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values.fileSize ?? 0)
            let resolvedMime = inferAttachmentMimeType(fileName: name, fallback: mime)
            let kind = inferAttachmentKind(fileName: name, mimeType: resolvedMime)
            let dimensions = imageDimensions(url: url, kind: kind)
            let modifiedAt = values.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) }
            let preview = textPreview(
                url: url,
                name: name,
                mime: resolvedMime,
                byteLimit: textPreviewBytes,
                offset: textPreviewOffset
            )
            let search = textSearchMatches(
                url: url,
                name: name,
                mime: resolvedMime,
                query: textSearch
            )

            return FileInspectionResponse(
                name: name,
                path: url.path,
                sizeBytes: size,
                mime: resolvedMime,
                artifactType: artifactType(for: kind),
                modifiedAt: modifiedAt ?? ISO8601DateFormatter().string(from: Date()),
                textPreview: preview.text,
                textPreviewBytes: preview.bytes,
                textPreviewTruncated: preview.truncated,
                textPreviewOffset: max(textPreviewOffset, 0),
                textPreviewNextOffset: preview.nextOffset,
                textSearchQuery: search.query,
                textSearchMatchCount: search.matchCount,
                textSearchMatches: search.matches,
                imageWidth: dimensions.width,
                imageHeight: dimensions.height
            )
        }.value
    }

    private static func artifactType(for kind: DraftAttachment.Kind) -> String {
        switch kind {
        case .image:
            return "image"
        case .code:
            return "code"
        case .file:
            return "file"
        }
    }

    private static func textPreview(
        url: URL,
        name: String,
        mime: String,
        byteLimit: Int,
        offset: Int
    ) -> (text: String?, bytes: Int, truncated: Bool, nextOffset: Int?) {
        let limit = max(0, byteLimit)
        let safeOffset = max(0, offset)
        guard limit > 0, TextPreviewLoader.canPreview(fileName: name, mimeType: mime) else {
            return (nil, 0, false, nil)
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(safeOffset))
            let data = try handle.read(upToCount: limit + 4) ?? Data()
            let truncated = data.count > limit
            let previewData = Data(truncated ? data.prefix(limit) : data[...])
            if let decoded = TextPreviewDataDecoder.decodedPrefix(from: previewData) {
                let nextOffset = truncated ? safeOffset + decoded.byteCount : nil
                return (decoded.text, decoded.byteCount, truncated, nextOffset)
            }
        } catch {
            return (nil, 0, false, nil)
        }
        return (nil, 0, false, nil)
    }

    private static func textSearchMatches(
        url: URL,
        name: String,
        mime: String,
        query: String?
    ) -> (query: String?, matchCount: Int?, matches: [TextSearchMatch]) {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !needle.isEmpty, TextPreviewLoader.canPreview(fileName: name, mimeType: mime) else {
            return (nil, nil, [])
        }

        do {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize, size > 8 * 1024 * 1024 {
                return (needle, 0, [])
            }
            let data = try Data(contentsOf: url)
            guard let text = TextPreviewDataDecoder.decodedText(from: data) else {
                return (needle, 0, [])
            }
            var count = 0
            var matches: [TextSearchMatch] = []
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.range(of: needle, options: [.caseInsensitive]) != nil {
                count += 1
                if matches.count < 50 {
                    matches.append(TextSearchMatch(lineNumber: index + 1, lineText: String(line)))
                }
            }
            return (needle, count, matches)
        } catch {
            return (needle, 0, [])
        }
    }

    private static func imageDimensions(url: URL, kind: DraftAttachment.Kind) -> (width: Int?, height: Int?) {
        guard kind == .image,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        return (width, height)
    }
}

#if DEBUG
func _test_numberedPreviewText(_ text: String) -> String {
    TextPreviewFormatter.numberedText(text)
}

func _test_textPreviewMatchCount(_ text: String, query: String) -> Int {
    TextPreviewFormatter.matchCount(in: text, query: query)
}

func _test_textPreviewMatchedSnippets(_ text: String, query: String) -> [String] {
    TextPreviewFormatter.matchRanges(in: text, query: query).map { String(text[$0]) }
}
#endif

enum TextPreviewError: Error, LocalizedError {
    case tooLarge
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            return "This text file is too large for the inline preview."
        case .unsupportedEncoding:
            return "This text file uses an encoding the app can't display."
        }
    }
}

private struct FileQuickLookPreview: UIViewControllerRepresentable {
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

struct PairingConfirmationSheet: View {
    let pending: VoiceAgentViewModel.PendingPairing
    @Binding var trustHost: Bool
    let onCancel: () -> Void
    let onConfirm: () async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var isPairing = false
    @State private var pairingError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Host", value: pending.serverHost.isEmpty ? pending.serverURL : pending.serverHost)
                        .font(.footnote.monospaced())
                    LabeledContent("URL", value: pending.serverURL)
                        .font(.footnote.monospaced())
                    LabeledContent("Security", value: pending.badgeText)
                }

                if pending.serverURLs.count > 1 {
                    Section("Connection Paths") {
                        Text("MOBaiLE will try these URLs in order for pairing and reconnects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(pending.serverURLs.enumerated()), id: \.offset) { index, url in
                            LabeledContent(index == 0 ? "Primary" : "Fallback \(index)", value: url)
                                .font(.footnote.monospaced())
                        }
                    }
                }

                if pending.tailscaleNetworkNotice != nil || pending.localNetworkWarning != nil {
                    Section("Network") {
                        if let notice = pending.tailscaleNetworkNotice {
                            Label("Tailscale path selected", systemImage: "network")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.blue)
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let warning = pending.localNetworkWarning {
                            Label("Local network HTTP detected", systemImage: "wifi.exclamationmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Session") {
                    LabeledContent("Session ID", value: pending.sessionID ?? "default")
                    LabeledContent(
                        "Method",
                        value: pending.pairCode != nil ? "One-time pair code" : "Legacy token (developer mode)"
                    )
                }

                Section("Trust") {
                    Toggle("Remember this server after pairing", isOn: $trustHost)
                    Text("A fresh pair code is still required. Remembering the server only preselects this trust choice the next time you pair with the same host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isPairing {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Pairing with \(pending.serverHost.isEmpty ? pending.serverURL : pending.serverHost)")
                                    .font(.subheadline.weight(.semibold))
                                Text("Checking the advertised route first so the one-time pair code is only used on a reachable backend.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let pairingError {
                    Section {
                        Label("Pairing failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(pairingError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Confirm Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard !isPairing else { return }
                        isPairing = true
                        pairingError = nil
                        Task {
                            let errorMessage = await onConfirm()
                            isPairing = false
                            if let errorMessage {
                                pairingError = errorMessage
                                return
                            }
                            dismiss()
                        }
                    } label: {
                        if isPairing {
                            ProgressView()
                        } else {
                            Text("Pair")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(isPairing)
                }
            }
        }
    }
}

struct SetupGuideSheet: View {
    let bootstrapInstallCommand: String
    let checkoutInstallCommand: String
    let quickStartURL: URL
    let supportURL: URL
    let onOpenScanner: () -> Void
    let onManualSetup: () -> Void

    @State private var copiedLabel: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Set it up", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Start on your computer. Pair once. Then the app is ready.")
                            .font(.title3.weight(.semibold))
                        Text("MOBaiLE does not run code on iPhone. It connects to a backend on your own Mac or Linux machine.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SetupGuideStepSummaryRow(
                            stepNumber: 1,
                            title: "Run the installer on your computer",
                            detail: "This is the easiest path. The installer asks three quick questions. For the normal setup, keep `Full Access`, `Anywhere with Tailscale`, and `Yes` for the background service."
                        )
                        SetupGuideCommandBlock(command: bootstrapInstallCommand)

                        HStack(spacing: 10) {
                            Button(copiedLabel == "bootstrap" ? "Copied" : "Copy Command") {
                                UIPasteboard.general.string = bootstrapInstallCommand
                                copiedLabel = "bootstrap"
                            }
                            .buttonStyle(.borderedProminent)

                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Already inside this repo?")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(checkoutInstallCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        SetupGuideStepSummaryRow(
                            stepNumber: 2,
                            title: "Scan the pairing QR in MOBaiLE",
                            detail: "After install, run `mobaile pair` on the computer and open the QR path it prints. In MOBaiLE, tap Scan Pairing QR and point the phone at the screen."
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("What to do next")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("1. Run `mobaile pair` on the computer.")
                            Text("2. Open the `Pairing QR` path it prints.")
                            Text("3. Tap Scan Pairing QR in MOBaiLE.")
                            Text("4. Point the phone at the screen and confirm the pairing.")
                            Text("5. Later, run `mobaile status` on the computer. If your shell does not find it yet, run `~/.local/bin/mobaile status`.")
                        }
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)

                        Button {
                            onOpenScanner()
                        } label: {
                            Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Manual fallback", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                        Text("If QR pairing is not available, open Settings and paste the server URL from the active pairing file plus `VOICE_AGENT_API_TOKEN` from the active backend `.env`.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Enter URL and Token Manually") {
                            onManualSetup()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Link("Open Set It Up", destination: quickStartURL)
                        Link("Open Support", destination: supportURL)
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Set It Up")
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

private struct ComposerSlashCommandRow: View {
    let command: ComposerSlashCommand
    let arguments: String
    let isReadyToRun: Bool

    private var hintText: String {
        if isReadyToRun {
            if command.acceptsArguments && !arguments.isEmpty {
                return "Run"
            }
            return "Use"
        }
        return "Insert"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.usage)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.primary)
                    if let group = command.group, !group.isEmpty {
                        Text(group.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
                Text(command.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text(hintText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isReadyToRun ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background((isReadyToRun ? Color.accentColor : Color.secondary).opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SetupGuideStepSummaryRow: View {
    let stepNumber: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Text("\(stepNumber)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct SetupGuideCommandBlock: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.footnote.monospaced())
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.separator).opacity(0.14), lineWidth: 1)
            )
    }
}
