import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()
    @State private var showConnectionSettings: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(vm.executor.uppercased())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Capsule())
                        Spacer()
                        Button(showConnectionSettings ? "Hide Settings" : "Show Settings") {
                            showConnectionSettings.toggle()
                        }
                        .font(.caption.weight(.semibold))
                    }
                    if !vm.resolvedWorkingDirectory.isEmpty {
                        Text("cwd: \(vm.resolvedWorkingDirectory)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    if showConnectionSettings {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Server URL", text: $vm.serverURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote.monospaced())
                            SecureField("API Token", text: $vm.apiToken)
                                .font(.footnote.monospaced())
                            HStack {
                                TextField("Session ID", text: $vm.sessionID)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                TextField("Working dir", text: $vm.workingDirectory)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            HStack {
                                Text("Timeout (sec)")
                                    .foregroundStyle(.secondary)
                                TextField("300", text: $vm.runTimeoutSeconds)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.footnote.monospaced())
                            Picker("Executor", selection: $vm.executor) {
                                Text("Local").tag("local")
                                Text("Codex").tag("codex")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(vm.conversation) { message in
                                HStack {
                                    if message.role == "user" {
                                        Spacer(minLength: 44)
                                    }
                                    Text(message.text)
                                        .font(.body)
                                        .padding(10)
                                        .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
                                        .background(
                                            message.role == "user"
                                                ? Color.blue
                                                : Color(.secondarySystemBackground)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    if message.role != "user" {
                                        Spacer(minLength: 44)
                                    }
                                }
                                .id(message.id)
                            }
                            if vm.conversation.isEmpty {
                                Text("Conversation will appear here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: vm.conversation.count) {
                        if let last = vm.conversation.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: vm.didCompleteRun) {
                        if vm.didCompleteRun {
                            showConnectionSettings = false
                        }
                    }
                }

                VStack(spacing: 8) {
                    TextEditor(text: $vm.promptText)
                        .frame(minHeight: 64, maxHeight: 120)
                        .padding(6)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 8) {
                        Button(vm.isLoading ? "Running..." : "Send") {
                            Task { await vm.sendPrompt() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isLoading || vm.apiToken.isEmpty || vm.serverURL.isEmpty || vm.promptText.isEmpty)

                        Button(vm.isRecording ? "Recording..." : "Record") {
                            Task { await vm.startRecording() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isLoading || vm.isRecording || vm.apiToken.isEmpty || vm.serverURL.isEmpty)

                        Button("Stop + Send") {
                            Task { await vm.stopRecordingAndSend() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isLoading || !vm.isRecording || vm.apiToken.isEmpty || vm.serverURL.isEmpty)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    if !vm.runID.isEmpty {
                        Text("Run: \(vm.runID)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text(vm.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !vm.errorText.isEmpty {
                    Text(vm.errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("MOBaiLE")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat") {
                        vm.startNewChat()
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
