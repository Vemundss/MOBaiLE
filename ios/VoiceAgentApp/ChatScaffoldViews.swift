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
    let requiresRepair: Bool
    let statusText: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: requiresRepair ? "qrcode.viewfinder" : (isConnected ? "checkmark.circle.fill" : "gearshape.fill"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(requiresRepair ? Color.orange : (isConnected ? Color.green : Color.orange))

            VStack(alignment: .leading, spacing: 2) {
                Text(requiresRepair ? "Reconnect needed" : (isConnected ? "Connected" : "Setup needed"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderTint, lineWidth: 1)
        )
    }

    private var backgroundFill: Color {
        if requiresRepair {
            return Color.orange.opacity(0.12)
        }
        if isConnected {
            return Color.green.opacity(0.10)
        }
        return Color(.tertiarySystemGroupedBackground)
    }

    private var borderTint: Color {
        if requiresRepair {
            return Color.orange.opacity(0.20)
        }
        if isConnected {
            return Color.green.opacity(0.18)
        }
        return Color(.separator).opacity(0.12)
    }
}

private struct StarterPrompt {
    let label: String
    let prompt: String
    let systemImage: String
    let detail: String
}

struct EmptyStateRuntimeContext {
    let executor: String
    let model: String
    let effort: String?
    let workspace: String
}

struct ConversationEmptyStateView: View {
    let isConfigured: Bool
    let needsConnectionRepair: Bool
    let statusText: String
    let canRetryLastPrompt: Bool
    let runtimeContext: EmptyStateRuntimeContext?
    let onOpenSetupGuide: () -> Void
    let onOpenPairingScanner: () -> Void
    let onOpenSettings: () -> Void
    let onRetryLastPrompt: () -> Void
    let onStartVoiceMode: () -> Void
    let onUsePrompt: (String) -> Void

    private let starterPrompts = [
        StarterPrompt(
            label: "Map the repo",
            prompt: "summarize this repo and point out the most important modules",
            systemImage: "square.stack.3d.up",
            detail: "Get a quick codebase map."
        ),
        StarterPrompt(
            label: "Run Smoke Test",
            prompt: "run the recommended smoke test for this project and summarize the result",
            systemImage: "checkmark.seal",
            detail: "Check the current baseline first."
        ),
        StarterPrompt(
            label: "Review Latest UI",
            prompt: "review the current UI and suggest the highest-impact improvements",
            systemImage: "wand.and.stars",
            detail: "Tighten the current screen."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isConfigured && !needsConnectionRepair {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        MobaileLogoMark()
                            .frame(width: 38, height: 38)
                            .padding(5)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.systemBackground))
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Start with a focused task")
                                .font(.title3.weight(.semibold))
                            Text("Use a quick start or type below. Keeping the first run narrow makes the thread easier to scan.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Label(statusText, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.green.opacity(0.10))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.green.opacity(0.14), lineWidth: 1)
                            )
                    }

