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

    /// Test-only seam used by `FeralCompanionTests` to inject a known
    /// transcript prefix before exercising dedupe / voice fallback
    /// frame handling. Must not be called from product code.
    public func _injectTranscriptForTesting(_ messages: [BrainMessage]) {
        self.transcript = messages
    }

    /// Test-only seam to drive `handleInbound` from XCTest without
    /// stubbing the entire transport. Constructs a `HUPFrame` from the
    /// raw `(type, payload)` pair so test cases stay readable.
    public func _handleFrameForTesting(type: String, payload: [String: AnyCodable]) async {
        let frame = HUPFrame(type: type, payload: payload)
        await handleInbound(frame)
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

    /// Conversation id sent on every `chat_request`.
    ///
    /// Audit-r9 fix — operator report 2026-05-10:
    /// > "the chat and memory should be the same for my phone chat
    /// >  and the webui for feral brain on the local brain right?"
    ///
    /// Yes. Until this fix, BrainClient minted `UUID().uuidString`
    /// per app launch and sent it on every `chat_request`. The brain
    /// honored that explicit id, so iOS chat ran in a `conversation_history`
    /// keyed by that UUID — completely isolated from web's
    /// `conversation_history[uuid4()]` for whichever WebSocket the
    /// browser tab opened.
    ///
    /// Now we default to **empty string**. The brain's `chat_request`
    /// resolver (`api/server.py` ~1486) treats empty as "use my
    /// primary_session_id" — the per-install shared id that web
    /// `/v1/session` also defaults to. The brain then echoes the
    /// resolved id back in `chat_response.payload.session_id`, and
    /// the existing handler at `case "chat_response":` (~306) adopts
    /// it for subsequent turns. Net effect: phone + web share one
    /// thread out of the box; an explicit "new chat" gesture would
    /// set this back to a fresh UUID before the next send.
    @Published public private(set) var chatSessionId: String = ""

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

    /// Phase 5 / audit-r8 brief #04 — the latest GenUI surface pushed
    /// by the brain via `genui_push`. The chat tab renders this above
    /// the message list when present so app surfaces (Notes, Calendar,
    /// confirmations, etc.) appear inline. `sdui_patch` frames mutate
    /// `sduiTree` in place when their `screen_id` matches.
    public struct GenUISurface: Equatable {
        public let appId: String
        public let surfaceId: String
        public let screenId: String
        public let title: String
        public let body: String
        /// Decoded JSON (`Any`-equivalent) — kept loose so JSON-Patch
        /// applies cleanly. Renderer re-decodes via `SDUINode.decode`.
        public var sduiTree: NSObject?
        public let receivedAt: Date

        public static func == (lhs: GenUISurface, rhs: GenUISurface) -> Bool {
            lhs.appId == rhs.appId && lhs.surfaceId == rhs.surfaceId
                && lhs.screenId == rhs.screenId && lhs.title == rhs.title
                && lhs.body == rhs.body && lhs.receivedAt == rhs.receivedAt
        }
    }
    @Published public private(set) var genUI: GenUISurface? = nil

    /// Cached `phone_bearer` for authenticated HTTP calls to the brain.
    ///
    /// Audit-r11 — Bug 2 (Context tab Status 401). Written by
    /// ``ConnectionStore`` after a successful pair and on startup
    /// (when the persisted bearer is restored from ``UserDefaults``).
    /// All HTTP-issuing stores read this through ``BrainHTTP/authorized(_:bearer:method:jsonBody:timeout:)``
    /// instead of calling ``URLSession.shared.data(from:)`` raw.
    /// Setting to `nil` (e.g. on unpair) makes subsequent calls
    /// anonymous — the brain will return 401 for `_PHONE_BEARER_GET_PATHS`
    /// endpoints, which is correct.
    @Published public var phoneBearer: String? = nil

    /// Latest `voice_status` snapshot from the brain.
    ///
    /// Audit-r11 — Bug 3 (silent voice everywhere). When OpenAI
    /// Realtime closes with `1013 insufficient_quota`, the brain emits
    /// a `voice_status state=degraded reason=openai_realtime_quota`
    /// frame and starts falling through to whisper TTS (`tts_chunk`
    /// frames). When even the fallback fails the brain emits
    /// `state=unavailable`. The chat view reads this to show a
    /// "Voice unavailable — out of credit" banner instead of going
    /// silent. Nil = healthy (no banner).
    @Published public private(set) var voiceStatus: VoiceStatus? = nil

    /// Brain-emitted voice subsystem health. Mirror of the wire shape
    /// defined in `feral-core/models/protocol.py:VoiceStatusPayload`.
    public struct VoiceStatus: Equatable {
        public enum State: String {
            case available
            case degraded
            case unavailable
        }
        public let state: State
        public let reason: String
        public let provider: String
        public let fallbackProvider: String
        public let detail: String

        public init(state: State, reason: String, provider: String, fallbackProvider: String, detail: String) {
            self.state = state
            self.reason = reason
            self.provider = provider
            self.fallbackProvider = fallbackProvider
            self.detail = detail
        }
    }

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

    /// Always-on phone skills registered alongside the user-toggled
    /// adapters on every connect. See `CallKitSkill` (Phase 4a) for
    /// the first example. Phase 4b adds the demo trio: ContactsSkill
    /// (so "call John" resolves to a real phone number),
    /// MusicKitSkill (Apple Music playback), and EventKitSkill
    /// (read/create calendar events).
    private static func alwaysOnSkills() -> [VendorAdapter] {
        var skills: [VendorAdapter] = [
            CallKitSkill(),
            ContactsSkill(),
            EventKitSkill(),
        ]
        if #available(iOS 16.0, *) {
            skills.append(MusicKitSkill())
        }
        return skills
    }

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
        // Phase 4a (audit-r10 overhaul) — always-on phone skills.
        // These don't live in DeviceStore because they're not user-
        // togglable devices; they're capabilities the phone itself
        // exposes whenever it's connected to the brain. Adding new
        // skills in Phase 4b means appending here.
        for skill in Self.alwaysOnSkills() {
            await node.register(adapter: skill)
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
            // The SDK's ``disconnect(reason:)`` already emits a
            // single ``node_bye`` frame with the caller-supplied
            // reason. We previously emitted an explicit
            // ``user_disconnect`` bye AND then called
            // ``node.disconnect()`` which sent a second
            // ``shutdown`` bye — the brain log only ever showed
            // ``shutdown`` because the second frame raced past the
            // first (operator report 2026-05-08:
            // "node_bye reason=shutdown" right after register, even
            // though the user explicitly disconnected). One bye,
            // correctly labeled.
            await node.disconnect(reason: "user_disconnect")
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

    /// Phase 5 / audit-r8 brief #04 — forward a SwiftUI SDUI tap /
    /// toggle / slider / form submit to the brain. Echoes back the
    /// `app_id`/`surface_id`/`screen_id` from the original
    /// `genui_push` so the brain dispatcher can locate the surface.
    /// `value` accepts the lossy `SDUIJSONValue` re-export from the
    /// renderer.
    /// Internal: SDUI tree types are app-internal (App target only) so
    /// this helper is `internal` — only `ChatView` consumes it.
    func sendGenUIAction(
        surface: GenUISurface,
        actionId: String,
        eventType: String,
        value: SDUINode.SDUIJSONValue?
    ) async throws {
        guard let node else { throw BrainClientError.notConnected }
        let codable: AnyCodable? = value.map { Self.sduiValueToCodable($0) }
        try await node.sendGenUIEvent(
            appId: surface.appId,
            surfaceId: surface.surfaceId,
            screenId: surface.screenId,
            actionId: actionId,
            eventType: eventType,
            value: codable
        )
    }

    private static func sduiValueToCodable(_ v: SDUINode.SDUIJSONValue) -> AnyCodable {
        switch v {
        case .string(let s): return .string(s)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .bool(let b): return .bool(b)
        case .null: return .null
        case .array(let arr): return .array(arr.map { sduiValueToCodable($0) })
        case .object(let obj):
            var d: [String: AnyCodable] = [:]
            for (k, vv) in obj { d[k] = sduiValueToCodable(vv) }
            return .object(d)
        }
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
                // Audit-r11 — Bug 1 (iOS double assistant bubble).
                // The brain-side fix (orchestrator
                // `_text_response_suppressed` flag, see
                // `feral-core/api/server.py` chat_request branch)
                // guarantees only one frame per turn, but a stale
                // brain build OR a future divergence where both
                // surfaces emit could resurrect the bug. This
                // belt-and-suspenders guard collapses any (role,
                // text) duplicate landing within 2s of the previous
                // assistant turn so the chat history can never
                // double-render. Pinned by
                // `FeralCompanionTests.test_BrainClient_dedupes_back_to_back_assistant_frames`.
                if let last = transcript.last,
                   last.role == .assistant,
                   last.text == text,
                   Date().timeIntervalSince(last.timestamp) < 2.0 {
                    isAssistantSpeaking = false
                    break
                }
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

        case "tts_chunk":
            // Audit-r11 — Bug 3 (silent voice). The brain's whisper
            // TTS fallback path emits `tts_chunk` frames carrying
            // base64-encoded compressed audio (mp3 by default, wav
            // for the local Piper provider). Without this handler iOS
            // dropped every chunk and the user heard nothing whenever
            // the realtime PCM path went down (e.g. OpenAI
            // insufficient_quota). Decode by `encoding` and hand off
            // to `AudioPlayback.enqueueCompressed`.
            if case .string(let b64) = frame.payload["data_b64"] ?? .null,
               let data = Data(base64Encoded: b64) {
                let isFinal: Bool = {
                    if case .bool(let b) = frame.payload["is_final"] ?? .null { return b }
                    return false
                }()
                let encoding: String = {
                    if case .string(let s) = frame.payload["encoding"] ?? .null { return s }
                    return "mp3"
                }()
                isAssistantSpeaking = !isFinal
                await audioPlayback.enqueueCompressed(data, encoding: encoding, isFinal: isFinal)
                if isFinal { isAssistantSpeaking = false }
            }

        case "voice_status":
            // Audit-r11 — Bug 3 banner contract. Brain emits this
            // when the realtime provider died (`state=degraded`,
            // `reason=openai_realtime_quota`/`openai_realtime_auth`/etc)
            // or when even the fallback failed (`state=unavailable`).
            // Mirror into a typed `@Published voiceStatus` so ChatView
            // can render a banner instead of silently going mute.
            let stateRaw: String = {
                if case .string(let s) = frame.payload["state"] ?? .null { return s }
                return "available"
            }()
            let mapped = VoiceStatus.State(rawValue: stateRaw) ?? .available
            let reason: String = {
                if case .string(let s) = frame.payload["reason"] ?? .null { return s }
                return ""
            }()
            let provider: String = {
                if case .string(let s) = frame.payload["provider"] ?? .null { return s }
                return ""
            }()
            let fallback: String = {
                if case .string(let s) = frame.payload["fallback_provider"] ?? .null { return s }
                return ""
            }()
            let detail: String = {
                if case .string(let s) = frame.payload["detail"] ?? .null { return s }
                return ""
            }()
            if mapped == .available {
                voiceStatus = nil
            } else {
                voiceStatus = VoiceStatus(
                    state: mapped,
                    reason: reason,
                    provider: provider,
                    fallbackProvider: fallback,
                    detail: detail
                )
            }

        case "speech_started":
            // User barge-in: stop any in-flight TTS playback locally.
            await audioPlayback.stopAndDrain()
            isAssistantSpeaking = false

        case "error":
            if case .string(let msg) = frame.payload["message"] ?? .null {
                state = .failed(message: msg)
            }

        case "genui_push":
            // Phase 5: brain pushed an app surface. Persist it for
            // ChatView to render. The full SDUI tree lives under
            // `payload.sdui` as a JSON object; we keep it as an
            // `NSObject` (a Foundation collection) so JSON-Patch
            // mutates it cleanly later.
            let appId = stringField(frame.payload["app_id"]) ?? ""
            let surfaceId = stringField(frame.payload["surface_id"]) ?? ""
            let screenId = stringField(frame.payload["screen_id"]) ?? ""
            let title = stringField(frame.payload["title"]) ?? "\(appId):\(surfaceId)"
            let body = stringField(frame.payload["body"]) ?? ""
            let sduiObj = anyJSONField(frame.payload["sdui"])
            genUI = GenUISurface(
                appId: appId,
                surfaceId: surfaceId,
                screenId: screenId,
                title: title,
                body: body,
                sduiTree: sduiObj,
                receivedAt: Date()
            )

        case "sdui_patch":
            // Patch the active GenUI surface IFF the screen_id matches.
            // Brain emits one `sdui_patch` per logical change — see
            // `feral-core/agents/ui_handlers.py` patch helpers.
            let targetId = stringField(frame.payload["screen_id"]) ?? ""
            guard var current = genUI, current.screenId == targetId,
                  let tree = current.sduiTree as Any?,
                  let patches = patchArrayField(frame.payload["patches"])
            else { break }
            let next = SDUIJSON.applyPatches(tree, patches: patches)
            current.sduiTree = (next as AnyObject) as? NSObject
            genUI = current

        default:
            // Other frame types (skill_proposal, etc.) — silently
            // ignored at this layer; richer surfaces hook on top.
            break
        }
    }

    // MARK: - Frame field helpers (Phase 5 GenUI ingest)

    private func stringField(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }

    /// Extract the inner JSON value (`Any`-equivalent NSObject) from
    /// an `AnyCodable`. Used for the `genui_push.payload.sdui` blob
    /// which the brain serialises as a generic JSON object — we don't
    /// want to model every component as a Swift type at the SDK level
    /// because the renderer redecodes via `SDUINode.decode`.
    private func anyJSONField(_ value: AnyCodable?) -> NSObject? {
        guard let value else { return nil }
        return Self.anyCodableToFoundation(value) as? NSObject
    }

    private func patchArrayField(_ value: AnyCodable?) -> [[String: Any]]? {
        guard let value else { return nil }
        guard case .array(let arr) = value else { return nil }
        var out: [[String: Any]] = []
        for el in arr {
            guard case .object(let obj) = el else { continue }
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = Self.anyCodableToFoundation(v) }
            out.append(dict)
        }
        return out
    }

    /// AnyCodable → Foundation tree (String/NSNumber/NSNull/Array/Dict)
    /// so JSONSerialization-style `[String: Any]` consumers work.
    private static func anyCodableToFoundation(_ value: AnyCodable) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { anyCodableToFoundation($0) }
        case .object(let obj):
            var d: [String: Any] = [:]
            for (k, v) in obj { d[k] = anyCodableToFoundation(v) }
            return d
        }
    }

    private func extractBrainURL() throws -> URL {
        if case .connected(let url, _) = state { return url }
        if case .connecting(let url) = state { return url }
        throw BrainClientError.notConnected
    }

    /// Phase 10 (audit-r10 overhaul) — public HTTP base for the
    /// currently-paired brain. Returns `http://host:port` / `https://host:port`
    /// derived from the WebSocket URL we've been using for HUP. Nil
    /// when no brain is connected (or connecting). Consumed by the
    /// Brain Devices section in `DevicesView` so it can hit
    /// `/api/capabilities` without re-deriving the URL.
    public var brainHTTPBase: URL? {
        let wsURL: URL
        do { wsURL = try extractBrainURL() } catch { return nil }
        return Self.httpBase(from: wsURL)
    }

    // MARK: - Phase 9 (audit-r10) — backgrounded chat resume

    /// Position of the last brain-originated message we know about,
    /// expressed as the `ts_ms` returned by the brain's primary
    /// transcript endpoint. Used as `since_ms` on resume so the
    /// reconcile call only fetches genuinely new turns.
    private var lastSeenTranscriptTs: Int = 0

    /// Fetch the brain's authoritative primary-session transcript
    /// over REST and append any messages we don't already have to
    /// `transcript`. Call from `scenePhase: .active` after the
    /// WebSocket has reconnected — without this round-trip, replies
    /// the brain emitted while iOS was backgrounded are lost forever
    /// (the WS dropped them on the way out).
    ///
    /// Idempotent. Safe to call repeatedly; the `since_ms` cursor
    /// makes the second call a no-op when no new turns landed.
    public func reconcileTranscriptFromBrain() async {
        let brainURL: URL
        do { brainURL = try extractBrainURL() } catch { return }
        // The brain URL is a WebSocket (`ws://` / `wss://`); rewrite
        // the scheme + drop the WS path component to hit `/api/...`.
        guard let httpBase = Self.httpBase(from: brainURL) else { return }
        guard let endpoint = URL(string: "/api/sessions/primary/transcript?since_ms=\(lastSeenTranscriptTs)&limit=200", relativeTo: httpBase) else {
            return
        }

        // Audit-r11 fix — Bug 2 (Status 401). Backgrounded chat
        // resume calls `/api/sessions/primary/transcript` which is in
        // `_PHONE_BEARER_GET_PATHS` and requires the bearer. Before
        // this, every reconcile after a cold launch silently failed
        // with 401 and the iOS chat lost any turn the brain emitted
        // while we were backgrounded.
        let request = BrainHTTP.authorized(endpoint, bearer: phoneBearer)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let messages = json["messages"] as? [[String: Any]] else { return }

            for entry in messages {
                let roleStr = (entry["role"] as? String) ?? ""
                let text = (entry["text"] as? String) ?? ""
                let ts = (entry["ts_ms"] as? Int) ?? 0
                guard !text.isEmpty,
                      let role = BrainMessage.Role(rawValue: roleStr) else { continue }
                // De-dupe by (role, text) against the tail of the
                // local transcript — covers the case where the user
                // sent a message that was both echoed locally AND
                // recorded in the brain's history.
                if !transcript.contains(where: { $0.role == role && $0.text == text }) {
                    transcript.append(BrainMessage(role: role, text: text))
                }
                if ts > lastSeenTranscriptTs { lastSeenTranscriptTs = ts }
            }
        } catch {
            // Reconcile is best-effort. A network failure leaves the
            // local transcript untouched; the next reconcile call
            // retries with the same `since_ms` cursor.
        }
    }

    /// Map `ws://host:port` or `wss://host:port` → `http://host:port`
    /// / `https://host:port`. Returns nil for unexpected schemes so
    /// the caller can short-circuit cleanly.
    private static func httpBase(from wsURL: URL) -> URL? {
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)
        switch components?.scheme {
        case "ws": components?.scheme = "http"
        case "wss": components?.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        // Strip any WS endpoint path so the relative `/api/...` URL
        // resolves against the host root.
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url
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
    /// iOS denied the app's Local Network permission. Triggered when a
    /// pair-flow URLSession request to an RFC-1918 host returns
    /// `URLError.notConnectedToInternet | .networkConnectionLost |
    /// .cannotConnectToHost` — none of which actually mean "offline".
    /// Surfaced verbatim so callers (pair view) can render an "Open
    /// Settings" button.
    case localNetworkDenied(host: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Brain client is not connected."
        case .invalidBrainURL(let s):
            return "Invalid brain URL: \(s)"
        case .localNetworkDenied(let host):
            return "FERAL needs Local Network permission to reach the brain at \(host). Open Settings -> Privacy & Security -> Local Network -> enable FERAL, then try again."
        }
    }
}
