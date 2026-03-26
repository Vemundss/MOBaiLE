import Foundation
import SwiftUI

private struct MobaileLogoMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.92, green: 0.95, blue: 1.0), Color(red: 0.83, green: 0.90, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(Color.white.opacity(0.95))
                .padding(6)
            Circle()
                .fill(Color(red: 0.27, green: 0.46, blue: 0.88))
                .frame(width: 6, height: 6)
                .offset(x: -7, y: -2)
            Circle()
                .fill(Color(red: 0.27, green: 0.46, blue: 0.88))
                .frame(width: 6, height: 6)
                .offset(x: 7, y: -2)
            Capsule()
                .fill(Color(red: 0.30, green: 0.53, blue: 0.94))
                .frame(width: 14, height: 3.5)
                .offset(y: 7)
            Circle()
                .fill(Color(red: 1.0, green: 0.74, blue: 0.86))
                .frame(width: 4, height: 4)
                .offset(x: -12, y: 7)
            Circle()
                .fill(Color(red: 1.0, green: 0.74, blue: 0.86))
                .frame(width: 4, height: 4)
                .offset(x: 12, y: 7)
            Circle()
                .fill(Color(red: 0.30, green: 0.53, blue: 0.94))
                .frame(width: 6, height: 6)
                .offset(y: -14)
            Rectangle()
                .fill(Color(red: 0.30, green: 0.53, blue: 0.94))
                .frame(width: 2.5, height: 6)
                .offset(y: -10)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 5, y: 2)
    }
}

