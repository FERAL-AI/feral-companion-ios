import AVFoundation
import Combine
import Foundation

// Audit-r8 brief #03 — Phase 6 W300AudioBridge.
//
// Centralises every AVAudioSession decision so AudioCapture,
// AudioPlayback, and the Devices/Health UIs all read the SAME truth
// about which BT route the system has selected. The W300 (and any
// classic Bluetooth audio peripheral — AirPods, car BT, etc.)
// participate as ROUTES; we don't drive the codec or the firmware
// pairing — iOS owns that. What we do own:
//
//   1. The session policy: `playAndRecord`, `.voiceChat`, options
//      `[.allowBluetooth, .duckOthers]` — **HFP ONLY**. The glasses'
//      mic + speaker ride the Bluetooth HFP/SCO link, which is
//      bidirectional. `.allowBluetooth` is the HFP enable flag
//      (renamed `.allowBluetoothHFP` on the iOS 26 SDK; identical
//      meaning, and `.allowBluetooth` still compiles + works on the
//      iOS 16 deployment target). We deliberately do **NOT** pass
//      `.allowBluetoothA2DP`: A2DP is a one-way media-out profile
//      that is mutually exclusive with the HFP SCO link an active
//      mic needs. Allowing it makes iOS prefer A2DP for OUTPUT, so
//      the assistant's voice routes to A2DP / the iPhone speaker
//      instead of the glasses speaker (an observed regression). For
//      voice (24 kHz mono) HFP is the correct and only profile.
//
//   2. Route observation: published `currentRoute` so the Devices
//      tab can show "Voice in/out routed via W300" with the actual
//      port name iOS reports. No more lying about glasses voice.
//
//   3. Route-change reactions: when the user yanks the W300 mid-
//      conversation, BrainClient gets a chance to gracefully tear
//      down voice instead of hanging in `voiceActive = true`.
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
    public func activate(for direction: Direction) throws {
        let session = AVAudioSession.sharedInstance()
        // HFP ONLY — see the file header (item 1). `.allowBluetooth` is
        // the HFP enable flag (== `.allowBluetoothHFP` on iOS 26). We must
        // NOT add `.allowBluetoothA2DP`: it hijacks OUTPUT to A2DP / the
        // iPhone speaker and kills glasses-speaker playback while the mic
        // is active. `.voiceChat` mode keeps system AEC on (do NOT use
        // `.measurement` — it disables HFP input). `.duckOthers` ducks
        // background media without disabling AEC. No `.mixWithOthers`
        // (non-AEC mix path → mic picks up the assistant's own TTS) and no
        // `.defaultToSpeaker` (forces the iPhone loudspeaker).
        // `.allowBluetoothHFP` (iOS 26) == `.allowBluetooth` (iOS 16+);
        // gate by availability so we get the non-deprecated spelling on the
        // newer SDK while still compiling/working on the iOS 16 target.
        var options: AVAudioSession.CategoryOptions = [.duckOthers]
        if #available(iOS 26.0, *) {
            options.insert(.allowBluetoothHFP)
        } else {
            options.insert(.allowBluetooth)
        }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setPreferredSampleRate(24000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true, options: [])
        switch direction {
        case .capture: captureActive = true
        case .playback: playbackActive = true
        }
        // `.allowBluetooth` only makes the glasses' HFP mic AVAILABLE — iOS
        // otherwise keeps the built-in mic selected, so voice IN (and,
        // since HFP is bidirectional, voice OUT) would stay on the phone.
        // Prefer the HFP input, then route output to match. The HFP/SCO
        // link often takes ~0.5–1.5 s to appear after activation, so if it
        // isn't here yet, poll for it instead of forcing the iPhone speaker.
        let onBluetooth = Self.preferBluetoothInput(on: session)
        Self.applyOutputRoute(on: session, bluetooth: onBluetooth)
        if !onBluetooth {
            scheduleHFPReacquire()
        }
        refreshRoute()
        logRoute("activate.\(direction == .capture ? "capture" : "playback")")
    }

    /// Select a connected Bluetooth headset (W300 / AirPods / any HFP or
    /// LE-audio peripheral) as the session's preferred input when one is
    /// present. HFP is a bidirectional profile, so preferring the BT mic
    /// also pulls playback onto the headset. When no BT input is available
    /// the preference is cleared so iOS falls back to its default (built-in
    /// mic / speaker) cleanly.
    /// Returns true iff a Bluetooth headset input was selected as preferred.
    @discardableResult
    private static func preferBluetoothInput(on session: AVAudioSession) -> Bool {
        let available = session.availableInputs ?? []
        // Prefer HFP specifically (the glasses' bidirectional voice link),
        // then fall back to LE-audio. A2DP never appears as an INPUT, so it
        // can't be selected here.
        let bt = available.first(where: { $0.portType == .bluetoothHFP })
            ?? available.first(where: { $0.portType == .bluetoothLE })
        do {
            if let bt {
                try session.setPreferredInput(bt)
                return true
            } else {
                try session.setPreferredInput(nil)
                return false
            }
        } catch {
            #if DEBUG
            print("[W300AudioBridge] setPreferredInput failed: \(error)")
            #endif
            return false
        }
    }

    /// Poll up to 6× at 300 ms for the glasses' HFP mic to surface after
    /// `setActive(true)`. iOS commonly exposes the `.bluetoothHFP` port a
    /// second or so late — and frequently *after* an output route appears,
    /// which is why preferring it on the first try fails. On success we
    /// prefer it, reassert output onto the glasses, and — if capture is
    /// already running on the iPhone mic — ask `AudioCapture` to rebuild
    /// its tap so input moves to the glasses. Bounded: gives up after
    /// ~1.8 s and leaves voice on the iPhone rather than spinning forever.
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
                    Self.applyOutputRoute(on: session, bluetooth: true)
                    if self.captureActive {
                        // Capture is on the iPhone mic — rebuild its tap so
                        // it now reads from the glasses.
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

    /// Route playback to match the input: when a BT headset (W300) is the
    /// input, clear any speaker override so output follows the headset (HFP
    /// is bidirectional); otherwise force the loudspeaker (the behavior the
    /// old `.defaultToSpeaker` category option provided for phone-only use).
    ///
    /// Crucially, we only force the iPhone loudspeaker when the current
    /// route has NO Bluetooth output present. The W300 commonly exposes
    /// an A2DP OUTPUT route without an HFP/LE MIC — in that case
    /// `preferBluetoothInput` returns false (no BT mic available), but
    /// blindly calling `overrideOutputAudioPort(.speaker)` would yank
    /// playback off the W300 A2DP route and back to the phone speaker
    /// (the same regression `.defaultToSpeaker` used to cause). Checking
    /// `session.currentRoute.outputs` preserves W300 A2DP playback while
    /// still defaulting to the loudspeaker for phone-only hands-free use.
    private static func applyOutputRoute(on session: AVAudioSession, bluetooth: Bool) {
        do {
            if bluetooth {
                try session.overrideOutputAudioPort(.none)
                return
            }
            let btOutputTypes: Set<AVAudioSession.Port> = [
                .bluetoothHFP, .bluetoothA2DP, .bluetoothLE,
            ]
            let hasBTOutput = session.currentRoute.outputs.contains { output in
                btOutputTypes.contains(output.portType)
            }
            try session.overrideOutputAudioPort(hasBTOutput ? .none : .speaker)
        } catch {
            #if DEBUG
            print("[W300AudioBridge] overrideOutputAudioPort failed: \(error)")
            #endif
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
        let onBluetooth = Self.preferBluetoothInput(on: session)
        Self.applyOutputRoute(on: session, bluetooth: onBluetooth)
        let onHFP = session.currentRoute.inputs.contains {
            $0.portType == .bluetoothHFP
        }
        if onHFP {
            // The glasses HFP route is live — if capture is running on the
            // iPhone mic, rebuild its tap so input follows the glasses.
            if captureActive { captureRestartHandler?() }
        } else {
            // SDK says the headset is connected but iOS hasn't surfaced the
            // HFP mic yet — poll for it.
            scheduleHFPReacquire()
        }
        refreshRoute()
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
            // Re-assert input + output routing whenever the system
            // tells us the route landscape changed. The previous gate
            // was `.newDeviceAvailable` only, which missed the very
            // common case of the W300 negotiating its HFP/LE mic
            // profile a fraction of a second AFTER the initial A2DP
            // output appeared — by then we had already locked in
            // built-in mic + speaker. Adding `.oldDeviceUnavailable`,
            // `.routeConfigurationChange`, `.override`, and
            // `.categoryChange` lets us re-apply the correct route
            // whenever iOS reshapes the route graph. The
            // `setPreferredInput` / `overrideOutputAudioPort` calls
            // are idempotent enough that re-running on a transient
            // change doesn't introduce a feedback loop.
            let reEvaluateReasons: Set<AVAudioSession.RouteChangeReason> = [
                .newDeviceAvailable,
                .oldDeviceUnavailable,
                .routeConfigurationChange,
                .override,
                .categoryChange,
            ]
            if reEvaluateReasons.contains(reason), captureActive || playbackActive {
                let session = AVAudioSession.sharedInstance()
                let onBluetooth = Self.preferBluetoothInput(on: session)
                Self.applyOutputRoute(on: session, bluetooth: onBluetooth)
                let onHFP = session.currentRoute.inputs.contains {
                    $0.portType == .bluetoothHFP
                }
                switch reason {
                case .newDeviceAvailable, .routeConfigurationChange:
                    if onHFP {
                        // Glasses mic just came online mid-capture — move
                        // the capture tap from the iPhone mic onto it.
                        if captureActive { captureRestartHandler?() }
                    } else {
                        // Output may be up but the HFP mic is still
                        // negotiating (it usually lands a beat later).
                        scheduleHFPReacquire()
                    }
                case .oldDeviceUnavailable:
                    // Glasses dropped — stop chasing the HFP route and let
                    // voice fall back to the iPhone cleanly (rebuild the
                    // capture tap onto the now-current iPhone mic).
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
