import AVFoundation
import Foundation

/// PCM16 playback queue. The brain emits `audio_response` frames
/// containing base64-encoded PCM16 chunks; we decode + queue them
/// onto an AVAudioEngine + AVAudioPlayerNode pipeline so the user
/// hears the assistant in real time.
///
/// ## Why this has a jitter buffer
/// The brain streams TTS as many small `audio_response` chunks whose
/// arrival is gated by network jitter. The glasses' Bluetooth HFP/SCO
/// link adds its own latency. If we scheduled each tiny chunk straight
/// onto `AVAudioPlayerNode` and started playing on the first one (the
/// old behavior), the player drained faster than chunks arrived and
/// underran between words — the assistant "spat one word at a time".
///
/// The proven Theora reference (`GeminiLiveManager.scheduleBufferedAudio`)
/// avoids this by accumulating incoming bytes into a single buffer,
/// coalescing them into uniform ~100 ms slices, and only feeding the
/// player once enough has built up. We mirror that here:
///
///   1. **Coalesce** — append every chunk into `jitterBuffer`, then peel
///      off uniform `chunkBytes` (100 ms) slices to schedule. Tiny
///      network chunks become evenly-sized buffers.
///   2. **Pre-roll** — don't call `player.play()` until ~`preRollBytes`
///      (200 ms) has been queued (or the utterance is already complete),
///      so there's a cushion the network/HFP jitter can dip into without
///      starving the player mid-utterance.
///   3. **Tail flush** — on the final chunk, schedule whatever remains
///      even if it's shorter than a full slice, so the last word isn't
///      dropped.
///
/// The engine is kept warm across utterances (only rebuilt on a sample-
/// rate change) so playback resumes instantly. Session/route policy is
/// owned entirely by `W300AudioBridge` (HFP-only; no IO-buffer or
/// output-port tuning here — the reference proves the smoothness comes
/// from buffering, not from session knobs).
@MainActor
public final class AudioPlayback {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private var lastInputSampleRate: Double = 0
    private var configured = false

    // MARK: - Jitter buffer state

    /// Accumulates decoded PCM16 bytes for the current utterance until we
    /// have a full `chunkBytes` slice (or the utterance ends).
    private var jitterBuffer = Data()
    /// 100 ms of PCM16 at the configured rate (coalesced buffer size).
    private var chunkBytes = 4800
    /// 200 ms pre-roll: bytes queued before we start the player so the
    /// pipeline has a cushion against network/HFP jitter.
    private var preRollBytes = 9600

    /// Whether `player.play()` has been called for the current utterance.
    private var playStarted = false
    /// Set once the brain marks `is_final` for the current utterance.
    private var finalReceived = false
    /// True between the first chunk of an utterance and the moment the
    /// last scheduled buffer drains — drives the TTS auto-mute.
    private var ttsActive = false
    /// Bytes scheduled but not yet started (only tracked pre-`play()`),
    /// used to decide when the pre-roll cushion is full.
    private var preRollQueued = 0

    public init() {}

    /// Decode-and-enqueue a PCM16 chunk. Chunks are coalesced into
    /// uniform 100 ms buffers and held until a 200 ms pre-roll cushion
    /// exists (or the utterance completes) before playback starts, so
    /// the player never starves between words on the higher-latency HFP
    /// link. The first chunk lazily configures the engine for the
    /// chunk's sample rate.
    public func enqueuePCM16(_ data: Data, sampleRate: Int, isFinal: Bool) async {
        do {
            try ensureConfigured(sampleRate: Double(sampleRate))
        } catch {
            return
        }

        // Mute the mic for the whole utterance as soon as the first chunk
        // arrives (belt-and-suspenders alongside the `.voiceChat` system
        // AEC) so the brain's VAD can't trigger on the assistant's own
        // speech. Idempotent.
        if !ttsActive {
            ttsActive = true
            VoiceMuteController.shared.startedPlayingTTS()
        }

        if !data.isEmpty {
            jitterBuffer.append(data)
        }
        if isFinal {
            finalReceived = true
        }

        // Coalesce into uniform 100 ms slices.
        while jitterBuffer.count >= chunkBytes {
            let slice = Data(jitterBuffer.prefix(chunkBytes))
            jitterBuffer.removeFirst(chunkBytes)
            schedule(slice)
        }
        // On the final chunk, flush the short tail so the last word plays.
        if finalReceived && !jitterBuffer.isEmpty {
            let tail = Data(jitterBuffer)
            jitterBuffer.removeAll(keepingCapacity: true)
            schedule(tail)
        }

        // Start the player once the pre-roll cushion is full, or
        // immediately if the whole (short) utterance is already in.
        if !playStarted && (preRollQueued >= preRollBytes || finalReceived) {
            player.play()
            playStarted = true
        }

        // A final frame may arrive with nothing left to play (e.g. an
        // empty terminator) — settle immediately in that case.
        settleIfFinished()
    }

