import SwiftUI

struct RuntimeInfoBar: View {
    @ObservedObject var vm: VoiceAgentViewModel
    let activeNavigationTitle: String
    let runtimeDirectorySummary: String
    let runtimeDirectoryLabel: String
    let runtimeDescriptorSummary: String
    let shouldShowRuntimeStatusBadge: Bool
    let runtimeStatusText: String
    let runtimeStatusIcon: String
    let runtimeStatusTint: Color
    let onOpenThreads: () -> Void
    let onOpenWorkspace: () -> Void
    let onOpenPairingScanner: () -> Void
    let onOpenSetupGuide: () -> Void

    var body: some View {
        Group {
            if !vm.hasConfiguredConnection || vm.needsConnectionRepair {
                setupRuntimeInfoBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                compactRuntimeInfoBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground))
        .overlay(
            Rectangle()
                .fill(Color(.separator).opacity(0.35))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var setupRuntimeInfoBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: vm.needsConnectionRepair ? "qrcode.viewfinder" : "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(vm.needsConnectionRepair ? .orange : .accentColor)
                .frame(width: 34, height: 34)
                .background((vm.needsConnectionRepair ? Color.orange : Color.accentColor).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.needsConnectionRepair ? "Reconnect this phone" : "Finish setup to start a run")
                    .font(.subheadline.weight(.semibold))
                Text(
                    vm.needsConnectionRepair
                        ? "Open the latest pairing QR on your computer, then scan it again here."
                        : "Run one install command on your computer, then scan the pairing QR here."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Group {
                if vm.needsConnectionRepair {
                    Button("Scan QR Again", action: onOpenPairingScanner)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Setup Guide", action: onOpenSetupGuide)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(vm.needsConnectionRepair ? Color.orange.opacity(0.12) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    vm.needsConnectionRepair
                        ? Color.orange.opacity(0.20)
                        : Color(.separator).opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    private var compactRuntimeInfoBar: some View {
        ViewThatFits(in: .horizontal) {
            compactRuntimeInfoStrip(showDescriptor: true)
            compactRuntimeInfoStrip(showDescriptor: false)
        }
    }

    private func compactRuntimeInfoStrip(showDescriptor: Bool) -> some View {
        HStack(spacing: 8) {
            runtimeThreadButton
            runtimeWorkspaceButton
            if showDescriptor {
                runtimeDescriptorBadge
            }
            if shouldShowRuntimeStatusBadge {
                RuntimeStatusBadge(
                    text: runtimeStatusText,
                    systemImage: runtimeStatusIcon,
                    tint: runtimeStatusTint
                )
            }
            if vm.isVoiceModeActiveForCurrentThread {
                RuntimeStatusBadge(
                    text: vm.voiceModeStatusText,
                    systemImage: "waveform.circle.fill",
                    tint: .blue
                )
            }
        }
        .padding(.vertical, 2)
    }

    private var runtimeDescriptorBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
            Text(runtimeDescriptorSummary)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            Capsule()
                .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
        )
    }

    private var runtimeThreadButton: some View {
        Button(action: onOpenThreads) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text(activeNavigationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .overlay(
                Capsule()
                    .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open chats")
    }

    private var runtimeWorkspaceButton: some View {
        Group {
            if vm.needsConnectionRepair {
                Button(action: onOpenPairingScanner) {
                    Label("Scan QR Again", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
            } else if vm.hasConfiguredConnection {
                Button(action: onOpenWorkspace) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(runtimeDirectorySummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(.tertiarySystemGroupedBackground))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color(.separator).opacity(0.10), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse workspace \(runtimeDirectoryLabel)")
            } else {
                Button(action: onOpenSetupGuide) {
                    Label("Setup Guide", systemImage: "list.number")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
    }
}
