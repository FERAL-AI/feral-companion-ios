import SwiftUI

/// Mutable composer state held in a long-lived ObservableObject so
/// SwiftUI doesn't reset the input every time `env` republishes
/// (which happens often via BrainClient liveTranscript / state /
/// transcript updates). @State on a view that re-creates frequently
/// drops keystrokes on real iPhones — @StateObject survives.
@MainActor
final class ChatComposer: ObservableObject {
    @Published var input: String = ""
}

/// Chat + voice. The user can type to the brain, and tap the mic
/// button to start a realtime voice session. Replies stream in
/// from `BrainClient.transcript`.
///
/// Voice lifecycle is owned by `BrainClient` (Phase 1 truthfulness
/// sweep) so the same flag drives the chat mic button **and** the
/// `scenePhase: .background` teardown. Storing voice state in this
/// view's `@State` would mean the lifecycle layer can't stop the
/// engine when the OS suspends the app.
struct ChatView: View {
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var composer = ChatComposer()
    // Phase 8 (audit-r10 overhaul) — observe the shared mute
    // controller so the mute icon swaps state without polling.
    // Auto-mute during TTS playback is reflected in `.autoMuted` but
    // the button only binds to `.userMuted` (user intent), so an
    // assistant utterance doesn't flicker the icon.
    @ObservedObject private var muteController = VoiceMuteController.shared
    @State private var showConversationsSheet = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Phase 5 / audit-r8 brief #04 — render the active GenUI
            // surface above the message list. Brain pushes via
            // `genui_push` and updates via `sdui_patch`; BrainClient
            // tracks the latest in `env.brain.genUI`. Action callbacks
            // forward to `FeralNode.sendGenUIEvent` with the IDs the
            // brain sent on the push frame.
            if let surface = env.brain.genUI, let tree = surface.sduiTree {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.3.group.bubble.left")
                            .foregroundStyle(.secondary)
                        Text(surface.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(surface.appId):\(surface.surfaceId)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !surface.body.isEmpty {
                        Text(surface.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SDUIRenderer(tree: tree as Any) { eventType, actionId, value in
                        Task {
                            try? await env.brain.sendGenUIAction(
                                surface: surface,
                                actionId: actionId,
                                eventType: eventType,
                                value: value
                            )
                        }
                    }
                }
                .padding(FeralTheme.padMD)
                .feralGlass(.thin, radius: .md)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Live transcript from the brain (partial speech recognition).
            if let live = env.brain.liveTranscript, !live.isEmpty {
                Text(live)
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            // Message scroll. Two SwiftUI mechanisms make the keyboard
            // dismissable without a Done button:
            //   1. .scrollDismissesKeyboard(.interactively) — drag the
            //      list to swipe-dismiss.
            //   2. .contentShape(Rectangle()).onTapGesture — tapping
            //      anywhere in the message area resigns focus.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if env.chat.messages.isEmpty {
                            EmptyChatPlaceholder()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        }
                        ForEach(env.chat.messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal: .opacity
                                ))
                        }
                        if env.brain.isAssistantSpeaking {
                            TypingIndicator()
                                .id("typing-indicator")
                        }
                    }
                    .padding()
                    .animation(FeralTheme.springSnappy, value: env.chat.messages.count)
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture { inputFocused = false }
                .onChange(of: env.chat.messages.count) { _ in
                    if let last = env.chat.messages.last {
                        withAnimation(FeralTheme.springSnappy) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: env.brain.isAssistantSpeaking) { speaking in
                    if speaking {
                        withAnimation(FeralTheme.springSnappy) {
                            proxy.scrollTo("typing-indicator", anchor: .bottom)
                        }
                    }
                }
            }

