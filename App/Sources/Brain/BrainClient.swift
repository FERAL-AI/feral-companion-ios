import Foundation
import Combine

/// Thin SwiftUI-friendly wrapper around the SDK's `FeralNode` actor.
/// Exposes the brain connection as an `ObservableObject` so views can
/// bind to connection state and inbound frames without juggling actor
/// hops in every view-model.
///
/// Lifecycle is owned by the host app (typically by `AppEnvironment`
/// at app launch and by `ConnectionStore` once the user pairs).
@MainActor
public final class BrainClient: ObservableObject {

    /// Top-level connection state observable by SwiftUI.
    public enum State: Equatable {
        case disconnected
        case connecting(brainURL: URL)
        case connected(brainURL: URL, sessionToken: String?)
        case reconnecting
        case failed(message: String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published public private(set) var state: State = .disconnected

    /// Test-only seam used by `FeralCompanionTests` to drive the
    /// idempotency guard inside `ConnectionStore.connect()` without
    /// opening a real WebSocket. Must not be called from product code
    /// (the underlying transport is the only legitimate state writer);
    /// pinned by `_ConnectionStoreConnectIdempotencyTests`.
    public func _setStateForTesting(_ newState: State) {
        self.state = newState
    }

    /// Latest text turns from the brain (oldest first). Hosts append
    /// user-typed messages here too so chat views render uniformly.
    @Published public private(set) var transcript: [BrainMessage] = []

    /// Latest live transcript line from voice (partial or final).
    /// Cleared after each utterance ends.
    @Published public private(set) var liveTranscript: String? = nil

    /// `true` while the brain is mid-stream (assistant response in
    /// progress). Used by views to render typing indicators.
    @Published public private(set) var isAssistantSpeaking: Bool = false

    /// Stable conversation id sent on every `chat_request`. The brain's
    /// `ChatRequestPayload` requires a non-empty `session_id`. We
    /// generate one per BrainClient lifetime so multiple turns share
    /// orchestrator context. If the brain returns a different
    /// `session_id` on the first `chat_response`, we adopt that.
    @Published public private(set) var chatSessionId: String = UUID().uuidString

    /// Stable voice stream id emitted on `voice_session_start`. Reset
    /// when a new voice session opens.
    @Published public private(set) var voiceStreamId: String = UUID().uuidString

    /// `true` while a phone-mic voice session is open (between
    /// `startVoice()` and `stopVoice()`). Owned here so any view can
    /// bind without duplicating capture state, and so app-level
    /// lifecycle teardown (`scenePhase: .background`) can stop the
    /// session cleanly without reaching into a SwiftUI view's
    /// `@State`.
    @Published public private(set) var voiceActive: Bool = false

    private var node: FeralNode?
    private var inboundTask: Task<Void, Never>?
    private let audioPlayback: AudioPlayback
    private weak var history: ChatHistoryStore?
    private var historyCancellables: Set<AnyCancellable> = []
    private var audioCapture: AudioCapture?

    public init(audioPlayback: AudioPlayback? = nil) {
        self.audioPlayback = audioPlayback ?? AudioPlayback()
    }

    // MARK: - History binding

    /// Bind a `ChatHistoryStore` so:
    ///   1. The most recent session's transcript is restored on cold launch.
    ///   2. `chatSessionId` aligns with the store's `currentSessionId`.
    ///   3. Every `transcript` change is debounced-saved to disk.
    ///   4. When the store switches sessions, our transcript reloads.
    public func bindHistory(_ store: ChatHistoryStore) {
        self.history = store
        self.chatSessionId = store.currentSessionId
        self.transcript = store.loadMessages(for: store.currentSessionId)

        // Persist on every transcript change.
        $transcript
            .dropFirst()
            .sink { [weak self] msgs in
                guard let self = self, let h = self.history else { return }
                h.save(msgs, for: self.chatSessionId)
            }
            .store(in: &historyCancellables)

        // Reload when the user switches conversations.
        store.$currentSessionId
            .dropFirst()
            .sink { [weak self] sid in
                guard let self = self, let h = self.history else { return }
                self.chatSessionId = sid
                self.transcript = h.loadMessages(for: sid)
            }
            .store(in: &historyCancellables)
    }

    /// Force a synchronous flush of the current transcript — call from
    /// `scenePhase: .background` so iOS suspending the app doesn't
    /// lose the last few messages.
    public func flushHistory() {
        guard let h = history else { return }
        h.flushNow(transcript, for: chatSessionId)
    }

    // MARK: - Lifecycle

    /// Open the WebSocket and run `node_register`. The provided
    /// `adapters` are registered before connect so their capabilities
    /// land in the brain's first-ack.
    public func connect(
        brainURL: URL,
        apiKey: String,
        nodeId: String,
        adapters: [VendorAdapter]
    ) async {
        await disconnect()

        state = .connecting(brainURL: brainURL)

        let node = FeralNode(brainURL: brainURL, apiKey: apiKey, nodeID: nodeId)
        for adapter in adapters {
            await node.register(adapter: adapter)
        }
        self.node = node

        // Subscribe to inbound frames BEFORE connecting so we don't
        // miss the very first node_ack.
        inboundTask = Task { [weak self] in
            guard let stream = await self?.node?.inboundFrames else { return }
            for await frame in stream {
                await self?.handleInbound(frame)
            }
        }

        do {
            try await node.connect()
            // Wire the JWBle session so glasses_status emits actually
            // reach the brain. The audit confirmed bind(brainNode:)
            // had zero call sites in the iOS tree before Phase 1 —
            // this is the call site. Safe to run regardless of whether
            // the user has activated the Theora capability: when the
            // session phase later transitions to `.ready`/`.failed`,
            // those emits are now delivered to the brain's
            // node_subdevices store via `device_event` envelopes.
            JWBleSession.shared.bind(brainNode: node)
            // Connection state flips to .connected when we observe
            // the first node_ack frame in handleInbound.
        } catch {
            state = .failed(message: error.localizedDescription)
            self.node = nil
            inboundTask?.cancel()
            inboundTask = nil
        }
    }

    public func disconnect() async {
        // Tear down voice first so the WS doesn't drop while audio is
        // mid-stream — the brain's voice_router prefers a clean
        // is_final chunk to a half-open socket.
        await stopVoice()
        inboundTask?.cancel()
        inboundTask = nil
        if let node = node {
            try? await node.sendNodeBye(reason: "user_disconnect")
            await node.disconnect()
        }
        node = nil
        state = .disconnected
    }

    // MARK: - Outbound

    /// Send a chat message. Brain replies via `chat_response` on the
    /// inbound stream and we append it to ``transcript``. Uses the
    /// schema-correct values from `Info.swift` enums — pass an explicit
    /// `sessionId` to override the per-client default.
    public func sendChat(_ text: String, sessionId: String? = nil) async throws {
        guard let node else { throw BrainClientError.notConnected }
        let sid = sessionId ?? chatSessionId
        transcript.append(BrainMessage(role: .user, text: text))
        try await node.sendChatRequest(
            text: text,
            sessionId: sid,
            replyMode: .final,
            channel: .chat
        )
    }

    /// Begin a voice session. Call before streaming audio chunks.
    /// Defaults to `openai_realtime` + VAD + barge-in, the same as
    /// the brain's daemon_session voice path expects when a phone
    /// node hasn't customized provider selection.
    public func startVoiceSession() async throws {
        guard let node else { throw BrainClientError.notConnected }
        // Mint a fresh stream id every session so the brain's voice
        // router treats consecutive starts as distinct sessions.
        voiceStreamId = UUID().uuidString
        try await node.startVoiceSession(
            streamId: voiceStreamId,
            voiceMode: .openaiRealtime,
            sampleRate: 24000,
            channels: 1,
            mode: .vad,
            interruptPolicy: .bargeIn
        )
    }

    public func sendAudioChunk(_ pcm: Data, isFinal: Bool = false) async throws {
        guard let node else { throw BrainClientError.notConnected }
        try await node.sendAudioChunk(pcmData: pcm, isFinal: isFinal)
    }

    public func interruptVoice() async throws {
        guard let node else { throw BrainClientError.notConnected }
        try await node.interruptVoiceSession(streamId: voiceStreamId)
    }

    // MARK: - Voice lifecycle

    /// Start a phone-mic voice session: open the brain-side voice
    /// session, spin up `AudioCapture`, and begin streaming PCM16
    /// chunks. `voiceActive` flips to `true` so any bound view sees
    /// the live state without polling.
    ///
    /// Idempotent: a second call while a session is already running
    /// is a no-op so the UI button can't double-allocate the engine.
    public func startVoice() async throws {
        if voiceActive { return }
        try await startVoiceSession()
        let capture = AudioCapture()
        try capture.start { [weak self] chunk in
            // The capture callback runs off the main actor on an
            // AVAudioEngine tap queue. Hop back to the actor's send
            // path; failures are logged but don't tear down capture
            // (the brain's voice_router tolerates dropped chunks).
            Task { [weak self] in
                try? await self?.sendAudioChunk(chunk, isFinal: false)
            }
        }
        self.audioCapture = capture
        self.voiceActive = true
    }

    /// Stop the current phone-mic voice session. Sends an empty
    /// `is_final: true` chunk so the brain's voice_router sees a
    /// clean end-of-utterance, then tears down `AudioCapture`.
    /// Safe to call when no session is running.
    public func stopVoice() async {
        guard voiceActive || audioCapture != nil else { return }
        audioCapture?.stop()
        audioCapture = nil
        voiceActive = false
        try? await sendAudioChunk(Data(), isFinal: true)
    }

    // MARK: - Inbound dispatch

    private func handleInbound(_ frame: HUPFrame) async {
        switch frame.type {
        case "node_ack":
            let session: String? = {
                if case .string(let s) = frame.payload["session_token"] ?? .null { return s }
                return nil
            }()
            if case .connecting(let url) = state {
                state = .connected(brainURL: url, sessionToken: session)
            } else if case .reconnecting = state {
                // The SDK auto-reconnected; stay in connected.
                state = .connected(
                    brainURL: (try? extractBrainURL()) ?? URL(string: "ws://localhost")!,
                    sessionToken: session
                )
            }

        case "chat_response", "text_response":
            // If the brain echoed back a session_id, adopt it so future
            // chat_request frames thread onto the same orchestrator
            // session. Brain handler builds the session_id deterministically
            // for phone nodes (server.py daemon_session chat branch).
            if case .string(let sid) = frame.payload["session_id"] ?? .null, !sid.isEmpty {
                if sid != chatSessionId { chatSessionId = sid }
            }
            if case .string(let text) = frame.payload["text"] ?? .null, !text.isEmpty {
                transcript.append(BrainMessage(role: .assistant, text: text))
                isAssistantSpeaking = false
            }

        case "transcript":
            let text: String = {
                if case .string(let s) = frame.payload["text"] ?? .null { return s }
                return ""
            }()
            let isPartial: Bool = {
                if case .bool(let b) = frame.payload["is_partial"] ?? .null { return b }
                return false
            }()
            // Honor the explicit `role` field from the brain (added
            // 2026-05-08 to fix the "every chat bubble looks like a
            // user message" bug — iOS used to hardcode every
            // transcript as `.user` regardless of who spoke). The
            // brain always tags role on the wire now; we fall back
            // to `.assistant` for missing-role frames because in
            // practice the only legitimate untagged transcripts are
            // OpenAI Realtime audio-out transcripts.
            let roleString: String? = {
                if case .string(let s) = frame.payload["role"] ?? .null { return s }
                return nil
            }()
            // Defense-in-depth: if a brain on an older build is still
            // leaking the legacy `[user] ` sentinel, strip it AND
            // treat the message as user-spoken even when the role
            // field is missing.
            let hasLegacyUserPrefix = text.hasPrefix("[user] ")
            let cleanText = hasLegacyUserPrefix
                ? String(text.dropFirst("[user] ".count))
                : text
            let role: BrainMessage.Role = {
                if let r = roleString, let parsed = BrainMessage.Role(rawValue: r) {
                    return parsed
                }
                return hasLegacyUserPrefix ? .user : .assistant
            }()
            if isPartial {
                liveTranscript = cleanText
            } else {
                liveTranscript = nil
                if !cleanText.isEmpty {
                    transcript.append(BrainMessage(role: role, text: cleanText))
                }
            }

        case "audio_response":
            if case .string(let b64) = frame.payload["data_b64"] ?? .null,
               let data = Data(base64Encoded: b64) {
                let isFinal: Bool = {
                    if case .bool(let b) = frame.payload["is_final"] ?? .null { return b }
                    return false
                }()
                let sampleRate: Int = {
                    if case .int(let i) = frame.payload["sample_rate"] ?? .null { return i }
                    return 24000
                }()
                isAssistantSpeaking = !isFinal
                await audioPlayback.enqueuePCM16(data, sampleRate: sampleRate, isFinal: isFinal)
                if isFinal { isAssistantSpeaking = false }
            }

        case "speech_started":
            // User barge-in: stop any in-flight TTS playback locally.
            await audioPlayback.stopAndDrain()
            isAssistantSpeaking = false

        case "error":
            if case .string(let msg) = frame.payload["message"] ?? .null {
                state = .failed(message: msg)
            }

        default:
            // Other frame types (skill_proposal, etc.) — silently
            // ignored at this layer; richer surfaces hook on top.
            break
        }
    }

    private func extractBrainURL() throws -> URL {
        if case .connected(let url, _) = state { return url }
        if case .connecting(let url) = state { return url }
        throw BrainClientError.notConnected
    }
}

public struct BrainMessage: Identifiable, Equatable {
    public let id: UUID
    public let role: Role
    public let text: String
    public let timestamp: Date

    public enum Role: String, Equatable { case user, assistant, system }

    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public enum BrainClientError: Error, LocalizedError {
    case notConnected
    case invalidBrainURL(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Brain client is not connected."
        case .invalidBrainURL(let s):
            return "Invalid brain URL: \(s)"
        }
    }
}
