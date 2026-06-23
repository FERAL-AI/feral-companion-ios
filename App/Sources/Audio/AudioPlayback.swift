import AVFoundation
import Foundation

/// PCM16 playback queue. The brain emits `audio_response` frames
/// containing base64-encoded PCM16 chunks; we decode + queue them
/// onto an AVAudioEngine + AVAudioPlayerNode pipeline so the user
/// hears the assistant in real time.
@MainActor
public final class AudioPlayback {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var lastInputSampleRate: Double = 0
    private var configured = false

    public init() {}

    /// Decode a PCM16 chunk and schedule it for playback. The first
    /// chunk lazily configures AVAudioEngine to match the chunk's
    /// declared sample rate; subsequent chunks must match.
    public func enqueuePCM16(_ data: Data, sampleRate: Int, isFinal: Bool) async {
        do {
            try ensureConfigured(sampleRate: Double(sampleRate))
        } catch {
            return
        }

        guard let inputFormat = makeInputFormat(sampleRate: Double(sampleRate)) else { return }

        let frameCount = data.count / 2
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        if let int16Channel = pcmBuffer.int16ChannelData?.pointee {
            data.withUnsafeBytes { rawBuf in
                if let src = rawBuf.bindMemory(to: Int16.self).baseAddress {
                    int16Channel.update(from: src, count: frameCount)
                }
            }
        }

        // Phase 8 (audit-r10 overhaul) — auto-mute the mic for the
        // duration of TTS playback. Belt-and-suspenders alongside
        // the `.voiceChat`-mode system AEC: even on a loudspeaker
        // playback into a built-in mic, no audio chunks reach the
        // brain while the assistant is talking, so the brain's
        // realtime VAD can't trigger on its own speech.
        VoiceMuteController.shared.startedPlayingTTS()
        outstandingBuffers += 1
        player.scheduleBuffer(pcmBuffer, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferDidFinish()
            }
        })
        if !player.isPlaying {
            player.play()
        }
        _ = isFinal // currently no end-of-utterance hook needed
    }

    /// Stop playback and drop any queued buffers (used when the user
    /// barges in via `speech_started`).
    public func stopAndDrain() async {
        player.stop()
        outstandingBuffers = 0
        VoiceMuteController.shared.stoppedPlayingTTS()
    }

    public func teardown() {
        player.stop()
        engine.stop()
        configured = false
        outstandingBuffers = 0
        VoiceMuteController.shared.stoppedPlayingTTS()
        W300AudioBridge.shared.deactivate(for: .playback)
    }

    /// Count of scheduled buffers that haven't yet hit their
    /// completion handler. Lowered by `bufferDidFinish()`; when it
    /// hits zero we release the TTS auto-mute so the mic resumes
    /// streaming user audio to the brain.
    private var outstandingBuffers: Int = 0

    private func bufferDidFinish() {
        if outstandingBuffers > 0 { outstandingBuffers -= 1 }
        if outstandingBuffers == 0 {
            VoiceMuteController.shared.stoppedPlayingTTS()
        }
    }

    private func ensureConfigured(sampleRate: Double) throws {
        if configured && lastInputSampleRate == sampleRate { return }

        if configured {
            // Sample rate changed mid-session; rebuild.
            player.stop()
            engine.stop()
            engine.detach(player)
            configured = false
        }

        // Phase 6 / audit-r8 brief #03: route session config through
        // W300AudioBridge so capture + playback share ONE HFP-only voice
        // session and the bridge knows we're playing. Playback never
        // re-adds A2DP or overrides output — it follows the bridge's HFP
        // route so TTS plays out the glasses speaker (not the iPhone).
        try W300AudioBridge.shared.activate(for: .playback)

        guard let inputFormat = makeInputFormat(sampleRate: sampleRate) else { return }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: inputFormat)
        engine.prepare()
        try engine.start()

        lastInputSampleRate = sampleRate
        configured = true
    }

    private func makeInputFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )
    }
}
