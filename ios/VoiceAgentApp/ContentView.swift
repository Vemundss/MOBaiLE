import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings = false
    @State private var showLogs = false
    @State private var showThreads = false
    @State private var newDirectoryName = ""
    @State private var trustPairHost = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        BrandHeaderView()
                            .padding(.top, 6)

                        ForEach(vm.conversation) { message in
                            HStack {
                                if message.role == "user" {
                                    Spacer(minLength: 52)
                                }
                                MessageBubble(message: message, serverURL: vm.serverURL, apiToken: vm.apiToken)
                                if message.role != "user" {
                                    Spacer(minLength: 52)
                                }
                            }
                            .id(message.id)
                        }

                        if vm.conversation.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Start by typing or recording a prompt.")
                                    .font(.subheadline.weight(.medium))
                                Text("MOBaiLE will stream the agent response here.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 20)
                        }

                        if !vm.errorText.isEmpty {
                            Text(vm.errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .safeAreaInset(edge: .top, spacing: 8) {
                    runtimeInfoBar
                }
                .onChange(of: vm.conversation.count) {
                    if let last = vm.conversation.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if !vm.statusText.isEmpty && vm.statusText != "Idle" {
                            HStack {
                                if !vm.runID.isEmpty {
                                    Text("Run \(shortRunID(vm.runID))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if vm.isLoading {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                                Text(bottomRunStatusText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $vm.promptText)
                                    .focused($composerFocused)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .frame(height: composerHeight)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                if vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Message MOBaiLE")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 12)
                                        .padding(.top, 14)
                                        .allowsHitTesting(false)
                                }
                            }
                            .animation(.easeInOut(duration: 0.16), value: composerHeight)

                            HStack(spacing: 10) {
                                Button {
                                    Task {
                                        if vm.isRecording {
                                            await vm.stopRecordingAndSend()
                                        } else {
                                            await vm.startRecording()
                                        }
                                    }
                                } label: {
                                    Image(systemName: vm.isRecording ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.bordered)
                                .tint(vm.isRecording ? .red : .blue)
                                .disabled(vm.isLoading || vm.apiToken.isEmpty || vm.serverURL.isEmpty)

                                Spacer()

                                if vm.isLoading && !vm.runID.isEmpty {
                                    Button("Cancel") {
                                        Task { await vm.cancelCurrentRun() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                } else {
                                    Button("Send") {
                                        Task { await vm.sendPrompt() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(
                                        vm.apiToken.isEmpty ||
                                        vm.serverURL.isEmpty ||
                                        vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                        vm.isRecording
                                    )
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showConnectionSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            showThreads = true
                        } label: {
                            Image(systemName: "text.bubble")
                        }
                        .accessibilityLabel("Threads")
                        Button {
                            showLogs = true
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        Button("New Chat") {
                            vm.startNewChat()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .sheet(isPresented: $showConnectionSettings) {
                NavigationStack {
                    Form {
                        Section("Connection") {
                            TextField("Server URL", text: $vm.serverURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote.monospaced())
                            SecureField("API Token", text: $vm.apiToken)
                                .font(.footnote.monospaced())
                            TextField("Session ID", text: $vm.sessionID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Section("Execution") {
                            TextField("Working directory", text: $vm.workingDirectory)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote.monospaced())
                            Text("Folder where commands run and files are created. In safe mode, this must stay inside the backend workdir root.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Timeout seconds", text: $vm.runTimeoutSeconds)
                                .keyboardType(.numberPad)
                            Text("Max time to wait for a run before the app marks it as timed out.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Agent guidance", selection: $vm.agentGuidanceMode) {
                                Text("Guided").tag("guided")
                                Text("Minimal").tag("minimal")
                            }
                            .pickerStyle(.segmented)
                            Text(vm.agentGuidanceMode == "minimal"
                                ? "Minimal: keeps chat focused on final results with fewer progress updates."
                                : "Guided: includes short progress updates and clearer result context.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            LabeledContent("Chat detail", value: "Concise")
                            Text("Verbose chat mode removed. Use Run Logs for full execution events.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if vm.developerMode {
                                Picker("Executor", selection: $vm.executor) {
                                    Text("Local").tag("local")
                                    Text("Codex").tag("codex")
                                }
                                .pickerStyle(.segmented)
                            } else {
                                LabeledContent("Executor", value: "Codex")
                            }
                        }
                        Section("App") {
                            Toggle("Developer Mode", isOn: $vm.developerMode)
                            LabeledContent("Backend mode", value: vm.backendSecurityMode)
                            Text(vm.developerMode
                                ? "Enables local executor switching."
                                : "Keeps production-safe defaults (Codex executor only).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showConnectionSettings = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showThreads) {
                ThreadsView(
                    threads: vm.sortedThreads,
                    activeThreadID: vm.activeThreadID,
                    onSelect: { threadID in
                        vm.switchToThread(threadID)
                        showThreads = false
                    },
                    onRename: { threadID, title in
                        vm.renameThread(threadID, title: title)
                    },
                    onDelete: { threadID in
                        vm.deleteThread(threadID)
                    },
                    onNewChat: {
                        vm.startNewChat()
                        showThreads = false
                    }
                )
            }
            .sheet(isPresented: $showLogs) {
                LogsView(events: vm.events)
            }
            .task {
                await vm.bootstrapSessionIfNeeded()
            }
            .onChange(of: vm.didCompleteRun) {
                if vm.didCompleteRun {
                    showConnectionSettings = false
                    composerFocused = false
                }
            }
            .onChange(of: vm.serverURL) {
                vm.hideDirectoryBrowser()
                vm.persistSettings()
            }
            .onChange(of: vm.apiToken) {
                vm.hideDirectoryBrowser()
                vm.persistSettings()
            }
            .onChange(of: vm.sessionID) { vm.persistSettings() }
            .onChange(of: vm.workingDirectory) {
                vm.hideDirectoryBrowser()
                vm.persistSettings()
            }
            .onChange(of: vm.runTimeoutSeconds) { vm.persistSettings() }
            .onChange(of: vm.agentGuidanceMode) { vm.persistSettings() }
            .onChange(of: vm.executor) { vm.persistSettings() }
            .onChange(of: vm.developerMode) { vm.persistSettings() }
            .onChange(of: vm.pendingPairing) {
                guard let pending = vm.pendingPairing else {
                    trustPairHost = false
                    return
                }
                trustPairHost = vm.isTrustedPairHost(pending.serverHost)
            }
            .onOpenURL { url in
                vm.applyPairingURL(url)
            }
            .sheet(item: Binding(
                get: { vm.pendingPairing },
                set: { if $0 == nil { vm.cancelPendingPairing() } }
            )) { pending in
                PairingConfirmationSheet(
                    pending: pending,
                    trustHost: $trustPairHost,
                    onCancel: { vm.cancelPendingPairing() },
                    onConfirm: {
                        vm.confirmPendingPairing(trustHost: trustPairHost)
                    }
                )
            }
        }
    }

    private func shortRunID(_ runID: String) -> String {
        if runID.count <= 8 {
            return runID
        }
        return String(runID.prefix(8))
    }

    private var bottomRunStatusText: String {
        if vm.runPhaseText == "Planning" || vm.runPhaseText == "Executing" || vm.runPhaseText == "Summarizing" {
            return "Thinking"
        }
        if vm.runPhaseText != "Idle" {
            return vm.runPhaseText
        }
        return vm.statusText
    }

    private var composerHeight: CGFloat {
        let trimmed = vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !composerFocused && trimmed.isEmpty {
            return 44
        }
        let lineCount = max(1, vm.promptText.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(152, max(76, CGFloat(lineCount) * 24 + 30))
    }

    private var runtimeExecutorLabel: String {
        let value = vm.runID.isEmpty ? (vm.developerMode ? vm.executor : "codex") : vm.activeRunExecutor
        return value.uppercased()
    }

    private var runtimeDirectoryLabel: String {
        let resolved = vm.resolvedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return vm.workingDirectory
    }

    private var runtimeInfoBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(runtimeExecutorLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
                if !vm.runID.isEmpty {
                    Text("run: \(shortRunID(vm.runID))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !vm.statusText.isEmpty && vm.statusText != "Idle" {
                    Text(vm.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await vm.toggleDirectoryBrowser() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: vm.showDirectoryBrowser ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("cwd: \(runtimeDirectoryLabel)")
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if vm.showDirectoryBrowser {
                directoryBrowserPanel
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground).opacity(0.96))
        .overlay(
            Rectangle()
                .fill(Color(.separator).opacity(0.35))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var directoryBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if vm.directoryBreadcrumbs.isEmpty {
                            Text(runtimeDirectoryLabel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(vm.directoryBreadcrumbs) { crumb in
                                Button(crumb.title) {
                                    Task { await vm.openDirectory(path: crumb.path) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                Button {
                    Task { await vm.navigateDirectoryUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!vm.canNavigateDirectoryUp || vm.isLoadingDirectoryBrowser)

                Button {
                    Task { await vm.refreshDirectoryBrowser() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(vm.isLoadingDirectoryBrowser)
            }

            HStack(spacing: 6) {
                TextField("New folder", text: $newDirectoryName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption2.monospaced())
                    .textFieldStyle(.roundedBorder)
                Button("Create") {
                    Task {
                        let created = await vm.createDirectoryInCurrentBrowser(name: newDirectoryName)
                        if created {
                            newDirectoryName = ""
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(
                    vm.isLoadingDirectoryBrowser ||
                    newDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if vm.isLoadingDirectoryBrowser {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading folder contents...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !vm.directoryBrowserError.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.directoryBrowserError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if !vm.directoryBrowserMissingPath.isEmpty {
                        Button("Create missing directory") {
                            Task { await vm.createDirectoryFromBrowser() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
            } else if vm.directoryBrowserEntries.isEmpty {
                Text("No files found in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.directoryBrowserEntries.prefix(20)) { entry in
                    Button {
                        Task { await vm.openDirectoryEntry(entry) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                .font(.caption2)
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                            Text(entry.name)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if entry.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isDirectory)
                }
                if vm.directoryBrowserTruncated {
                    Text("Showing first 20 entries.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PairingConfirmationSheet: View {
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


#Preview {
    ContentView()
}
