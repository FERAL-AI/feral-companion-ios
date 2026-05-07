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
    @State private var showConversationsSheet = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if env.chat.messages.isEmpty {
                            EmptyChatPlaceholder()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        }
                        ForEach(env.chat.messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture { inputFocused = false }
                .onChange(of: env.chat.messages.count) { _ in
                    if let last = env.chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                Button {
                    Task { await sendCurrent() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.green : Color.gray)
                }
                .disabled(!canSend)

                Button {
                    if env.brain.state.isConnected {
                        Task { await toggleVoice() }
                    } else {
                        env.chat.appendSystemMessage("Voice needs a paired brain. Open Settings → Pair with a brain.")
                    }
                } label: {
                    Image(systemName: env.brain.voiceActive ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(env.brain.voiceActive ? .red : (env.brain.state.isConnected ? .green : .gray))
                }
            }
            .padding()
            .background(.ultraThinMaterial)
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

private struct EmptyChatPlaceholder: View {
    @EnvironmentObject var env: AppEnvironment
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            Text(headline).font(.title3.weight(.semibold))
            Text(subhead).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                                            .foregroundStyle(.green)
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
                Text(message.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(background, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(foreground)
                Text(message.role.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if message.role != .user { Spacer(minLength: 32) }
        }
    }

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }
    private var background: Color {
        switch message.role {
        case .user: return Color.green.opacity(0.85)
        case .assistant: return Color.white.opacity(0.08)
        case .system: return Color.orange.opacity(0.15)
        }
    }
    private var foreground: Color {
        switch message.role {
        case .user: return .black
        case .assistant: return .white
        case .system: return .orange
        }
    }
}
