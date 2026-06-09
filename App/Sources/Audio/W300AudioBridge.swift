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
//      including `.allowBluetooth` (HFP mic, narrowband 8/16 kHz)
//      AND `.allowBluetoothA2DP` (high-quality stereo OUT). The old
//      capture path requested only `.allowBluetooth`, which on iOS
//      26 disables high-quality A2DP output for the same session
//      and forces the W300 mic to handle TTS playback through the
//      narrowband HFP profile. Adding `.allowBluetoothA2DP` here
//      lets iOS pick the better profile for each direction.
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

    private init() {
        installNotifications()
        refreshRoute()
    }

    // MARK: - Public API consumed by AudioCapture / AudioPlayback

    public enum Direction { case capture, playback }

    /// Activate the shared playAndRecord session with options that
    /// allow BOTH HFP mic and A2DP output, then refresh the route
    /// snapshot. Idempotent — repeated calls are cheap.
    public func activate(for direction: Direction) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                // NOTE: `.defaultToSpeaker` was REMOVED here. It forced
                // playback to the built-in loudspeaker even when a BT
                // headset (W300) was the preferred input — so TTS stayed on
                // the phone while the mic was on the glasses. We now set the
                // output route explicitly below: follow the BT headset when
                // one is selected, else override to speaker for phone-only.
                // HFP / classic BT mic + speaker (narrowband).
                .allowBluetooth,
                // A2DP output (high-quality stereo). Audit-r8 brief
                // #03 gap: the prior capture-only path omitted this
                // and forced TTS through HFP whenever the W300 was
                // also acting as the mic. Adding it lets the system
                // pick the better profile per direction.
                .allowBluetoothA2DP,
                // Phase 8 (audit-r10 overhaul) — `.mixWithOthers`
                // was REMOVED. It coexists badly with `.voiceChat`
                // mode's loudspeaker echo cancellation: iOS hands
                // the speaker output through a non-AEC mix path
                // when this flag is set, and the built-in mic then
                // picks up the assistant's own TTS — exactly the
                // "voice itself echoes, replying to its own audio
                // when not using headphones" operator complaint.
                // `.duckOthers` stays so background audio (Music,
                // podcasts) ducks while FERAL is speaking, without
                // disabling AEC.
                .duckOthers,
            ]
        )
        try session.setPreferredSampleRate(24000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true, options: [])
        // `.allowBluetooth` only makes the W300's classic-BT HFP mic
        // AVAILABLE — iOS otherwise keeps the built-in mic selected, so
        // voice IN (and, since HFP is bidirectional, voice OUT) stayed on
        // the phone even with the glasses connected. Prefer the BT input,
        // then route output to match (headset if BT, speaker otherwise).
        let onBluetooth = Self.preferBluetoothInput(on: session)
        Self.applyOutputRoute(on: session, bluetooth: onBluetooth)
        switch direction {
        case .capture: captureActive = true
        case .playback: playbackActive = true
        }
        refreshRoute()
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
        let btInputTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE]
        let available = session.availableInputs ?? []
        do {
            if let bt = available.first(where: { btInputTypes.contains($0.portType) }) {
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
