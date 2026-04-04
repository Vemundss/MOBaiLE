import Foundation
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
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(0.12), lineWidth: 1)
        )
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
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
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
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(fill)
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
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct SettingsRuntimeDetailItem: Identifiable {
    let icon: String
    let label: String
    let value: String

    var id: String { label }
}

struct DraftAttachmentChip: View {
    let attachment: DraftAttachment
    let transferState: DraftAttachmentTransferState
    let isBusy: Bool
    let onRemove: () -> Void

    var body: some View {
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            return Color(.secondarySystemBackground)
        case .uploading:
            return tintColor.opacity(0.12)
        case .failed:
            return Color.red.opacity(0.10)
        }
    }
}

struct PairingConfirmationSheet: View {
    let pending: VoiceAgentViewModel.PendingPairing
    @Binding var trustHost: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

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

                if let warning = pending.localNetworkWarning {
                    Section("Network") {
                        Label("Local network HTTP detected", systemImage: "wifi.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Toggle("Trust this server", isOn: $trustHost)
                    Text("Trusted hosts auto-enable this toggle the next time you pair.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Button("Pair") {
                        onConfirm()
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
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
                            detail: "After install, open `backend/pairing-qr.png` on the computer. In MOBaiLE, tap Scan Pairing QR and point the phone at the screen."
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("What to do next")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("1. Open `backend/pairing-qr.png` on the computer.")
                            Text("2. Tap Scan Pairing QR in MOBaiLE.")
                            Text("3. Point the phone at the screen and confirm the pairing.")
                            Text("4. Later, run `mobaile status` on the computer. If your shell does not find it yet, run `~/.local/bin/mobaile status`.")
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
                        Text("If QR pairing is not available, open Settings and paste the `server_url` from `backend/pairing.json` plus `VOICE_AGENT_API_TOKEN` from `backend/.env`.")
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