    /// Stop playback and drop any queued buffers (used when the user
    /// barges in via `speech_started`). Keeps the engine warm.
    public func stopAndDrain() async {
        player.stop()
        resetUtteranceState()
        VoiceMuteController.shared.stoppedPlayingTTS()
    }

    public func teardown() {
        player.stop()
        engine.stop()
        configured = false
        resetUtteranceState()
        VoiceMuteController.shared.stoppedPlayingTTS()
        W300AudioBridge.shared.deactivate(for: .playback)
    }

    // MARK: - Scheduling internals

    /// Count of scheduled buffers that haven't yet hit their completion
    /// handler. When it reaches zero AND the utterance is final, the
    /// player has drained — we release the TTS auto-mute.
    private var outstandingBuffers: Int = 0

    private func schedule(_ pcm: Data) {
        guard let format = currentFormat, !pcm.isEmpty else { return }
        let frameCount = pcm.count / 2
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        if let int16Channel = pcmBuffer.int16ChannelData?.pointee {
            pcm.withUnsafeBytes { rawBuf in
                if let src = rawBuf.bindMemory(to: Int16.self).baseAddress {
                    int16Channel.update(from: src, count: frameCount)
                }
            }
        }

        outstandingBuffers += 1
        if !playStarted {
            preRollQueued += pcm.count
        }
        player.scheduleBuffer(pcmBuffer, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferDidFinish()
            }
        })
    }

    private func bufferDidFinish() {
        if outstandingBuffers > 0 { outstandingBuffers -= 1 }
        settleIfFinished()
    }

    /// When the utterance is final and everything has drained, end it:
    /// reset per-utterance state, stop the player so the next utterance
    /// starts cleanly, and lift the TTS auto-mute.
    private func settleIfFinished() {
        guard finalReceived, jitterBuffer.isEmpty, outstandingBuffers == 0 else {
            return
        }
        // Only act if an utterance was actually in flight.
        guard ttsActive else { return }
        player.stop()
        resetUtteranceState()
        VoiceMuteController.shared.stoppedPlayingTTS()
    }

    private func resetUtteranceState() {
        jitterBuffer.removeAll(keepingCapacity: true)
        outstandingBuffers = 0
        playStarted = false
        finalReceived = false
        ttsActive = false
        preRollQueued = 0
    }

    private func ensureConfigured(sampleRate: Double) throws {
        if configured && lastInputSampleRate == sampleRate { return }

        if configured {
            // Sample rate changed mid-session; rebuild the graph.
            player.stop()
            engine.stop()
            engine.detach(player)
            configured = false
            resetUtteranceState()
        }

        // Route/session policy is owned by W300AudioBridge (HFP-only voice
        // session shared with capture). Playback never re-adds A2DP or
        // overrides output — it follows the bridge's HFP route so TTS
        // plays out the glasses speaker.
        try W300AudioBridge.shared.activate(for: .playback)

        guard let inputFormat = makeInputFormat(sampleRate: sampleRate) else { return }
        currentFormat = inputFormat

        // Size the jitter buffer to the actual rate: 100 ms coalesced
        // slices, 200 ms pre-roll cushion. (2 bytes/sample, mono.)
        chunkBytes = Int(sampleRate * 0.1) * 2
        preRollBytes = Int(sampleRate * 0.2) * 2

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
