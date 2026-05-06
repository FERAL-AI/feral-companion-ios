import SwiftUI

/// Chat + voice. The user can type to the brain, and tap the mic
/// button to start a realtime voice session. Replies stream in
/// from `BrainClient.transcript`.
struct ChatView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var voiceActive = false
    @State private var capture: AudioCapture?

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

            // Message scroll.
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
                .onChange(of: env.chat.messages.count) { _ in
                    if let last = env.chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // Composer: text input + mic.
            HStack(spacing: 8) {
                TextField(
                    "Ask FERAL anything",
                    text: Binding(
                        get: { env.chat.draft },
                        set: { env.chat.draft = $0 }
                    ),
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                Button {
                    if env.brain.state.isConnected {
                        Task { await env.chat.send() }
                    } else {
                        env.chat.appendSystemMessage("Not connected to a brain. Open Settings → Pair with a brain.")
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(env.brain.state.isConnected ? Color.green : Color.gray)
                }
                .disabled(env.chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || env.chat.sending)

                Button {
                    if env.brain.state.isConnected {
                        Task { await toggleVoice() }
                    } else {
                        env.chat.appendSystemMessage("Voice needs a paired brain. Open Settings → Pair with a brain.")
                    }
                } label: {
                    Image(systemName: voiceActive ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(voiceActive ? .red : (env.brain.state.isConnected ? .green : .gray))
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    private func toggleVoice() async {
        if voiceActive {
            capture?.stop()
            capture = nil
            voiceActive = false
            try? await env.brain.sendAudioChunk(Data(), isFinal: true)
            return
        }
        do {
            try await env.brain.startVoiceSession()
            let cap = AudioCapture()
            try cap.start { chunk in
                Task { try? await env.brain.sendAudioChunk(chunk, isFinal: false) }
            }
            self.capture = cap
            self.voiceActive = true
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
