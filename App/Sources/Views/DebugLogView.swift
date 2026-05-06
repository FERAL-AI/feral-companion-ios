import SwiftUI

/// Shows the last N `DebugLog` entries. Linked from Settings tab
/// so the operator can see exactly what the app is doing without
/// attaching Xcode.
struct DebugLogView: View {
    @ObservedObject var log: DebugLog = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if log.entries.isEmpty {
                    Text("No log entries yet. Try pairing or activating an adapter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(log.entries.reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        circle(for: entry.level)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stamp(entry.timestamp))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                        }
                    }
                    .listRowSeparatorTint(.gray.opacity(0.3))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Debug log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { log.clear() }
                }
            }
        }
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func color(for level: DebugLog.Entry.Level) -> Color {
        switch level {
        case .info: return .white
        case .warning: return .yellow
        case .error: return .red
        case .success: return .green
        }
    }

    @ViewBuilder
    private func circle(for level: DebugLog.Entry.Level) -> some View {
        Circle().fill(color(for: level))
    }
}