private struct ConnectionBadge: View {
    let isConnected: Bool
    let statusText: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label(isConnected ? "Connected" : "Setup needed", systemImage: isConnected ? "checkmark.circle.fill" : "gearshape.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isConnected ? Color.green : Color.orange)

            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StarterPrompt {
    let label: String
    let prompt: String
    let systemImage: String
    let detail: String
}

struct ConversationEmptyStateView: View {
    let isConfigured: Bool
    let statusText: String
    let canRetryLastPrompt: Bool
    let onOpenSettings: () -> Void
    let onRetryLastPrompt: () -> Void
    let onUsePrompt: (String) -> Void

    private let starterPrompts = [
        StarterPrompt(
            label: "Map the repo",
            prompt: "summarize this repo and point out the most important modules",
            systemImage: "square.stack.3d.up",
            detail: "Get a quick codebase map and where to start."
        ),
        StarterPrompt(
            label: "Run Smoke Test",
            prompt: "run the recommended smoke test for this project and summarize the result",
            systemImage: "checkmark.seal",
            detail: "Validate the current baseline before changing anything."
        ),
        StarterPrompt(
            label: "Review Latest UI",
            prompt: "review the current UI and suggest the highest-impact improvements",
            systemImage: "wand.and.stars",
            detail: "Tighten the current screen before you ask for implementation."
        )
    ]

    private var configuredStarterPrompts: [StarterPrompt] {
        Array(starterPrompts.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isConfigured ? 12 : 18) {
            if isConfigured {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ask about this repo, or start with one of these tasks.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top),
                            GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top)
                        ],
                        spacing: 10
                    ) {
                        ForEach(configuredStarterPrompts, id: \.label) { prompt in
                            CompactStarterPromptButton(prompt: prompt) {
                                onUsePrompt(prompt.prompt)
                            }
                        }
                    }

                    if canRetryLastPrompt {
                        Button {
                            onRetryLastPrompt()
                        } label: {
                            Label("Retry last prompt", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    MobaileLogoMark()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("MOBaiLE")
                            .font(.title3.weight(.semibold))
                        Text("Voice and workspace agent")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    ConnectionBadge(isConnected: isConfigured, statusText: statusText)
                        .frame(maxWidth: 150, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your backend once, then prompts, voice tasks, and live run updates all happen here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("What you unlock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        EmptyStateFeatureRow(
                            systemImage: "mic.fill",
                            title: "Voice-first tasks",
                            detail: "Record a prompt hands-free and send it straight into the thread."
                        )
                        EmptyStateFeatureRow(
                            systemImage: "sparkles.rectangle.stack",
                            title: "Live run updates",
                            detail: "Watch planning, execution, and results stream back in one place."
                        )
                        EmptyStateFeatureRow(
                            systemImage: "folder.badge.gearshape",
                            title: "Workspace control",
                            detail: "Pick the repo folder and keep future runs anchored to it."
                        )
                    }

                    Button {
                        onOpenSettings()
                    } label: {
                        Label("Open Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isConfigured ? 14 : 18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(.separator).opacity(0.20), lineWidth: 1)
        )
    }
}

private struct CompactStarterPromptButton: View {
    let prompt: StarterPrompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label(prompt.label, systemImage: prompt.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(prompt.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyStateFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
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

struct InlineNoticeCard: View {
    let title: String
    let message: String
    let tint: Color
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SheetIntroCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(0.22), lineWidth: 1)
        )
    }
}

struct LogsView: View {
    let events: [ExecutionEvent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    ContentUnavailableView(
                        "No Run Logs Yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Run logs appear here after you send a prompt or voice task.")
                    )
                } else {
                    List {
                        Section {
                            SheetIntroCard(
                                title: "Execution Timeline",
                                message: "Newest events appear first. Long-press any row to select and copy text.",
                                systemImage: "waveform.path.ecg",
                                tint: .blue
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(Array(events.enumerated().reversed()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.type)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Run Logs")
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

struct ThreadsView: View {
    let threads: [ChatThread]
    let activeThreadID: UUID?
    let onSelect: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onNewChat: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renamingThreadID: UUID?
    @State private var renameTitle: String = ""
    @State private var pendingDeleteThread: ChatThread?

    private var displayedThreads: [ChatThread] {
        guard let activeThreadID,
              let activeIndex = threads.firstIndex(where: { $0.id == activeThreadID }) else {
            return threads
        }
        var ordered = threads
        let active = ordered.remove(at: activeIndex)
        return [active] + ordered
    }

    var body: some View {
        NavigationStack {
            Group {
                if threads.isEmpty {
                    ContentUnavailableView(
                        "No Threads Yet",
                        systemImage: "text.bubble",
                        description: Text("Start a chat and it will show up here for quick switching later.")
                    )
                } else {
                    List {
                        ForEach(displayedThreads) { thread in
                            Button {
                                onSelect(thread.id)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            Text(thread.title)
                                                .font(.body.weight(activeThreadID == thread.id ? .semibold : .regular))
                                                .lineLimit(1)
                                            if activeThreadID == thread.id {
                                                Text("Current")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 7)
                                                    .padding(.vertical, 3)
                                                    .background(Color.accentColor.opacity(0.12))
                                                    .foregroundStyle(Color.accentColor)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(threadPreview(for: thread))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        HStack(spacing: 8) {
                                            Text(thread.updatedAt, style: .relative)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(threadStatusText(for: thread))
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(threadStatusColor(for: thread).opacity(0.14))
                                                .foregroundStyle(threadStatusColor(for: thread))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(activeThreadID == thread.id ? Color.accentColor.opacity(0.09) : Color(.secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(
                                        activeThreadID == thread.id
                                            ? Color.accentColor.opacity(0.22)
                                            : Color(.separator).opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteThread = thread
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    renamingThreadID = thread.id
                                    renameTitle = thread.title
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat") {
                        onNewChat()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .alert("Rename Thread", isPresented: Binding(
                get: { renamingThreadID != nil },
                set: { if !$0 { renamingThreadID = nil } }
            )) {
                TextField("Title", text: $renameTitle)
                Button("Cancel", role: .cancel) {
                    renamingThreadID = nil
                }
                Button("Save") {
                    if let threadID = renamingThreadID {
                        onRename(threadID, renameTitle)
                    }
                    renamingThreadID = nil
                }
            }
            .alert("Delete Thread", isPresented: Binding(
                get: { pendingDeleteThread != nil },
                set: { if !$0 { pendingDeleteThread = nil } }
            )) {
                Button("Cancel", role: .cancel) {
                    pendingDeleteThread = nil
                }
                Button("Delete", role: .destructive) {
                    if let thread = pendingDeleteThread {
                        onDelete(thread.id)
                    }
                    pendingDeleteThread = nil
                }
            } message: {
                Text("This removes the thread history stored on the device.")
            }
        }
    }

    private func threadPreview(for thread: ChatThread) -> String {
        if let draftPreview = draftPreview(for: thread) {
            return "Draft: \(draftPreview)"
        }
        let values = [
            thread.summaryText,
            thread.transcriptText,
            thread.statusText
        ]
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "Idle" {
                return trimmed
            }
        }
        return "No messages yet."
    }

    private func threadStatusText(for thread: ChatThread) -> String {
        let lower = thread.statusText.lowercased()
        if lower.contains("running") || lower.contains("starting") {
            return "Running"
        }
        if hasDraftState(thread) {
            return "Draft"
        }
        if lower.contains("complete") {
            return "Completed"
        }
        if lower.contains("fail") || lower.contains("reject") {
            return "Failed"
        }
        if lower.contains("cancel") {
            return "Cancelled"
        }
        if thread.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Draft"
        }
        return "Saved"
    }

    private func threadStatusColor(for thread: ChatThread) -> Color {
        switch threadStatusText(for: thread) {
        case "Running":
            return .blue
        case "Completed":
            return .green
        case "Failed", "Cancelled":
            return .red
        case "Draft":
            return .orange
        default:
            return .secondary
        }
    }

    private func hasDraftState(_ thread: ChatThread) -> Bool {
        !thread.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !thread.draftAttachments.isEmpty
    }

    private func draftPreview(for thread: ChatThread) -> String? {
        let trimmed = thread.draftText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        guard !thread.draftAttachments.isEmpty else { return nil }
        if thread.draftAttachments.count == 1 {
            return thread.draftAttachments[0].fileName
        }
        return "\(thread.draftAttachments.count) attachments"
    }
}
