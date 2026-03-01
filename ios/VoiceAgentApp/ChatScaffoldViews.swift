import Foundation
import SwiftUI

struct BrandHeaderView: View {
    var body: some View {
        HStack(spacing: 10) {
            MobaileLogoMark()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("MOBaiLE")
                    .font(.title2.weight(.black))
                Text("your pocket coding buddy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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

struct LogsView: View {
    let events: [ExecutionEvent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(events.enumerated().reversed()), id: \.offset) { _, event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.type)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(event.message)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
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

    var body: some View {
        NavigationStack {
            List {
                ForEach(threads) { thread in
                    Button {
                        onSelect(thread.id)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title)
                                    .font(.body.weight(activeThreadID == thread.id ? .semibold : .regular))
                                    .lineLimit(1)
                                Text(thread.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if activeThreadID == thread.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            onDelete(thread.id)
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
        }
    }
}
