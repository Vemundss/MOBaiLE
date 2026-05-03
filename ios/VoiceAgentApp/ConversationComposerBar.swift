import QuickLook
import SwiftUI
import UIKit

private let composerEstimatedCharactersPerLine = 38

private func estimatedComposerDisplayLineCount(
    _ text: String,
    charactersPerLine: Int = composerEstimatedCharactersPerLine
) -> Int {
    let safeCharactersPerLine = max(1, charactersPerLine)
    let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard !paragraphs.isEmpty else { return 1 }

    return paragraphs.reduce(0) { total, paragraph in
        let wrappedLines = max(1, (paragraph.count + safeCharactersPerLine - 1) / safeCharactersPerLine)
        return total + wrappedLines
    }
}

func _test_estimatedComposerDisplayLineCount(_ text: String, charactersPerLine: Int) -> Int {
    estimatedComposerDisplayLineCount(text, charactersPerLine: charactersPerLine)
}

struct ConversationComposerBar: View {
    @ObservedObject var vm: VoiceAgentViewModel
    let composerFocused: FocusState<Bool>.Binding
    let bottomRunStatusText: String
    let hasVisibleLiveActivityMessage: Bool
    let shouldShowRecordingNotice: Bool
    let onOpenLogs: () -> Void
    let onOpenAttachmentOptions: () -> Void
    let onRecordingButtonTap: () -> Void
    let onRecordingStopTap: () -> Void
    let onVoiceModeButtonTap: () -> Void
    let onSend: () -> Void
    let onSelectSlashCommand: (ComposerSlashCommand, ComposerSlashCommandState) -> Void
    @State private var previewAttachment: DraftAttachment?
    @State private var attachmentPreviewError: String = ""
    @ScaledMetric(relativeTo: .body) private var composerCompactHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var composerExpandedMinimumHeight: CGFloat = 88
    @ScaledMetric(relativeTo: .body) private var composerMaximumHeight: CGFloat = 158
    @ScaledMetric(relativeTo: .body) private var composerLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var composerVerticalChrome: CGFloat = 28

