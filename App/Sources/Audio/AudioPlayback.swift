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
        for cp in compressedPlayers { cp.stop() }
        compressedPlayers.removeAll()
        VoiceMuteController.shared.stoppedPlayingTTS()
    }

    public func teardown() {
        player.stop()
        engine.stop()
        configured = false
        outstandingBuffers = 0
        for cp in compressedPlayers { cp.stop() }
        compressedPlayers.removeAll()
        VoiceMuteController.shared.stoppedPlayingTTS()
        W300AudioBridge.shared.deactivate(for: .playback)
    }

    // MARK: - Compressed (mp3 / wav) playback

    /// Holders for in-flight ``AVAudioPlayer`` instances spawned by
    /// ``enqueueCompressed(_:encoding:isFinal:)``. Kept strongly so the
    /// player isn't ARC-reaped before its delegate fires
    /// ``audioPlayerDidFinishPlaying``. Cleaned up on stop / completion.
    private var compressedPlayers: [AVAudioPlayer] = []
    private let compressedDelegate = CompressedPlayerDelegate()

    /// Decode a compressed audio chunk (``mp3`` or ``wav``) and play
    /// it sequentially. The brain emits these on the whisper / Piper
    /// TTS fallback path when the realtime PCM provider died — without
    /// this handler iOS dropped every fallback chunk and the assistant
    /// went silent (operator report 2026-05-18). Each chunk is a full
    /// self-contained file (`AudioPipeline.synthesize_speech` chunks
    /// the synthesised mp3 into 32 KB pieces) so we leverage
    /// ``AVAudioPlayer`` instead of routing through the PCM16
    /// ``AVAudioEngine`` graph that ``enqueuePCM16`` uses — saves a
    /// converter dance and keeps the fallback path honest about the
    /// fact that fallback audio is non-realtime.
    public func enqueueCompressed(_ data: Data, encoding: String, isFinal: Bool) async {
        guard !data.isEmpty else { return }
        do {
            // Route audio through the same shared session so the
            // assistant TTS comes out the same speaker the realtime
            // path used (loudspeaker by default, A2DP if connected).
            try W300AudioBridge.shared.activate(for: .playback)
        } catch {
            return
        }

        // ``AVAudioPlayer(data:)`` infers format from the container —
        // works for mp3 + wav out of the box. ``fileTypeHint`` is a
        // safety net for sources that omit the magic bytes.
        let hint: AVFileType? = (encoding.lowercased() == "wav") ? .wav : .mp3
        let avPlayer: AVAudioPlayer
        do {
            avPlayer = try AVAudioPlayer(data: data, fileTypeHint: hint?.rawValue)
        } catch {
            return
        }
        avPlayer.delegate = compressedDelegate
        compressedDelegate.onFinish = { [weak self] player in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.compressedPlayers.removeAll { $0 === player }
                self.bufferDidFinish()
            }
        }
        avPlayer.prepareToPlay()
        VoiceMuteController.shared.startedPlayingTTS()
        outstandingBuffers += 1
        compressedPlayers.append(avPlayer)
        avPlayer.play()
        _ = isFinal
    }
}

/// AVAudioPlayer delegate hook used by ``AudioPlayback.enqueueCompressed``.
/// Kept as a NSObject sidecar because ``AVAudioPlayerDelegate`` requires
/// NSObject conformance and ``AudioPlayback`` is a value-semantics-leaning
/// MainActor class — splitting the delegate keeps the conformance off
/// the public API.
private final class CompressedPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((AVAudioPlayer) -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        onFinish?(player)
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
        onFinish?(player)
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
        // W300AudioBridge so capture + playback share `.allowBluetoothA2DP`
        // (high-quality output) and the bridge knows we're playing.
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
