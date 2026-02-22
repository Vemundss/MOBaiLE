import SwiftUI

struct ContentView: View {
    @StateObject private var vm = VoiceAgentViewModel()

    var body: some View {
        NavigationView {
            Form {
                Section("Connection") {
                    TextField("Server URL", text: $vm.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Token", text: $vm.apiToken)
                    TextField("Session ID", text: $vm.sessionID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Run") {
                    Picker("Executor", selection: $vm.executor) {
                        Text("Local").tag("local")
                        Text("Codex").tag("codex")
                    }
                    .pickerStyle(.segmented)

                    TextEditor(text: $vm.promptText)
                        .frame(minHeight: 80)

                    Button(vm.isLoading ? "Running..." : "Send Prompt") {
                        Task { await vm.sendPrompt() }
                    }
                    .disabled(vm.isLoading || vm.apiToken.isEmpty || vm.serverURL.isEmpty || vm.promptText.isEmpty)

                    HStack {
                        Button(vm.isRecording ? "Recording..." : "Start Recording") {
                            Task { await vm.startRecording() }
                        }
                        .disabled(vm.isLoading || vm.isRecording || vm.apiToken.isEmpty || vm.serverURL.isEmpty)

                        Button("Stop & Send Audio") {
                            Task { await vm.stopRecordingAndSend() }
                        }
                        .disabled(vm.isLoading || !vm.isRecording || vm.apiToken.isEmpty || vm.serverURL.isEmpty)
                    }

                    if !vm.runID.isEmpty {
                        Text("Run ID: \(vm.runID)")
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                    Text(vm.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !vm.summaryText.isEmpty {
                    Section("Summary") {
                        Text(vm.summaryText)
                    }
                }

                if !vm.transcriptText.isEmpty {
                    Section("Transcript") {
                        Text(vm.transcriptText)
                    }
                }

                if !vm.errorText.isEmpty {
                    Section("Error") {
                        Text(vm.errorText)
                            .foregroundColor(.red)
                    }
                }

                Section("Events") {
                    if vm.events.isEmpty {
                        Text("No events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.type)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.body)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Voice Agent MVP")
        }
    }
}

#Preview {
    ContentView()
}
