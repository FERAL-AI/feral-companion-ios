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

        // Schedule the buffer. The player plays back at the device's
        // output rate; AVAudioEngine handles any rate adaptation
        // through the connection format declared at configure time.
        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
        _ = isFinal // currently no end-of-utterance hook needed
    }

    /// Stop playback and drop any queued buffers (used when the user
    /// barges in via `speech_started`).
    public func stopAndDrain() async {
        player.stop()
    }

    public func teardown() {
        player.stop()
        engine.stop()
        configured = false
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

        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers, .duckOthers])
            try session.setActive(true, options: [])
        }

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