            // Composer. Single-line so .submitLabel(.send) + .onSubmit
            // actually trigger send on Return (vertical text fields
            // suppress submit). @StateObject composer holds the input
            // string so re-renders of env.* don't drop keystrokes.
            HStack(spacing: 8) {
                TextField("Ask FERAL anything", text: $composer.input)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendCurrent() } }
                    .autocorrectionDisabled(false)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(FeralTheme.surface1, in: RoundedRectangle(cornerRadius: FeralTheme.radiusMD, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: FeralTheme.radiusMD, style: .continuous)
                            .stroke(FeralTheme.hairline, lineWidth: 0.5)
                    )

                Button {
                    Task { await sendCurrent() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? FeralTheme.accent : FeralTheme.textTertiary)
                }
                .disabled(!canSend)

                // Phase 8 (audit-r10 overhaul) — mute toggle. Only
                // visible while a voice session is live so the
                // composer doesn't grow extra controls during text
                // chat. Reads the shared `VoiceMuteController` so
                // its state survives Voice on/off cycles and
                // synchronises with AudioPlayback auto-mute.
                if env.brain.voiceActive {
                    Button {
                        VoiceMuteController.shared.toggleUserMute()
                    } label: {
                        Image(systemName: muteController.userMuted
                              ? "mic.slash.fill"
                              : "mic.slash")
                            .font(.title2)
                            .foregroundStyle(muteController.userMuted ? .orange : .secondary)
                    }
                    .accessibilityLabel(muteController.userMuted ? "Unmute" : "Mute")
                }

                Button {
                    if env.brain.state.isConnected {
                        Task { await toggleVoice() }
                    } else {
                        env.chat.appendSystemMessage("Voice needs a paired brain. Open Settings → Pair with a brain.")
                    }
                } label: {
                    Image(systemName: env.brain.voiceActive ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(env.brain.voiceActive ? FeralTheme.stateError : (env.brain.state.isConnected ? FeralTheme.stateLive : FeralTheme.textTertiary))
                }
            }
            .padding(FeralTheme.padLG)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle().fill(FeralTheme.hairline).frame(height: 0.5)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showConversationsSheet = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    Button {
                        env.history.newSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
        .sheet(isPresented: $showConversationsSheet) {
            ConversationsListView(isPresented: $showConversationsSheet)
                .environmentObject(env)
        }
    }

    private var canSend: Bool {
        !composer.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !env.chat.sending
    }

    private func sendCurrent() async {
        let text = composer.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !env.brain.state.isConnected {
            env.chat.appendSystemMessage("Not connected to a brain. Open Settings → Pair with a brain.")
            return
        }
        env.chat.draft = text
        await env.chat.send()
        composer.input = ""
        inputFocused = false
    }

    private func toggleVoice() async {
        if env.brain.voiceActive {
            await env.brain.stopVoice()
            return
        }
        do {
            try await env.brain.startVoice()
        } catch {
            // Show a system message in chat so the user sees why nothing happened.
            env.chat.appendSystemMessage("Voice failed: \(error.localizedDescription)")
        }
    }
}

/// Animated three-dot typing indicator shown while the assistant streams.
private struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(FeralTheme.textTertiary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(phase == i ? 1.3 : 0.8)
                        .opacity(phase == i ? 1.0 : 0.5)
                        .animation(FeralTheme.springSnappy, value: phase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(FeralTheme.surface1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FeralTheme.hairline, lineWidth: 0.5)
            )
            Spacer(minLength: 32)
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

private struct EmptyChatPlaceholder: View {
    @EnvironmentObject var env: AppEnvironment
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(FeralTheme.accent.opacity(0.6))
            Text(headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(FeralTheme.textPrimary)
            Text(subhead)
                .font(.callout)
                .foregroundStyle(FeralTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding()
    }

    private var headline: String {
        env.brain.state.isConnected ? "Ready when you are." : "Pair a FERAL brain to begin."
    }
    private var subhead: String {
        env.brain.state.isConnected
        ? "Type a question or hold the mic. FERAL pulls live signal from your devices when it matters."
        : "Open Settings → Pair a brain. You can scan a QR or paste a feral:// link."
    }
}

/// Sheet listing every persisted conversation. Tapping a row switches
/// the active session and triggers BrainClient to reload that
/// session's transcript from disk.
struct ConversationsListView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        env.history.newSession()
                        isPresented = false
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
                Section("History") {
                    ForEach(env.history.sessions) { meta in
                        Button {
                            env.history.switchTo(sessionId: meta.id)
                            isPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(meta.title.isEmpty ? "New chat" : meta.title)
                                        .font(.body.weight(meta.id == env.history.currentSessionId ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if meta.id == env.history.currentSessionId {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(FeralTheme.stateLive)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text(relativeDate(meta.lastUpdated))
                                    Text("·")
                                    Text("\(meta.messageCount) message\(meta.messageCount == 1 ? "" : "s")")
                                }
                                .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            let meta = env.history.sessions[idx]
                            env.history.deleteSession(meta.id)
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

private struct ChatBubble: View {
    let message: BrainMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: alignment, spacing: 2) {
                bubbleContent
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor, lineWidth: 0.5)
                    )
                Text(message.role.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(FeralTheme.textTertiary)
            }
            if message.role != .user { Spacer(minLength: 32) }
        }
    }

    /// User bubbles are short and always plain text on a tinted
    /// background — running them through the markdown parser would
    /// turn `**emphasis**` typed by the operator into bold while also
    /// breaking accidental asterisks. Assistant + system replies get
    /// the full markdown treatment because that's where the brain
    /// actually emits headings, lists, and code.
    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .foregroundStyle(foreground)
        case .assistant, .system:
            MarkdownText(raw: message.text, textColor: foreground)
        }
    }

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }
    private var background: Color {
        switch message.role {
        case .user: return FeralTheme.accent.opacity(0.85)
        case .assistant: return FeralTheme.surface1
        case .system: return FeralTheme.stateWarnSoft
        }
    }
    private var foreground: Color {
        switch message.role {
        case .user: return .white
        case .assistant: return FeralTheme.textPrimary
        case .system: return FeralTheme.stateWarn
        }
    }
    private var borderColor: Color {
        switch message.role {
        case .user: return .clear
        case .assistant: return FeralTheme.hairline
        case .system: return FeralTheme.stateWarn.opacity(0.3)
        }
    }
}
