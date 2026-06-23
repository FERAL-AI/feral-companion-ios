import AVFoundation
import Combine
import Foundation

// W300AudioBridge — single AVAudioSession owner for FERAL voice I/O.
//
// This file is a deliberate port of the proven Theora glasses voice
// audio session policy (`Theora/Voice/SharedVoiceAudioEngine.swift`
// + `OpenAIRealtimeManager.configureAudioSession` in the Theora
// repo). That policy is the only configuration we have ever seen
// actually route both mic AND speaker through the W300's Bluetooth
// HFP/SCO link on real hardware, so this bridge mirrors it
// faithfully. Past attempts that added "helpful" extras — explicit
// loudspeaker overrides, A2DP allowance, preferred sample
// rate/buffer hints, ducking — all regressed voice back onto the
// iPhone. We stay minimal.
//
// What this layer owns:
//
//   1. Session policy. For glasses voice we set, EXACTLY:
//        .playAndRecord, .voiceChat, options = [.allowBluetoothHFP]
//      (with `.allowBluetooth` as the iOS-16 fallback spelling).
//      No `.allowBluetoothA2DP` (A2DP is media-only and is mutually
//      exclusive with the HFP SCO link an active mic needs — it
//      hijacks OUTPUT onto A2DP/iPhone). No `.defaultToSpeaker`,
//      no `.duckOthers`, no `.mixWithOthers`. No
//      `setPreferredSampleRate` / `setPreferredIOBufferDuration` —
//      letting CoreAudio negotiate with the HFP/SCO link is what
//      the proven reference does, and forcing 24 kHz / 10 ms IO
//      can collide with HFP's narrowband 8/16 kHz SCO negotiation
//      on the first activate.
//
//   2. Input selection. The HFP profile is bidirectional, so
//      calling `setPreferredInput(<HFP port>)` is sufficient to
//      put BOTH mic AND speaker on the glasses. We NEVER call
//      `overrideOutputAudioPort` — the reference doesn't, and any
//      output override (`.speaker` or `.none`) fights iOS's HFP
//      routing and is the historical cause of "speaker stuck on
//      iPhone" regressions in this app.
//
//   3. Late-HFP reacquire. iOS commonly surfaces the
//      `.bluetoothHFP` input ~0.5–1.5 s after `setActive(true)`
//      (sometimes after a route-change for an A2DP output that
//      arrives first). We poll 6× at 300 ms and, the moment HFP
//      appears, prefer it and ask `AudioCapture` to rebuild its
//      tap so input follows the glasses without restarting the
//      voice session.
//
//   4. Published `currentRoute` snapshot for the Devices tab so
//      the user can see at a glance whether voice is actually on
//      the glasses HFP route or on the iPhone.
//
// What this is NOT:
//   - Not a custom A2DP encoder (CoreAudio + AVAudioSession own it).
//   - Not a JieLi BLE-mic implementation (the W300 sends mic over
//     classic-BT HFP; CoreAudio sees it as an iPhone mic input).
//   - Not a fix for headset firmware that refuses to bond — that
//     belongs in `JWBleSession`. This layer assumes the OS already
//     has the route.

@MainActor
public final class W300AudioBridge: ObservableObject {

    public static let shared = W300AudioBridge()

    /// Snapshot of the currently selected audio route. Published so
    /// the Devices tab can render "Voice routed via {portName}" and
    /// flip to "iPhone speaker" when the user removes the W300.
    public struct RouteSnapshot: Equatable {
        public let inputName: String
        public let inputPortType: String
        public let outputName: String
        public let outputPortType: String
        /// True iff the input or output port type matches one of the
        /// classic-BT identifiers iOS uses for headsets (W300 etc.).
        public let isBluetoothHeadset: Bool
        /// True iff output is on the high-quality A2DP profile.
        public let isA2DPOutput: Bool
        public let updatedAt: Date

        public static let unknown = RouteSnapshot(
            inputName: "—",
            inputPortType: "—",
            outputName: "—",
            outputPortType: "—",
            isBluetoothHeadset: false,
            isA2DPOutput: false,
            updatedAt: .distantPast
        )
    }

