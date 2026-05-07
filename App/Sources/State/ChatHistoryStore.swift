import Foundation

/// On-disk chat history store. One JSON file per session_id under
/// the app's Documents directory plus a single `index.json` that
/// tracks every session the user has ever opened.
///
/// Format on disk:
///   Documents/feral-chat/index.json          // [SessionMeta]
///   Documents/feral-chat/<sessionId>.json    // [BrainMessage] (codable)
///
/// The store is intentionally file-based JSON instead of Core Data:
///   * Core Data is overkill for a chat log
///   * UserDefaults has size + threading limits
///   * JSON files are trivially debuggable + survive app reinstalls
///     when iCloud Backup is enabled, and roll forward across model
///     versions because we control the codable struct.
///
/// Writes are debounced with `save(after:)` so rapid streams of
/// `audio_response` deltas don't thrash the disk.
@MainActor
public final class ChatHistoryStore: ObservableObject {

    public struct SessionMeta: Codable, Identifiable, Equatable {
        public let id: String              // session_id
        public var title: String           // best-effort first user msg
        public var lastUpdated: Date
        public var messageCount: Int

        public init(id: String, title: String = "New chat",
                    lastUpdated: Date = Date(), messageCount: Int = 0) {
            self.id = id
            self.title = title
            self.lastUpdated = lastUpdated
            self.messageCount = messageCount
        }
    }

    @Published public private(set) var sessions: [SessionMeta] = []
    @Published public private(set) var currentSessionId: String

    private let baseDir: URL
    private let indexURL: URL
    private var debounce: Task<Void, Never>? = nil

    /// Maximum messages persisted per session — older messages are
    /// dropped from disk to keep the file small. The brain still has
    /// the full transcript on its side.
    public static let maxMessagesPerSession: Int = 500

    public init(documentsURL: URL? = nil) {
        let docs = documentsURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.baseDir = docs.appendingPathComponent("feral-chat", isDirectory: true)
        self.indexURL = baseDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Restore index. If empty, mint a fresh session.
        let restored = Self.loadIndex(at: indexURL) ?? []
        self.sessions = restored
        if let head = restored.first {
            self.currentSessionId = head.id
        } else {
            let sid = UUID().uuidString
            self.currentSessionId = sid
            let meta = SessionMeta(id: sid)
            self.sessions = [meta]
            Self.persistIndex(self.sessions, at: indexURL)
        }
    }

    // MARK: - Public API

    /// Replace `currentSessionId`. Caller is responsible for swapping
    /// in the freshly-loaded transcript on the BrainClient side.
    public func switchTo(sessionId: String) {
        if !sessions.contains(where: { $0.id == sessionId }) {
            let meta = SessionMeta(id: sessionId)
            sessions.insert(meta, at: 0)
            persistIndex()
        }
        currentSessionId = sessionId
    }

    /// Mint a new session and select it. Returns the new id.
    @discardableResult
    public func newSession() -> String {
        let sid = UUID().uuidString
        let meta = SessionMeta(id: sid)
        sessions.insert(meta, at: 0)
        currentSessionId = sid
        persistIndex()
        return sid
    }

    public func deleteSession(_ sessionId: String) {
        sessions.removeAll { $0.id == sessionId }
        let url = baseDir.appendingPathComponent("\(sessionId).json")
        try? FileManager.default.removeItem(at: url)
        if currentSessionId == sessionId {
            currentSessionId = sessions.first?.id ?? newSession()
        }
        persistIndex()
    }

    /// Load messages for a session id from disk.
    public func loadMessages(for sessionId: String) -> [BrainMessage] {
        let url = baseDir.appendingPathComponent("\(sessionId).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CodableMessage].self, from: data))?
            .map { $0.toBrainMessage() } ?? []
    }

    /// Persist messages for a session id (debounced 500ms).
    public func save(_ messages: [BrainMessage], for sessionId: String) {
        debounce?.cancel()
        debounce = Task { [weak self, messages, sessionId] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self = self, !Task.isCancelled else { return }
            self.flushSave(messages, for: sessionId)
        }
    }

    /// Force an immediate flush — call from `scenePhase: .background`
    /// so we don't lose the last few messages if iOS suspends us.
    public func flushNow(_ messages: [BrainMessage], for sessionId: String) {
        debounce?.cancel()
        debounce = nil
        flushSave(messages, for: sessionId)
    }

    private func flushSave(_ messages: [BrainMessage], for sessionId: String) {
        let trimmed = Array(messages.suffix(Self.maxMessagesPerSession))
        let codable = trimmed.map(CodableMessage.init(from:))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = baseDir.appendingPathComponent("\(sessionId).json")
        if let data = try? encoder.encode(codable) {
            try? data.write(to: url, options: .atomic)
        }
        // Update the index entry.
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].lastUpdated = Date()
            sessions[idx].messageCount = trimmed.count
            if let firstUser = trimmed.first(where: { $0.role == .user }) {
                let title = String(firstUser.text.prefix(48))
                if !title.isEmpty { sessions[idx].title = title }
            }
        }
        sessions.sort { $0.lastUpdated > $1.lastUpdated }
        persistIndex()
    }

    private func persistIndex() {
        Self.persistIndex(sessions, at: indexURL)
    }

    private static func persistIndex(_ sessions: [SessionMeta], at url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func loadIndex(at url: URL) -> [SessionMeta]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([SessionMeta].self, from: data)
    }
}

/// Codable mirror of `BrainMessage` because BrainMessage's `Role` is
/// declared as a String-backed enum but BrainMessage itself is not
/// Codable today. We don't want to retrofit Codable onto the public
/// SDK type, so we mediate through this struct.
private struct CodableMessage: Codable {
    let id: UUID
    let role: String
    let text: String
    let timestamp: Date

    init(from msg: BrainMessage) {
        self.id = msg.id
        self.role = msg.role.rawValue
        self.text = msg.text
        self.timestamp = msg.timestamp
    }

    func toBrainMessage() -> BrainMessage {
        let r = BrainMessage.Role(rawValue: role) ?? .system
        return BrainMessage(id: id, role: r, text: text, timestamp: timestamp)
    }
}
