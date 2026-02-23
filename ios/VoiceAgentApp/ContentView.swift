import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Text(vm.executor.uppercased())
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(Capsule())
                            if !vm.resolvedWorkingDirectory.isEmpty {
                                Text("cwd: \(vm.resolvedWorkingDirectory)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.top, 4)

                        ForEach(vm.conversation) { message in
                            HStack {
                                if message.role == "user" {
                                    Spacer(minLength: 52)
                                }
                                Text(message.text)
                                    .font(.body)
                                    .lineSpacing(1.5)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
                                    .background(
                                        message.role == "user"
                                            ? Color.blue
                                            : Color(.secondarySystemBackground)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                                Text(vm.statusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(spacing: 8) {
                            TextEditor(text: $vm.promptText)
                                .frame(minHeight: 50, maxHeight: 100)
                                .padding(6)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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
                                    .disabled(vm.apiToken.isEmpty || vm.serverURL.isEmpty || vm.promptText.isEmpty || vm.isRecording)
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
            .navigationTitle("MOBaiLE")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showConnectionSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat") {
                        vm.startNewChat()
                    }
                    .font(.subheadline.weight(.semibold))
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
                            TextField("Timeout seconds", text: $vm.runTimeoutSeconds)
                                .keyboardType(.numberPad)
                            Picker("Executor", selection: $vm.executor) {
                                Text("Local").tag("local")
                                Text("Codex").tag("codex")
                            }
                            .pickerStyle(.segmented)
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
            .onChange(of: vm.didCompleteRun) {
                if vm.didCompleteRun {
                    showConnectionSettings = false
                }
            }
        }
    }

    private func shortRunID(_ runID: String) -> String {
        if runID.count <= 8 {
            return runID
        }
        return String(runID.prefix(8))
    }
}

#Preview {
    ContentView()
}