    @Published public private(set) var currentRoute: RouteSnapshot = .unknown

    /// Last reason iOS gave for the most recent route change. Useful
    /// in Devices to explain "switched to Speaker because the W300
    /// disconnected".
    @Published public private(set) var lastRouteChangeReason: AVAudioSession.RouteChangeReason? = nil

    /// Set by AudioCapture/AudioPlayback so the bridge knows whether
    /// to keep the session alive on a route change. When neither is
    /// active we deactivate to release the BT route for other apps.
    public private(set) var captureActive: Bool = false
    public private(set) var playbackActive: Bool = false

    private var observers: [NSObjectProtocol] = []

    /// Bounded poll task that re-acquires the glasses HFP input after it
    /// surfaces late (~0.5–1.5 s post-activation). Cancelled on deactivate.
    private var hfpReacquireTask: Task<Void, Never>?

    /// Set by `AudioCapture` so the bridge can ask it to rebuild its input
    /// tap + converter onto a glasses HFP mic that arrived *after* capture
    /// already started (otherwise capture stays stuck on the iPhone mic).
    /// Cleared by `AudioCapture.stop()`.
    public var captureRestartHandler: (() -> Void)?

    private init() {
        installNotifications()
        refreshRoute()
    }

    // MARK: - Public API consumed by AudioCapture / AudioPlayback

    public enum Direction { case capture, playback }