                    if let runtimeContext {
                        configuredRuntimeContextRow(context: runtimeContext)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Try one")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(starterPrompts, id: \.label) { prompt in
                            CompactStarterPromptButton(prompt: prompt) {
                                onUsePrompt(prompt.prompt)
                            }
                        }
                    }

                    if canRetryLastPrompt {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Button {
                                    onRetryLastPrompt()
                                } label: {
                                    Label("Retry last prompt", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    onStartVoiceMode()
                                } label: {
                                    Label("Start voice mode", systemImage: "waveform.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }

                            VStack(spacing: 10) {
                                Button {
                                    onRetryLastPrompt()
                                } label: {
                                    Label("Retry last prompt", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    onStartVoiceMode()
                                } label: {
                                    Label("Start voice mode", systemImage: "waveform.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        Label("Voice mode stays in the composer for fast hands-free follow-up.", systemImage: "waveform.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        MobaileLogoMark()
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(needsConnectionRepair ? "Reconnect this phone" : "Set up your computer first")
                                .font(.title3.weight(.semibold))
                            Text(
                                needsConnectionRepair
                                    ? "The saved connection on this phone is no longer valid. Open the latest pairing QR on your computer, then scan it again here."
                                    : "MOBaiLE is the remote control. Start the backend on your Mac or Linux machine, then scan one pairing QR in the app."
                            )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }

                    ConnectionBadge(
                        isConnected: isConfigured,
                        requiresRepair: needsConnectionRepair,
                        statusText: statusText
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("The fastest path")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        SetupStepRow(
                            stepNumber: 1,
                            systemImage: "laptopcomputer",
                            title: needsConnectionRepair ? "Open a fresh pairing QR on your computer" : "Run one install command on your computer",
                            detail: needsConnectionRepair
                                ? "Run `mobaile pair` on the computer if you need a new QR, then keep it visible on screen."
                                : "Use the guided bootstrap flow to install the backend, start it, and prepare pairing."
                        )
                        SetupStepRow(
                            stepNumber: 2,
                            systemImage: "qrcode.viewfinder",
                            title: needsConnectionRepair ? "Scan the QR again in MOBaiLE" : "Scan the pairing QR in MOBaiLE",
                            detail: "Open `backend/pairing-qr.png` on your computer, then tap Scan Pairing QR here and point the phone at the screen."
                        )
                        SetupStepRow(
                            stepNumber: 3,
                            systemImage: "slider.horizontal.3",
                            title: needsConnectionRepair ? "Use manual fields only if the QR is not practical" : "Use manual fields only as a fallback",
                            detail: "If you already have a server URL and token, you can enter them yourself in Settings."
                        )
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Button {
                                onOpenSetupGuide()
                            } label: {
                                Label(needsConnectionRepair ? "Show Repair Steps" : "Show Setup Steps", systemImage: "list.number")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                onOpenPairingScanner()
                            } label: {
                                Label(needsConnectionRepair ? "Scan Pairing QR Again" : "Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        VStack(spacing: 10) {
                            Button {
                                onOpenSetupGuide()
                            } label: {
                                Label(needsConnectionRepair ? "Show Repair Steps" : "Show Setup Steps", systemImage: "list.number")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                onOpenPairingScanner()
                            } label: {
                                Label(needsConnectionRepair ? "Scan Pairing QR Again" : "Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Button {
                        onOpenSettings()
                    } label: {
                        Label("Enter Manually", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(needsConnectionRepair ? Color.orange.opacity(0.08) : Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    needsConnectionRepair
                        ? Color.orange.opacity(0.18)
                        : Color(.separator).opacity(0.16),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.03), radius: 14, y: 6)
    }

    @ViewBuilder
    private func configuredRuntimeContextRow(context: EmptyStateRuntimeContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Connected runtime")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    EmptyStateMetaPill(systemImage: "sparkles", text: context.model)
                    EmptyStateMetaPill(systemImage: "bolt.horizontal.circle.fill", text: context.executor)
                    if let effort = context.effort {
                        EmptyStateMetaPill(systemImage: "brain.head.profile", text: effort)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        EmptyStateMetaPill(systemImage: "sparkles", text: context.model)
                        EmptyStateMetaPill(systemImage: "bolt.horizontal.circle.fill", text: context.executor)
                        if let effort = context.effort {
                            EmptyStateMetaPill(systemImage: "brain.head.profile", text: effort)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Text(context.workspace)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
        )
    }
}

private struct EmptyStateMetaPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(.systemBackground))
        )
        .overlay(
            Capsule()
                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
        )
    }
}

private struct CompactStarterPromptButton: View {
    let prompt: StarterPrompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(prompt.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.separator).opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SetupStepRow: View {
    let stepNumber: Int
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 30, height: 30)
                Text("\(stepNumber)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
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
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?

    init(
        title: String,
        message: String,
        tint: Color,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.tint = tint
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryAction = secondaryAction
    }

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

                if actionTitle != nil || secondaryActionTitle != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if let actionTitle, let action {
                                Button(actionTitle) {
                                    action()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            if let secondaryActionTitle, let secondaryAction {
                                Button(secondaryActionTitle) {
                                    secondaryAction()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            if let actionTitle, let action {
                                Button(actionTitle) {
                                    action()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            if let secondaryActionTitle, let secondaryAction {
                                Button(secondaryActionTitle) {
                                    secondaryAction()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
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
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(0.14), lineWidth: 1)
        )
    }
}

struct LogsView: View {
    let events: [ExecutionEvent]
    let diagnostics: RunDiagnostics?
    @Environment(\.dismiss) private var dismiss
    @State private var scope: LogScope = .highlights

    private enum LogScope: String, CaseIterable, Identifiable {
        case all
        case highlights

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:
                return "All"
            case .highlights:
                return "Highlights"
            }
        }

        var introTitle: String {
            switch self {
            case .all:
                return "Raw Execution Events"
            case .highlights:
                return "Run Highlights"
            }
        }

        var introMessage: String {
            switch self {
            case .all:
                return "Chat shows the curated live activity. This sheet keeps the full event tape for diagnostics."
            case .highlights:
                return "A quieter view of key milestones. Switch back to All if you need the raw event timeline."
            }
        }
    }

    private var effectiveDiagnostics: RunDiagnostics? {
        if let diagnostics {
            return diagnostics
        }
        guard !events.isEmpty else { return nil }
        return RunDiagnostics.derived(runId: "", status: "unknown", summary: "", events: events)
    }

    private var highlightEventCount: Int {
        events.filter(isHighlightEvent(_:)).count
    }

    private var displayedEvents: [ExecutionEvent] {
        let source: [ExecutionEvent]
        switch scope {
        case .all:
            source = events
        case .highlights:
            source = events.filter(isHighlightEvent(_:))
        }
        return Array(source.enumerated().reversed()).map(\.element)
    }

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
                            VStack(alignment: .leading, spacing: 12) {
                                SheetIntroCard(
                                    title: scope.introTitle,
                                    message: scope.introMessage,
                                    systemImage: "waveform.path.ecg",
                                    tint: .blue
                                )

                                if let effectiveDiagnostics {
                                    RunHealthSummaryCard(
                                        diagnostics: effectiveDiagnostics,
                                        highlightEventCount: highlightEventCount
                                    )
                                }

                                Picker("View", selection: $scope) {
                                    ForEach(LogScope.allCases) { option in
                                        Text(option.title)
                                            .tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(Array(displayedEvents.enumerated()), id: \.offset) { _, event in
                            LogEventRow(event: event)
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

    private func isHighlightEvent(_ event: ExecutionEvent) -> Bool {
        switch event.type {
        case "assistant.message", "chat.message", "run.completed", "run.failed", "run.blocked", "run.cancelled":
            return true
        case "activity.started", "activity.updated", "activity.completed":
            return true
        case "action.started", "action.completed":
            return true
        case "log.message":
            let lower = event.message.lowercased()
            return lower.contains("failed") || lower.contains("timed out") || lower.contains("blocked")
        default:
            return false
        }
    }
}

private struct LogEventRow: View {
    let event: ExecutionEvent

    private var descriptor: LogEventDescriptor {
        logEventDescriptor(for: event)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: descriptor.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(descriptor.tint)
                .frame(width: 30, height: 30)
                .background(descriptor.tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(descriptor.title)
                        .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 0)

                    if let metadata = logEventMetadata(for: event) {
                        Text(metadata)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(event.displayMessage ?? event.message)
                    .font(descriptor.usesMonospacedBody ? .footnote.monospaced() : .footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct RunHealthSummaryCard: View {
    let diagnostics: RunDiagnostics
    let highlightEventCount: Int

    private var statusLabel: String {
        logDiagnosticStatusLabel(for: diagnostics.status)
    }

    private var statusTint: Color {
        logDiagnosticStatusTint(for: diagnostics.status)
    }

    private var latestActivity: String? {
        normalizedLogSummaryText(diagnostics.latestActivity)
    }

    private var summary: String? {
        normalizedLogSummaryText(diagnostics.summary)
    }

    private var lastError: String? {
        normalizedLogSummaryText(diagnostics.lastError)
    }

    private var orderedStageCounts: [(String, Int)] {
        diagnostics.activityStageCounts
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                let leftRank = logStageSortRank(lhs.key)
                let rightRank = logStageSortRank(rhs.key)
                if leftRank == rightRank {
                    return lhs.key < rhs.key
                }
                return leftRank < rightRank
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run Health")
                        .font(.subheadline.weight(.semibold))

                    if let latestActivity {
                        Text("Latest activity")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(latestActivity)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let summary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusTint.opacity(0.12))
                    .clipShape(Capsule())
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    LogSummaryPill(systemImage: "doc.text", text: "\(diagnostics.eventCount) raw events", tint: .blue)
                    LogSummaryPill(systemImage: "sparkles", text: "\(highlightEventCount) highlights", tint: .purple)
                    if diagnostics.hasStderr {
                        LogSummaryPill(systemImage: "exclamationmark.bubble.fill", text: "stderr seen", tint: .orange)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    LogSummaryPill(systemImage: "doc.text", text: "\(diagnostics.eventCount) raw events", tint: .blue)
                    LogSummaryPill(systemImage: "sparkles", text: "\(highlightEventCount) highlights", tint: .purple)
                    if diagnostics.hasStderr {
                        LogSummaryPill(systemImage: "exclamationmark.bubble.fill", text: "stderr seen", tint: .orange)
                    }
                }
            }

            if !orderedStageCounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stages")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ForEach(orderedStageCounts, id: \.0) { stage, count in
                                LogSummaryPill(
                                    systemImage: logStageSystemImage(for: stage),
                                    text: "\(logStageTitle(for: stage)) ×\(count)",
                                    tint: logStageTint(for: stage)
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(orderedStageCounts, id: \.0) { stage, count in
                                LogSummaryPill(
                                    systemImage: logStageSystemImage(for: stage),
                                    text: "\(logStageTitle(for: stage)) ×\(count)",
                                    tint: logStageTint(for: stage)
                                )
                            }
                        }
                    }
                }
            }

            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.red.opacity(0.10))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct LogSummaryPill: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct LogEventDescriptor {
    let title: String
    let systemImage: String
    let tint: Color
    let usesMonospacedBody: Bool
}

private func logEventDescriptor(for event: ExecutionEvent) -> LogEventDescriptor {
    let lowerMessage = event.message.lowercased()

    switch event.type {
    case "assistant.message", "chat.message":
        return LogEventDescriptor(title: "Assistant Update", systemImage: "text.bubble.fill", tint: .blue, usesMonospacedBody: false)
    case "activity.started", "activity.updated", "activity.completed":
        return LogEventDescriptor(
            title: event.title ?? logStageTitle(for: event.stage),
            systemImage: logStageSystemImage(for: event.stage),
            tint: logActivityTint(for: event),
            usesMonospacedBody: false
        )
    case "action.started":
        if lowerMessage.contains("starting write_file") {
            return LogEventDescriptor(title: "Writing Files", systemImage: "square.and.pencil", tint: .blue, usesMonospacedBody: false)
        }
        if lowerMessage.contains("starting run_command") {
            return LogEventDescriptor(title: "Running Command", systemImage: "terminal", tint: .blue, usesMonospacedBody: false)
        }
        if lowerMessage.contains("starting calendar adapter") {
            return LogEventDescriptor(title: "Checking Calendar", systemImage: "calendar", tint: .blue, usesMonospacedBody: false)
        }
        if lowerMessage.contains("starting codex exec") || lowerMessage.contains("starting claude exec") {
            return LogEventDescriptor(title: "Agent Started", systemImage: "sparkles", tint: .blue, usesMonospacedBody: false)
        }
        return LogEventDescriptor(title: "Action Started", systemImage: "play.circle.fill", tint: .blue, usesMonospacedBody: false)
    case "action.completed":
        let didFail = lowerMessage.contains("failed") || lowerMessage.contains("unsupported")
        return LogEventDescriptor(
            title: didFail ? "Action Reported a Problem" : "Action Completed",
            systemImage: didFail ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
            tint: didFail ? .orange : .green,
            usesMonospacedBody: false
        )
    case "action.stdout":
        return LogEventDescriptor(title: "Command Output", systemImage: "text.alignleft", tint: .secondary, usesMonospacedBody: true)
    case "action.stderr":
        return LogEventDescriptor(title: "Command Error", systemImage: "exclamationmark.bubble.fill", tint: .red, usesMonospacedBody: true)
    case "run.completed":
        return LogEventDescriptor(title: "Run Completed", systemImage: "checkmark.circle.fill", tint: .green, usesMonospacedBody: false)
    case "run.failed":
        return LogEventDescriptor(title: "Run Failed", systemImage: "xmark.circle.fill", tint: .red, usesMonospacedBody: false)
    case "run.blocked":
        return LogEventDescriptor(title: "Needs Input", systemImage: "hand.raised.fill", tint: .orange, usesMonospacedBody: false)
    case "run.cancelled":
        return LogEventDescriptor(title: "Run Cancelled", systemImage: "slash.circle.fill", tint: .secondary, usesMonospacedBody: false)
    case "log.message":
        return LogEventDescriptor(title: "Internal Log", systemImage: "doc.plaintext", tint: .secondary, usesMonospacedBody: true)
    default:
        return LogEventDescriptor(title: event.type, systemImage: "circle.fill", tint: .secondary, usesMonospacedBody: false)
    }
}

private func logEventMetadata(for event: ExecutionEvent) -> String? {
    var parts: [String] = []
    if let stage = normalizedLogSummaryText(event.stage) {
        parts.append(logStageTitle(for: stage))
    }
    parts.append(event.type)
    if let actionIndex = event.actionIndex {
        parts.append("step \(actionIndex + 1)")
    }
    if let seq = event.seq {
        parts.append("#\(seq)")
    }
    if let level = normalizedLogSummaryText(event.level), level != "info" {
        parts.append(level.uppercased())
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private func normalizedLogSummaryText(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func logDiagnosticStatusLabel(for rawStatus: String) -> String {
    let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if status.contains("block") || status.contains("input") {
        return "Needs Input"
    }
    if status.contains("timed out") {
        return "Timed Out"
    }
    if status.contains("fail") || status.contains("reject") {
        return "Failed"
    }
    if status.contains("cancel") {
        return "Cancelled"
    }
    if status.contains("complete") {
        return "Completed"
    }
    if status.contains("run") || status.contains("execut") || status.contains("planning") || status.contains("summar") {
        return "Running"
    }
    if status.isEmpty || status == "unknown" {
        return "In Progress"
    }
    return status.capitalized
}

private func logDiagnosticStatusTint(for rawStatus: String) -> Color {
    let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if status.contains("block") || status.contains("input") {
        return .orange
    }
    if status.contains("timed out") || status.contains("fail") || status.contains("reject") {
        return .red
    }
    if status.contains("cancel") {
        return .secondary
    }
    if status.contains("complete") {
        return .green
    }
    return .blue
}

private func logStageSortRank(_ stage: String) -> Int {
    switch stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "planning":
        return 0
    case "executing":
        return 1
    case "summarizing":
        return 2
    case "blocked":
        return 3
    default:
        return 99
    }
}

private func logStageTitle(for rawStage: String?) -> String {
    let stage = rawStage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch stage {
    case "planning":
        return "Planning"
    case "executing":
        return "Executing"
    case "summarizing":
        return "Summarizing"
    case "blocked":
        return "Needs Input"
    default:
        return stage.isEmpty ? "Activity" : stage.capitalized
    }
}

private func logStageSystemImage(for rawStage: String?) -> String {
    let stage = rawStage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch stage {
    case "planning":
        return "list.bullet"
    case "executing":
        return "terminal"
    case "summarizing":
        return "text.bubble.fill"
    case "blocked":
        return "hand.raised.fill"
    default:
        return "waveform.path.ecg"
    }
}

private func logStageTint(for rawStage: String?) -> Color {
    let stage = rawStage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch stage {
    case "planning":
        return .blue
    case "executing":
        return .indigo
    case "summarizing":
        return .green
    case "blocked":
        return .orange
    default:
        return .secondary
    }
}

private func logActivityTint(for event: ExecutionEvent) -> Color {
    switch event.level?.lowercased() {
    case "error":
        return .red
    case "warning":
        return .orange
    default:
        return logStageTint(for: event.stage)
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
                        Section {
                            SheetIntroCard(
                                title: "Chats",
                                message: "Switch threads here. The current thread stays pinned at the top so it is easy to jump back.",
                                systemImage: "bubble.left.and.bubble.right",
                                tint: .blue
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(displayedThreads) { thread in
                            Button {
                                onSelect(thread.id)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    threadIcon(for: thread)

                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Text(thread.title)
                                                .font(.body.weight(activeThreadID == thread.id ? .semibold : .regular))
                                                .lineLimit(1)

                                            Spacer(minLength: 0)

                                            Text(thread.updatedAt, style: .relative)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                        }

                                        Text(threadPreview(for: thread))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)

                                        HStack(spacing: 8) {
                                            Text(threadStatusText(for: thread))
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(threadStatusColor(for: thread).opacity(0.14))
                                                .foregroundStyle(threadStatusColor(for: thread))
                                                .clipShape(Capsule())

                                            if activeThreadID == thread.id {
                                                Text("Current")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.accentColor.opacity(0.12))
                                                    .foregroundStyle(Color.accentColor)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(activeThreadID == thread.id ? Color.accentColor.opacity(0.06) : Color(.secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(
                                        activeThreadID == thread.id
                                            ? Color.accentColor.opacity(0.16)
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
            .navigationTitle("Chats")
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
        if thread.presentationStatus == .ready {
            return "Ready for a new prompt."
        }
        return "No messages yet."
    }

    private func threadStatusText(for thread: ChatThread) -> String {
        thread.presentationStatus.label
    }

    private func threadStatusColor(for thread: ChatThread) -> Color {
        switch thread.presentationStatus {
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed, .cancelled:
            return .red
        case .needsInput, .draft:
            return .orange
        case .ready:
            return .blue
        default:
            return .secondary
        }
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

    @ViewBuilder
    private func threadIcon(for thread: ChatThread) -> some View {
        let tint = threadStatusColor(for: thread)
        let symbol: String = switch thread.presentationStatus {
        case .draft:
            "square.and.pencil"
        case .running:
            "waveform.path.ecg"
        case .needsInput:
            "hand.raised.fill"
        case .completed:
            "checkmark.circle.fill"
        case .failed, .cancelled:
            "exclamationmark.circle.fill"
        case .ready:
            "bubble.left.and.bubble.right.fill"
        default:
            "bubble.left.and.bubble.right.fill"
        }

        Image(systemName: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.12), lineWidth: 1)
            )
    }
}
