import Combine
import Foundation

// Phase 8 (audit-r10 overhaul) — shared mute state for the voice
// session.
//
// Closes operator complaints:
//   * "voice button keeps on being on always with no mute option"
//   * "voice itself echoes, replying to its own audio when not using
//     headphones"
//
// Two independent mute sources are tracked separately so a user-
// explicit mute doesn't get clobbered by a TTS-playback auto-mute
// (and vice versa). The combined `isMuted` is what AudioCapture
// reads each time a buffer arrives — true iff *either* source is
// muting. Subscribers in the UI bind to `userMuted` only so the
// mic button shows the user's intent rather than flickering with
// TTS playback.

public final class VoiceMuteController: ObservableObject, @unchecked Sendable {

    public static let shared = VoiceMuteController()

    /// User-driven mute (the mute button in ChatView). Tap toggles
    /// this and the value persists across TTS playback bursts.
    /// Written only from MainActor (UI button); read from any thread.
    @Published public var userMuted: Bool = false

    /// Auto-mute, raised while the brain is currently playing TTS
    /// through the device speakers. Reset when playback completes.
    /// Together with the system AEC (`.voiceChat` mode), this
    /// belt-and-suspenders approach kills the speaker-echo loop the
    /// operator reported when the headphones aren't in use.
    /// Written only from MainActor (AudioPlayback is `@MainActor`);
    /// read from the AVAudioEngine tap thread.
    @Published public private(set) var autoMuted: Bool = false

    /// Effective mute. `AudioCapture` reads this on every chunk
    /// directly off the audio render thread, so we deliberately do
    /// NOT route through MainActor here — both backing booleans are
    /// written serially from MainActor and a Bool read is atomic on
    /// every iOS-supported architecture.
    public var isMuted: Bool { userMuted || autoMuted }

    private init() {}

    // ── TTS playback hooks (called from AudioPlayback) ────────────

    /// Raised by `AudioPlayback` when the first PCM16 chunk of an
    /// assistant utterance is scheduled. Idempotent — repeated
    /// raises stay raised until `stoppedPlayingTTS()` lowers them.
    public func startedPlayingTTS() {
        if !autoMuted { autoMuted = true }
    }

    /// Lowered when the AVAudioPlayerNode drains or the user barges
    /// in via `speech_started`. Safe to call repeatedly.
    public func stoppedPlayingTTS() {
        if autoMuted { autoMuted = false }
    }

    // ── User toggle (called from ChatView's mute button) ─────────

    public func toggleUserMute() {
        userMuted.toggle()
    }
}
