import Foundation
import SwiftUI

struct BrandHeaderView: View {
    let isConnected: Bool
    let statusText: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.97, blue: 1.0),
                            Color(red: 0.91, green: 0.95, blue: 1.0),
                            Color(red: 0.96, green: 0.98, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.55))
                .blur(radius: 18)
                .offset(x: 60, y: -34)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    MobaileLogoMark()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MOBaiLE")
                            .font(.title2.weight(.black))
                        Text("voice-first coding from your pocket")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text("Talk to the repo, stream execution progress, and keep the thread context close at hand.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            ConnectionBadge(isConnected: isConnected, statusText: statusText)
                .padding(12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
    }
}

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
}

struct ConversationWelcomeCard: View {
    let isConfigured: Bool
    let canRetryLastPrompt: Bool
    let onOpenSettings: () -> Void
    let onRetryLastPrompt: () -> Void
    let onUsePrompt: (String) -> Void

    private let starterPrompts = [
        StarterPrompt(
            label: "Summarize Repo",
            prompt: "summarize this repo and point out the most important modules"
        ),
        StarterPrompt(
            label: "Run Smoke Test",
            prompt: "run the recommended smoke test for this project and summarize the result"
        ),
        StarterPrompt(
            label: "Review Latest UI",
            prompt: "review the current UI and suggest the highest-impact improvements"
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                isConfigured ? "Ready for a new task" : "Finish setup before you start",
                systemImage: isConfigured ? "sparkles" : "server.rack"
            )
            .font(.headline)

            Text(
                isConfigured
                    ? "Type or record a prompt and MOBaiLE will stream the run back into this thread."
                    : "Add a server URL and API token in Settings so sending and voice recording are available."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if isConfigured {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try a quick start")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(starterPrompts.enumerated()), id: \.offset) { _, prompt in
                                Button(prompt.label) {
                                    onUsePrompt(prompt.prompt)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    if canRetryLastPrompt {
                        Button {
                            onRetryLastPrompt()
                        } label: {
                            Label("Retry last prompt", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Open Settings", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 1)
        )
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
                        Section {
                            SheetIntroCard(
                                title: "Saved Conversations",
                                message: "Switch threads, rename them, or delete old ones without losing your current context.",
                                systemImage: "text.bubble.fill",
                                tint: .blue
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(threads) { thread in
                            Button {
                                onSelect(thread.id)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(thread.title)
                                            .font(.body.weight(activeThreadID == thread.id ? .semibold : .regular))
                                            .lineLimit(1)
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
                                    if activeThreadID == thread.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
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
