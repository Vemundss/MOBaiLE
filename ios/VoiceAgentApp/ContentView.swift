import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
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
                    .font(.footnote.monospaced())
                    HStack {
                        Picker("Executor", selection: $vm.executor) {
                            Text("Local").tag("local")
                            Text("Codex").tag("codex")
                        }
                        .pickerStyle(.segmented)
                    }
                    if !vm.resolvedWorkingDirectory.isEmpty {
                        Text("cwd: \(vm.resolvedWorkingDirectory)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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
            .navigationTitle("Voice Agent MVP")
        }
    }
}

#Preview {
    ContentView()
}
