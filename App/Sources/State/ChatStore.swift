import Foundation
import SwiftUI

/// Real `ChatStore`. Surfaces messages from the BrainClient transcript
/// and exposes a `send` action that pipes user text to the brain.
@MainActor
public final class ChatStore: ObservableObject {

    @Published public private(set) var messages: [BrainMessage] = []
    @Published public var draft: String = ""
    @Published public private(set) var sending: Bool = false

    private weak var brainClient: BrainClient?
    private var observation: Task<Void, Never>?

    public init() {}

    /// Bind to a `BrainClient` so `messages` mirrors its transcript.
    public func bind(to client: BrainClient) {
        brainClient = client
        observation?.cancel()
        observation = Task { [weak self] in
            // Lightweight polling is fine here — BrainClient.transcript
            // is a Published @MainActor property; we just want to
            // mirror it onto our published store. Using @Published
            // forwarding via Combine would be cleaner; this is the
            // minimum that works without adding another framework.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let bc = self.brainClient else { return }
                let latest = bc.transcript
                if self.messages.count != latest.count {
                    self.messages = latest
                }
            }
        }
    }

    public func send() async {
        guard let bc = brainClient else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await bc.sendChat(text)
            draft = ""
        } catch {
            // Surface as a system message so the user can see why nothing happened.
            appendSystemMessage("Send failed: \(error.localizedDescription)")
        }
    }

    /// Public helper for views that want to surface non-brain messages
    /// (errors, voice-pipeline failures) without having to reach into
    /// the published `messages` directly.
    public func appendSystemMessage(_ text: String) {
        messages.append(BrainMessage(role: .system, text: text))
    }
}