    /// Activate the shared playAndRecord session for full-duplex voice
    /// over the glasses' bidirectional HFP/SCO link, then refresh the
    /// route snapshot. Idempotent — repeated calls are cheap.
    ///
    /// This is a direct port of the proven reference implementation:
    ///   • Category `.playAndRecord`, mode `.voiceChat`
    ///   • Options EXACTLY `[.allowBluetoothHFP]` (no A2DP, no
    ///     `.defaultToSpeaker`, no `.duckOthers`)
    ///   • `setActive(true)` (no flags, no preferred sample rate or
    ///     IO buffer hints — those collide with HFP/SCO negotiation
    ///     on first activate)
    ///   • If the HFP input is already visible, prefer it; otherwise
    ///     schedule a bounded reacquire poll. HFP is bidirectional —
    ///     `setPreferredInput(hfp)` is sufficient to put BOTH mic
    ///     AND speaker on the glasses. We NEVER call
    ///     `overrideOutputAudioPort`.
    public func activate(for direction: Direction) throws {
        let session = AVAudioSession.sharedInstance()
        // `.allowBluetoothHFP` (iOS 26) == `.allowBluetooth` (iOS 16+);
        // gate by availability so we get the non-deprecated spelling on
        // the newer SDK while still compiling/working on the iOS 16 target.
        var options: AVAudioSession.CategoryOptions = []
        if #available(iOS 26.0, *) {
            options.insert(.allowBluetoothHFP)
        } else {
            options.insert(.allowBluetooth)
        }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setActive(true)
        switch direction {
        case .capture: captureActive = true
        case .playback: playbackActive = true
        }
        // Prefer the glasses' HFP input if it's already surfaced. The
        // SCO link often takes ~0.5–1.5 s to appear after activation —
        // when it isn't here yet, poll for it (don't override output to
        // the iPhone speaker; that's the historical regression).
        if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(hfp)
        } else {
            scheduleHFPReacquire()
        }
        refreshRoute()
        logRoute("activate.\(direction == .capture ? "capture" : "playback")")
    }

    /// Poll up to 6× at 300 ms for the glasses' HFP mic to surface after
    /// `setActive(true)`. iOS commonly exposes the `.bluetoothHFP` port
    /// up to ~1.5 s late — and frequently *after* an output route
    /// appears, which is why preferring it on the first try fails. On
    /// success we prefer it (HFP is bidirectional so output follows)
    /// and — if capture is already running on the iPhone mic — ask
    /// `AudioCapture` to rebuild its tap so input moves to the glasses.
    /// Bounded: gives up after ~1.8 s and leaves voice on the iPhone
    /// rather than spinning forever. Mirrors the reference's
    /// `scheduleHFPReacquire` exactly — in particular, we do NOT call
    /// `overrideOutputAudioPort`.
    private func scheduleHFPReacquire() {
        hfpReacquireTask?.cancel()
        hfpReacquireTask = Task { @MainActor [weak self] in
            let session = AVAudioSession.sharedInstance()
            for _ in 1...6 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
                guard let self, !Task.isCancelled else { return }
                // Only chase the route while a voice session is live.
                guard self.captureActive || self.playbackActive else { return }
                if let hfp = session.availableInputs?.first(where: {
                    $0.portType == .bluetoothHFP
                }) {
                    try? session.setPreferredInput(hfp)
                    if self.captureActive {
                        // Capture is on the iPhone mic — rebuild its tap
                        // so it now reads from the glasses.
                        self.captureRestartHandler?()
                    }
                    self.refreshRoute()
                    self.logRoute("hfp-reacquired")
                    return
                }
            }
            // Gave up — staying on the iPhone mic; the published route
            // snapshot reflects the truth for the UI.
            self?.refreshRoute()
            self?.logRoute("hfp-reacquire-gaveup")
        }
    }

    /// Mark a direction as inactive. When both directions are off
    /// we deactivate the session and notify other audio sessions
    /// (so e.g. Music can resume).
    public func deactivate(for direction: Direction) {
        switch direction {
        case .capture: captureActive = false
        case .playback: playbackActive = false
        }
        guard !captureActive, !playbackActive else { return }
        // No voice direction left — stop any in-flight HFP poll so it can't
        // re-assert a route after we've torn the session down.
        hfpReacquireTask?.cancel()
        hfpReacquireTask = nil
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            // Deactivation failure is non-fatal but worth logging.
            #if DEBUG
            print("[W300AudioBridge] setActive(false) failed: \(error)")
            #endif
        }
        refreshRoute()
    }

    /// Force-refresh the published route snapshot (e.g. on app
    /// foreground). Cheap; safe to call.
    public func refreshRoute() {
        currentRoute = Self.snapshot()
    }

    /// Log the live `AVAudioSession.currentRoute` (inputs/outputs, whether
    /// `.bluetoothHFP` is on each side, and whether an HFP input is even
    /// available yet) to the in-app DebugLog. Lets the operator verify at
    /// runtime — from the Settings → Debug log, no Xcode attach — that voice
    /// is actually on the glasses HFP route vs the iPhone. Called on
    /// activate, every relevant route change, and HFP (re)acquire.
    private func logRoute(_ context: String) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let ins = route.inputs.map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ",")
        let outs = route.outputs.map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ",")
        let hfpIn = route.inputs.contains { $0.portType == .bluetoothHFP }
        let hfpOut = route.outputs.contains { $0.portType == .bluetoothHFP }
        let hfpAvail = (session.availableInputs ?? [])
            .contains { $0.portType == .bluetoothHFP }
        DebugLog.shared.info(
            "audio-route[\(context)] in=[\(ins.isEmpty ? "—" : ins)] "
            + "out=[\(outs.isEmpty ? "—" : outs)] "
            + "hfpIn=\(hfpIn) hfpOut=\(hfpOut) hfpAvailable=\(hfpAvail)"
        )
    }

    /// Re-assert the BT input/output preference for the CURRENT session
    /// without flipping the capture/playback direction flags. Called when
    /// an external event — e.g. `JWBleSession` finishing W300 HFP headset
    /// pairing — makes a new `.bluetoothHFP` route available while a voice
    /// session is already running, so voice immediately follows the glasses
    /// instead of waiting for the next `activate(...)`. When no session is
    /// active this just refreshes the published snapshot.
    public func reassertRouteIfActive() {
        guard captureActive || playbackActive else {
            refreshRoute()
            return
        }
        let session = AVAudioSession.sharedInstance()
        if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            // HFP mic is here — prefer it (HFP is bidirectional so the
            // glasses speaker follows). If capture is still on the iPhone
            // mic, rebuild its tap so input follows the glasses too.
            try? session.setPreferredInput(hfp)
            if captureActive { captureRestartHandler?() }
            refreshRoute()
            logRoute("reassert.hfp-acquired")
        } else {
            // SDK says the headset is connected but iOS hasn't surfaced
            // the HFP mic yet — poll for it. Never override output to
            // the iPhone speaker; that's what kept voice off the glasses.
            scheduleHFPReacquire()
        }
    }

    // MARK: - Internals

    private func installNotifications() {
        let center = NotificationCenter.default
        let routeObs = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleRouteChange(note: note)
            }
        }
        let interruptObs = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleInterruption(note: note)
            }
        }
        observers.append(contentsOf: [routeObs, interruptObs])
    }

    private func handleRouteChange(note: Notification) {
        if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        {
            lastRouteChangeReason = reason
            // Re-assert the preferred HFP input whenever the system
            // tells us the route landscape changed. The previous gate
            // was `.newDeviceAvailable` only, which missed the very
            // common case of the W300 negotiating its HFP mic profile
            // a fraction of a second AFTER its initial A2DP output
            // appeared — by then we had already locked in built-in
            // mic. Adding `.oldDeviceUnavailable`,
            // `.routeConfigurationChange`, `.override`, and
            // `.categoryChange` lets us re-prefer the HFP mic any
            // time iOS reshapes the route graph. `setPreferredInput`
            // is idempotent so re-running on transient changes is
            // safe. We do NOT touch `overrideOutputAudioPort` — HFP
            // is bidirectional and the reference proves the speaker
            // follows the preferred input.
            let reEvaluateReasons: Set<AVAudioSession.RouteChangeReason> = [
                .newDeviceAvailable,
                .oldDeviceUnavailable,
                .routeConfigurationChange,
                .override,
                .categoryChange,
            ]
            if reEvaluateReasons.contains(reason), captureActive || playbackActive {
                let session = AVAudioSession.sharedInstance()
                let hfpAvailable = session.availableInputs?.first(where: {
                    $0.portType == .bluetoothHFP
                })
                if let hfp = hfpAvailable {
                    try? session.setPreferredInput(hfp)
                }
                switch reason {
                case .newDeviceAvailable, .routeConfigurationChange:
                    if hfpAvailable != nil {
                        // Glasses mic just came online mid-capture — move
                        // the capture tap from the iPhone mic onto it.
                        if captureActive { captureRestartHandler?() }
                    } else {
                        // Output may be up but the HFP mic is still
                        // negotiating (it usually lands a beat later).
                        scheduleHFPReacquire()
                    }
                case .oldDeviceUnavailable:
                    // Glasses dropped — stop chasing the HFP route and
                    // let voice fall back to the iPhone cleanly (rebuild
                    // the capture tap onto the now-current iPhone mic).
                    hfpReacquireTask?.cancel()
                    if captureActive { captureRestartHandler?() }
                default:
                    break
                }
                logRoute("routeChange.\(reason.rawValue)")
            }
        }
        refreshRoute()
    }

    private func handleInterruption(note: Notification) {
        // We don't auto-resume here — BrainClient owns the voice
        // lifecycle and decides whether to restart. Just refresh
        // so the UI flips.
        refreshRoute()
    }

    private static func snapshot() -> RouteSnapshot {
        let route = AVAudioSession.sharedInstance().currentRoute
        let input = route.inputs.first
        let output = route.outputs.first
        let inputType = input?.portType.rawValue ?? "—"
        let outputType = output?.portType.rawValue ?? "—"
        let btTypes: Set<String> = [
            AVAudioSession.Port.bluetoothHFP.rawValue,
            AVAudioSession.Port.bluetoothA2DP.rawValue,
            AVAudioSession.Port.bluetoothLE.rawValue,
        ]
        let isBT = btTypes.contains(inputType) || btTypes.contains(outputType)
        let isA2DP = outputType == AVAudioSession.Port.bluetoothA2DP.rawValue
        return RouteSnapshot(
            inputName: input?.portName ?? "—",
            inputPortType: inputType,
            outputName: output?.portName ?? "—",
            outputPortType: outputType,
            isBluetoothHeadset: isBT,
            isA2DPOutput: isA2DP,
            updatedAt: Date()
        )
    }

    deinit {
        let center = NotificationCenter.default
        for obs in observers { center.removeObserver(obs) }
    }
}
