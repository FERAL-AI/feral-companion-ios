import AVFoundation
import Foundation

/// Mic capture: AVAudioEngine input tap → PCM16 mono @ 24 kHz.
/// Resamples device-native rate (typically 48 kHz) down to 24 kHz
/// before forwarding so the brain's voice_router receives audio
/// matching the `voice_session_start` declared rate.
public final class AudioCapture {

    public typealias ChunkHandler = (Data) -> Void

    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let chunkBytes: Int
    private var pendingPCM16: Data = Data()
    /// Retained so the tap can be rebuilt against a new input route
    /// (e.g. the glasses HFP mic arriving mid-capture) without the caller.
    private var onChunkHandler: ChunkHandler?
    private var running = false

    /// - Parameters:
    ///   - sampleRate: Output sample rate (default 24000).
    ///   - chunkMs: Approximate chunk size in milliseconds (default
    ///     100 ms). At 24 kHz mono PCM16 that is 4800 bytes per chunk.
    public init(sampleRate: Double = 24000, chunkMs: Int = 100) {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
        let samplesPerChunk = Int(sampleRate * Double(chunkMs) / 1000.0)
        self.chunkBytes = samplesPerChunk * 2 // 16-bit = 2 bytes/sample
    }

    public func start(onChunk: @escaping ChunkHandler) throws {
        // Phase 6 / audit-r8 brief #03: route AVAudioSession config
        // through W300AudioBridge so capture + playback agree on the
        // session policy (HFP-only: `.allowBluetooth`, NO A2DP). Register
        // a restart hook so the bridge can rebuild this tap onto the
        // glasses HFP mic if that route arrives after we've already
        // started on the iPhone mic (HFP surfaces ~0.5–1.5 s late).
        try MainActor.assumeIsolated {
            try W300AudioBridge.shared.activate(for: .capture)
            W300AudioBridge.shared.captureRestartHandler = { [weak self] in
                self?.restartInputCaptureIfRunning()
            }
        }

        self.onChunkHandler = onChunk
        try buildEngineAndTap()
        running = true
    }

    /// Rebuild the capture engine + tap + converter against the CURRENT
    /// input route, WITHOUT touching the shared AVAudioSession (the bridge
    /// owns session policy). Called by `W300AudioBridge` when the glasses
    /// HFP mic surfaces — or drops — mid-capture, so input follows the
    /// route. The hardware input format can change (e.g. iPhone 48 kHz →
    /// HFP 48 kHz narrowband), so the `AVAudioConverter` is rebuilt too.
    /// No-op if capture isn't running.
    public func restartInputCaptureIfRunning() {
        guard running, onChunkHandler != nil else { return }
        inputNode?.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        inputNode = nil
        converter = nil
        // Keep any partially-accumulated bytes from bleeding a format
        // discontinuity into the next chunk.
        pendingPCM16.removeAll(keepingCapacity: true)
        do {
            try buildEngineAndTap()
        } catch {
            #if DEBUG
            print("[AudioCapture] restart on route change failed: \(error)")
            #endif
        }
    }

    /// Build the engine, converter, and tap from the input node's CURRENT
    /// hardware format. Shared by `start()` and `restartInputCaptureIfRunning()`.
    private func buildEngineAndTap() throws {
        guard let onChunk = onChunkHandler else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Build a converter from the hardware format to our 24 kHz
        // PCM16 target. AVAudioConverter handles arbitrary input
        // rates including the 48 kHz default on iPhone and the HFP mic.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(
                domain: "AudioCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "could not build converter \(inputFormat) → \(targetFormat)"]
            )
        }
        self.converter = converter
        self.engine = engine
        self.inputNode = input

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Phase 8 (audit-r10 overhaul) — mute check. We do NOT
            // tear down the tap when muted: keeping the engine warm
            // preserves the system AEC state so unmute resumes
            // instantly without a "first half-second is full of
            // echo" warm-up. The cost of discarding samples is
            // negligible vs the latency hit of restart.
            if VoiceMuteController.shared.isMuted {
                return
            }
            self.handle(buffer: buffer, onChunk: onChunk)
        }

        engine.prepare()
        try engine.start()
    }

    public func stop() {
        running = false
        onChunkHandler = nil
        inputNode?.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        inputNode = nil
        converter = nil
        pendingPCM16.removeAll(keepingCapacity: false)
        Task { @MainActor in
            // Drop the restart hook before deactivating so a late route
            // change can't resurrect a torn-down capture.
            W300AudioBridge.shared.captureRestartHandler = nil
            W300AudioBridge.shared.deactivate(for: .capture)
        }
    }

    private func handle(buffer: AVAudioPCMBuffer, onChunk: ChunkHandler) {
        guard let converter else { return }

        // Estimate output capacity. The conversion ratio plus a
        // generous safety margin avoids buffer-too-small errors when
        // the rate ratio isn't an integer.
        let inputFrames = AVAudioFrameCount(buffer.frameLength)
        let outputCapacity = AVAudioFrameCount(
            Double(inputFrames) * targetFormat.sampleRate / buffer.format.sampleRate * 2.0 + 1024
        )
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var providedInput = false
        let block: AVAudioConverterInputBlock = { _, status in
            if providedInput {
                status.pointee = .noDataNow
                return nil
            }
            providedInput = true
            status.pointee = .haveData
            return buffer
        }
        var error: NSError?
        let result = converter.convert(to: outBuffer, error: &error, withInputFrom: block)
        guard error == nil, result != .error, outBuffer.frameLength > 0 else { return }

        if let int16 = outBuffer.int16ChannelData?.pointee {
            let count = Int(outBuffer.frameLength)
            let bytes = Data(bytes: int16, count: count * 2)
            pendingPCM16.append(bytes)
        }

        // Emit accumulated bytes in chunkBytes-sized slices.
        while pendingPCM16.count >= chunkBytes {
            let slice = pendingPCM16.prefix(chunkBytes)
            onChunk(Data(slice))
            pendingPCM16.removeFirst(chunkBytes)
        }
    }
}