    var body: some View {
        VStack(spacing: 8) {
            if shouldShowRecordingNotice {
                recordingStatusBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let unblock = vm.pendingHumanUnblockRequest, !vm.isLoading {
                InlineNoticeCard(
                    title: "Continue this run",
                    message: unblock.instructions,
                    tint: .orange,
                    systemImage: "hand.raised.fill",
                    actionTitle: "Use Suggested Reply",
                    action: {
                        vm.prepareHumanUnblockReply()
                        composerFocused.wrappedValue = true
                    }
                )
            }

            if let retryNotice = runRetryNotice {
                InlineNoticeCard(
                    title: retryNotice.title,
                    message: retryNotice.message,
                    tint: .red,
                    systemImage: "arrow.clockwise.circle.fill",
                    actionTitle: "Retry Last Prompt",
                    action: onSendRetryPrompt,
                    secondaryActionTitle: vm.events.isEmpty ? nil : "Open Run Logs",
                    secondaryAction: vm.events.isEmpty ? nil : onOpenLogs
                )
            }

            if let attachmentFailureNotice = vm.draftAttachmentFailureNotice, !vm.isLoading {
                InlineNoticeCard(
                    title: "Attachment needs attention",
                    message: attachmentFailureNotice,
                    tint: .red,
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: nil,
                    action: nil
                )
            }

            VStack(spacing: 10) {
                if shouldShowComposerSummaryRow && !vm.isRecording {
                    composerSummaryRow
                }

                if shouldShowVoiceInteractionNotice {
                    voiceInteractionNoticeCard
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !vm.draftAttachments.isEmpty && !vm.isRecording {
                    if let attachmentSummary = vm.draftAttachmentSummaryText {
                        HStack {
                            ComposerMetaPill(
                                text: attachmentSummary,
                                systemImage: "paperclip",
                                tint: vm.hasInvalidDraftAttachments ? .red : .secondary
                            )
                            Spacer(minLength: 0)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.draftAttachments) { attachment in
                                DraftAttachmentChip(
                                    attachment: attachment,
                                    transferState: vm.draftAttachmentTransferState(for: attachment),
                                    isBusy: vm.isLoading,
                                    onPreview: { previewDraftAttachment(attachment) },
                                    onRemove: { vm.removeDraftAttachment(attachment) }
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let slashState = composerSlashCommandState, !vm.isRecording {
                    ComposerSlashCommandMenu(
                        state: slashState,
                        onSelect: { command in
                            onSelectSlashCommand(command, slashState)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if vm.isRecording {
                    recordingComposerRow
                } else {
                    standardComposerRow
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 18, y: 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: vm.isRecording)
        .animation(.easeInOut(duration: 0.18), value: shouldShowRecordingNotice)
        .animation(.easeInOut(duration: 0.18), value: vm.voiceInteractionNoticeText)
        .sheet(item: $previewAttachment) { attachment in
            FilePreviewSheet(
                url: attachment.localFileURL,
                title: attachment.fileName,
                originalPath: attachment.localFileURL.path
            )
        }
        .alert("Preview unavailable", isPresented: Binding(
            get: { !attachmentPreviewError.isEmpty },
            set: { if !$0 { attachmentPreviewError = "" } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentPreviewError)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    let downward = value.translation.height
                    let sideways = abs(value.translation.width)
                    guard downward > 24, downward > sideways else { return }
                    composerFocused.wrappedValue = false
                }
        )
    }

    private func previewDraftAttachment(_ attachment: DraftAttachment) {
        if QLPreviewController.canPreview(attachment.localFileURL as NSURL) {
            previewAttachment = attachment
        } else {
            attachmentPreviewError = "This attachment type can't be previewed on iPhone."
        }
    }

    private var composerSlashCommandState: ComposerSlashCommandState? {
        vm.composerSlashCommandState
    }

    private var canUseConnectedFeatures: Bool {
        vm.hasConfiguredConnection && !vm.needsConnectionRepair
    }

    private var composerSummaryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if vm.isVoiceModeActiveForCurrentThread {
                    Button(action: onToggleVoiceModeFromSummary) {
                        ComposerMetaPill(
                            text: vm.voiceModeStatusText,
                            systemImage: "waveform.circle.fill",
                            tint: .blue
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("End voice mode")
                }

                if shouldShowComposerStatusSummary {
                    ComposerMetaPill(
                        text: composerStatusSummaryText,
                        systemImage: composerStatusSummaryIcon,
                        tint: composerStatusSummaryTint
                    )
                }

                if !vm.runID.isEmpty && shouldShowComposerStatusSummary && !hasVisibleLiveActivityMessage {
                    Text("Run \(shortRunID(vm.runID))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var shouldShowVoiceInteractionNotice: Bool {
        !vm.isRecording && !shouldShowRecordingNotice && vm.voiceInteractionNoticeText != nil
    }

    private var voiceInteractionNoticeCard: some View {
        InlineNoticeCard(
            title: "Voice mode",
            message: vm.voiceInteractionNoticeText ?? "",
            tint: .blue,
            systemImage: "waveform.circle",
            actionTitle: nil,
            action: nil
        )
    }

    private var standardComposerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            embeddedComposerUtilityActions
            composerTextEditorSurface
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            composerPrimaryActionButton
        }
        .padding(.horizontal, shouldUseExpandedComposerLayout ? 10 : 6)
        .padding(.vertical, shouldUseExpandedComposerLayout ? 8 : 6)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    composerFocused.wrappedValue
                        ? Color.accentColor.opacity(0.30)
                        : Color(.separator).opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    private var shouldUseExpandedComposerLayout: Bool {
        vm.hasDraftContent
    }

    private var composerTextEditorSurface: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $vm.promptText)
                .focused(composerFocused)
                .accessibilityIdentifier("composer.textEditor")
                .accessibilityLabel("Prompt")
                .font(.body)
                .lineSpacing(2)
                .textInputAutocapitalization(.sentences)
                .textContentType(.none)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
                .frame(height: composerHeight, alignment: .topLeading)
                .onTapGesture {
                    composerFocused.wrappedValue = true
                }

            if vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(composerPlaceholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 7)
                    .padding(.top, 12)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
            }
        }
    }

    private var embeddedComposerUtilityActions: some View {
        HStack(spacing: 2) {
            Button(action: handleOpenAttachmentOptions) {
                ComposerEmbeddedButtonLabel(
                    systemImage: "plus",
                    tint: vm.draftAttachments.isEmpty ? Color.secondary : Color.accentColor,
                    fill: vm.draftAttachments.isEmpty ? Color(.tertiarySystemGroupedBackground) : Color.accentColor.opacity(0.16)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add context")
            .disabled(!canUseConnectedFeatures || vm.isLoading)
            .opacity((!canUseConnectedFeatures || vm.isLoading) ? 0.45 : 1)

            let canStartVoiceMode = !vm.isLoading && canUseConnectedFeatures
            Button(action: handleVoiceModeButtonTap) {
                ComposerEmbeddedButtonLabel(
                    systemImage: vm.isVoiceModeActiveForCurrentThread ? "waveform.circle.fill" : "waveform.circle",
                    tint: Color.blue,
                    fill: vm.isVoiceModeActiveForCurrentThread ? Color.blue.opacity(0.16) : Color(.tertiarySystemGroupedBackground)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.isVoiceModeActiveForCurrentThread ? "End voice mode" : "Start voice mode")
            .disabled(!vm.isVoiceModeActiveForCurrentThread && !canStartVoiceMode)
            .opacity((!vm.isVoiceModeActiveForCurrentThread && !canStartVoiceMode) ? 0.45 : 1)
        }
    }

    private var composerPrimaryActionButtonConfiguration: ComposerPrimaryActionConfiguration {
        if vm.canCancelActiveOperation {
            return ComposerPrimaryActionConfiguration(
                systemImage: "stop.fill",
                tint: .white,
                fill: .red,
                size: 34,
                iconSize: 11,
                weight: .semibold,
                accessibilityLabel: vm.activeOperationCancelAccessibilityLabel,
                isDisabled: false,
                opacity: 1
            ) {
                composerFocused.wrappedValue = false
                vm.cancelActiveOperation()
            }
        }

        if vm.hasDraftContent {
            return ComposerPrimaryActionConfiguration(
                systemImage: "arrow.up",
                tint: .white,
                fill: .accentColor,
                size: 34,
                iconSize: 13,
                weight: .bold,
                accessibilityLabel: "Send prompt",
                isDisabled: !canUseConnectedFeatures || !vm.hasDraftContent || vm.isLoading,
                opacity: (!canUseConnectedFeatures || !vm.hasDraftContent || vm.isLoading) ? 0.45 : 1
            ) {
                onSend()
            }
        }

        return ComposerPrimaryActionConfiguration(
            systemImage: "mic.fill",
            tint: .white,
            fill: .blue,
            size: 34,
            iconSize: 13,
            weight: .bold,
            accessibilityLabel: "Start recording",
            isDisabled: vm.isLoading || !canUseConnectedFeatures,
            opacity: (vm.isLoading || !canUseConnectedFeatures) ? 0.45 : 1
        ) {
            composerFocused.wrappedValue = false
            onRecordingButtonTap()
        }
    }

    private var composerPrimaryActionButton: some View {
        let configuration = composerPrimaryActionButtonConfiguration
        return Button(action: configuration.action) {
            ComposerActionButtonLabel(
                systemImage: configuration.systemImage,
                tint: configuration.tint,
                fill: configuration.fill,
                size: configuration.size,
                iconSize: configuration.iconSize,
                weight: configuration.weight
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configuration.accessibilityLabel)
        .disabled(configuration.isDisabled)
        .opacity(configuration.opacity)
        .frame(width: 40, height: 40)
    }

    private var recordingComposerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                recordingComposerDetails
                Spacer(minLength: 0)
                recordingComposerActions
            }

            VStack(alignment: .leading, spacing: 10) {
                recordingComposerDetails
                HStack {
                    Spacer(minLength: 0)
                    recordingComposerActions
                }
            }
        }
    }

    private var recordingComposerDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)

                Text("Listening")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let startedAt = vm.recordingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(recordingDurationLabel(since: startedAt, now: context.date))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }

            Text(recordingSubtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !recordingContextItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(recordingContextItems.enumerated()), id: \.offset) { _, item in
                            ComposerMetaPill(
                                text: item.text,
                                systemImage: item.systemImage,
                                tint: item.tint
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private var recordingComposerActions: some View {
        HStack(spacing: 10) {
            Button(action: onRecordingStopTap) {
                ComposerActionButtonLabel(
                    systemImage: "stop.fill",
                    tint: .white,
                    fill: .red,
                    size: 42,
                    iconSize: 12,
                    weight: .bold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.isVoiceModeActiveForCurrentThread ? "Stop voice mode" : "Discard recording")

            Button(action: onRecordingButtonTap) {
                ComposerActionButtonLabel(
                    systemImage: "paperplane.fill",
                    tint: .white,
                    fill: .accentColor,
                    size: 42,
                    iconSize: 12,
                    weight: .bold
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice prompt")
        }
    }

    private var shouldShowComposerStatusSummary: Bool {
        guard !vm.isRecording else { return false }
        guard runRetryNotice == nil else { return false }

        let lower = composerStatusSummaryText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lower.isEmpty, lower != "idle" else { return false }

        if lower == "ready for prompts" || lower == "completed" {
            return false
        }

        if hasVisibleLiveActivityMessage && isProgressChromeStatus(composerStatusSummaryText) {
            return false
        }

        if vm.isLoading || vm.isUploadingAttachments {
            return true
        }

        return lower.contains("input")
            || lower.contains("blocked")
            || lower.contains("fail")
            || lower.contains("cancel")
            || lower.contains("timed out")
            || lower.contains("upload")
            || lower.contains("start")
            || lower.contains("preparing")
            || lower.contains("transcrib")
            || lower.contains("microphone")
            || lower.contains("recorder")
            || lower.contains("access")
            || lower.contains("set server")
            || lower.contains("token")
    }

    private var shouldShowComposerSummaryRow: Bool {
        vm.isVoiceModeActiveForCurrentThread || shouldShowComposerStatusSummary
    }

    private var runRetryNotice: (title: String, message: String)? {
        guard !vm.isLoading,
              !vm.needsConnectionRepair,
              !vm.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              vm.pendingHumanUnblockRequest == nil,
              vm.canRetryLastPrompt else {
            return nil
        }

        let lower = vm.statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        if lower.contains("upload failed") || lower.contains("failed to start recording") {
            return nil
        }

        if lower.contains("timed out") {
            return (
                "Run timed out",
                "Retry the last prompt or inspect Run Logs."
            )
        }

        if lower.contains("cancel") {
            return (
                "Run stopped early",
                "Retry the last prompt or inspect Run Logs."
            )
        }

        if lower.contains("fail") || lower.contains("rejected") {
            return (
                "Run failed",
                "Retry the last prompt or inspect Run Logs."
            )
        }

        return nil
    }

    private var composerStatusSummaryText: String {
        bottomRunStatusText
    }

    private var composerStatusSummaryIcon: String {
        let lower = composerStatusSummaryText.lowercased()
        if lower.contains("input") || lower.contains("blocked") {
            return "hand.raised.fill"
        }
        if lower.contains("fail") || lower.contains("cancel") || lower.contains("timed out") {
            return "exclamationmark.circle.fill"
        }
        if lower.contains("complete") {
            return "checkmark.circle.fill"
        }
        if vm.isLoading || lower.contains("think") || lower.contains("plan") || lower.contains("execut") || lower.contains("summar") {
            return "bolt.horizontal.circle.fill"
        }
        return "info.circle.fill"
    }

    private var composerStatusSummaryTint: Color {
        let lower = composerStatusSummaryText.lowercased()
        if lower.contains("input") || lower.contains("blocked") {
            return .orange
        }
        if lower.contains("fail") || lower.contains("cancel") || lower.contains("timed out") {
            return .red
        }
        if lower.contains("complete") {
            return .green
        }
        if vm.isLoading || lower.contains("think") || lower.contains("plan") || lower.contains("execut") || lower.contains("summar") {
            return .blue
        }
        return .secondary
    }

    private var attachmentSummaryText: String {
        if vm.draftAttachments.count == 1 {
            return "1 attachment"
        }
        return "\(vm.draftAttachments.count) attachments"
    }

    private var hasRecordingDraftText: Bool {
        !vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recordingTypedNoteSummaryText: String? {
        guard hasRecordingDraftText else { return nil }
        return vm.draftAttachments.isEmpty ? "Typed note" : "Typed note + files"
    }

    private var composerHeight: CGFloat {
        let trimmed = vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shouldUseExpandedComposerLayout && trimmed.isEmpty {
            return composerCompactHeight
        }

        let displayLineCount = estimatedComposerDisplayLineCount(vm.promptText)
        let naturalHeight = CGFloat(displayLineCount) * composerLineHeight + composerVerticalChrome
        let minimumHeight = shouldUseExpandedComposerLayout ? composerExpandedMinimumHeight : composerCompactHeight
        let maximumHeight = max(minimumHeight, composerMaximumHeight)
        return min(maximumHeight, max(minimumHeight, naturalHeight))
    }

    private var composerPlaceholder: String {
        if vm.needsConnectionRepair {
            return "Reconnect to send"
        }
        if !vm.hasConfiguredConnection {
            return "Connect backend"
        }
        if vm.isRecording {
            return "Voice recording in progress"
        }
        if vm.draftAttachments.isEmpty {
            return composerFocused.wrappedValue ? "Type a prompt or /" : "Type a prompt"
        }
        return composerFocused.wrappedValue ? "Add a note or /" : "Add a note"
    }

    private var recordingStatusBanner: some View {
        Group {
            if vm.isRecording, let startedAt = vm.recordingStartedAt {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recording voice prompt")
                            .font(.caption.weight(.semibold))
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text("\(recordingDurationLabel(since: startedAt, now: context.date)) • \(recordingSubtitle)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(vm.usesAutoSendForCurrentTurn ? "Auto-send" : "Manual")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.usesAutoSendForCurrentTurn ? .blue : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background((vm.usesAutoSendForCurrentTurn ? Color.blue : Color.secondary).opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.red.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if vm.statusText == "Microphone access needed" {
                InlineNoticeCard(
                    title: "Microphone access is off",
                    message: "Enable microphone permission for MOBaiLE in iOS Settings, then try recording again.",
                    tint: .orange,
                    systemImage: "mic.slash.fill",
                    actionTitle: "Open App Settings",
                    action: openAppSettings
                )
            } else {
                InlineNoticeCard(
                    title: "Recording unavailable",
                    message: vm.errorText.isEmpty ? "The app couldn't start the microphone." : vm.errorText,
                    tint: .red,
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: nil,
                    action: nil
                )
            }
        }
    }

    private var recordingSubtitle: String {
        if vm.isVoiceModeActiveForCurrentThread {
            return "Pause to auto-send. Voice mode resumes after the reply."
        }
        if vm.usesAutoSendForCurrentTurn {
            return "Pause to auto-send this prompt."
        }
        return "Tap send when you are ready."
    }

    private var recordingContextItems: [(text: String, systemImage: String, tint: Color)] {
        var items: [(text: String, systemImage: String, tint: Color)] = []
        if vm.isVoiceModeActiveForCurrentThread {
            items.append(("Voice mode", "waveform.circle.fill", .blue))
        }
        if let recordingTypedNoteSummaryText {
            items.append((recordingTypedNoteSummaryText, "square.and.pencil", .secondary))
        }
        if !vm.draftAttachments.isEmpty {
            items.append((attachmentSummaryText, "paperclip", .secondary))
        }
        return items
    }

    private func shortRunID(_ runID: String) -> String {
        if runID.count <= 8 {
            return runID
        }
        return String(runID.prefix(8))
    }

    private func isProgressChromeStatus(_ rawText: String) -> Bool {
        let lower = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lower.isEmpty else { return false }

        if lower.contains("input")
            || lower.contains("blocked")
            || lower.contains("fail")
            || lower.contains("cancel")
            || lower.contains("timed out")
            || lower.contains("reconnect")
            || lower.contains("setup")
            || lower.contains("attention") {
            return false
        }

        return lower.contains("think")
            || lower.contains("plan")
            || lower.contains("execut")
            || lower.contains("summar")
            || lower.contains("start")
            || lower.contains("prepar")
            || lower.contains("running")
    }

    private func recordingDurationLabel(since startedAt: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    private func handleOpenAttachmentOptions() {
        composerFocused.wrappedValue = false
        onOpenAttachmentOptions()
    }

    private func handleVoiceModeButtonTap() {
        composerFocused.wrappedValue = false
        onVoiceModeButtonTap()
    }

    private func onToggleVoiceModeFromSummary() {
        onVoiceModeButtonTap()
    }

    private func onSendRetryPrompt() {
        Task { await vm.retryLastPrompt() }
    }
}

private struct ComposerEmbeddedButtonLabel: View {
    let systemImage: String
    let tint: Color
    let fill: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 32, height: 32)

            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 38, height: 38)
        .contentShape(Circle())
    }
}
