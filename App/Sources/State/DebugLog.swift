import Foundation
import SwiftUI

/// In-app rolling log so the operator can debug WITHOUT being attached
/// to Xcode. Every notable event (pair attempt, brain probe, adapter
/// activation, error) is appended here; the Settings tab renders the
/// last N entries in chronological order.
@MainActor
public final class DebugLog: ObservableObject {

    public struct Entry: Identifiable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let level: Level
        public let message: String

        public enum Level: String, Equatable {
            case info, warning, error, success
        }
    }

    @Published public private(set) var entries: [Entry] = []
    private let capacity: Int

    public static let shared = DebugLog()

    public init(capacity: Int = 200) {
        self.capacity = capacity
    }

    public func info(_ message: String) { append(.info, message) }
    public func warning(_ message: String) { append(.warning, message) }
    public func error(_ message: String) { append(.error, message) }
    public func success(_ message: String) { append(.success, message) }

    public func clear() { entries.removeAll() }

    private func append(_ level: Entry.Level, _ message: String) {
        let entry = Entry(id: UUID(), timestamp: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        // Lane 11 (audit-r14) — DEBUG-only console mirror. The
        // Release build no longer emits one ``NSLog`` per UI event
        // (the prior behaviour leaked the entire chat / pair /
        // memory-fetch trace into Console.app for anyone with
        // physical access to the device, even with the in-app
        // viewer hidden). The in-app entries list is unchanged so
        // operators can still inspect history from Settings.
        #if DEBUG
        let stamp = ISO8601DateFormatter().string(from: entry.timestamp)
        NSLog("[FERAL][\(level.rawValue.uppercased())] \(stamp) \(message)")
        #endif
    }
}
