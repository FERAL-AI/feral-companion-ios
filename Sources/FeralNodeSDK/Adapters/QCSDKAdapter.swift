import Foundation

/// W610 open-source Meta-Ray-Ban-style glasses adapter — wraps
/// QCSDK.framework. The Moshi voice-streaming LLM scaffolding that
/// ships alongside (moshi-swift) is separately wired; this adapter
/// focuses on the BLE + camera + audio pipeline, not the LLM.
///
/// Lane 11 (audit-r14) wire-up status: ``full mode`` — when the host
/// project drops ``QCSDK.framework`` into ``Vendor/QCSDK.framework``
/// (per ``docs/VENDOR_SETUP.md``), the host's xcodegen spec links it
/// in and ``canImport(QCSDK)`` is true. This file stays in
/// ``stub`` mode otherwise: ``attach`` throws ``adapterNotWired`` so
/// the build never silently advertises a capability it can't
/// service.
///
/// **Wire-up checklist** (mirrors
/// ``ASOS/AUDIT-r14/phase2/prompts/11-nodes-ios-hardware.md`` and the
/// patterns proven in the user's reference
/// ``~/Desktop/Theora-backend-ML/W610/QCSDKDemo``):
///
/// 1. **Vendor drop.** Copy ``QCSDK.framework`` into
///    ``Vendor/QCSDK.framework``. The framework is gitignored (NDA);
///    operators fetch it from the secured asset bucket or from the
///    proven W630_D344 demo project at
///    ``~/Desktop/Theora-backend-ML/W610/QCSDKDemo/QCSDK.framework``.
///    Document the NDA terms in ``docs/VENDOR_SETUP.md``.
///
/// 2. **Pairing.** Use the QCSDK ``QCSDKCmdCreator`` discovery
///    sequence: start scanning, filter for ``W630*`` / ``W610*``
///    advertisements, connect via CoreBluetooth, complete the
///    handshake. Reference: ``QCSDKDemo/QCSDKDemo/QCDemoMainViewController``
///    in the proven demo (``xcode-logs.md`` shows a successful
///    handshake at 16 kHz BT-HFP).
///
/// 3. **Camera frames.** Once connected, subscribe to the QCSDK
///    photo / video frame callback. Encode each frame to JPEG and
///    forward via ``node.emitGlassesFrame(deviceId:jpegBase64:
///    width:height:source:"w610",sequence:)`` — NOT
///    ``emitVideoFrame``. The brain dispatches ``glasses_frame``
///    into the per-device GlassesBuffer (HUP_SPEC §5.4.3), which
///    the orchestrator's vision-context-attach reads with a 30 s
///    freshness gate.
///
/// 4. **Audio frames.** Route the 16 kHz BT-HFP stream through
///    ``node.emitAudioFrame(opusBase64:sampleRate:16000,channels:1,
///    sequence:,frameMs:20)`` — the brain enforces 64 KiB per Opus
///    packet (HUP_SPEC §5.4.1). The proven demo uses WhisperKit
///    Tiny for on-device STT; that lives in
///    ``moshi-swift`` / WhisperKit and bridges into Lane 05's
///    ``audio.chained_providers`` once we ship the
///    ``whisperkit_on_device`` provider.
///
/// 5. **HUD actions.** Map ``display_hud``, ``capture_frame``,
///    ``start_recording``, ``stop_recording`` ``hup_action_request``
///    frames to the QCSDK command set in ``handleAction``. The
///    canonical command opcodes are documented in
///    ``iOS_SDK_Development_Guide.pdf`` shipped alongside the
///    framework.
///
/// 6. **Disconnect.** On ``detach`` release the CoreBluetooth
///    peripheral subscription and tear down the QCSDK session so
///    the radio doesn't keep the device awake after the app
///    backgrounds.
///
/// The implementation below stays as a strict scaffold (throws on
/// attach) until step 1 lands. Even with the binary in place we
/// gate behind ``#if canImport(QCSDK)`` so the stub-mode CI build
/// still compiles cleanly.
#if canImport(QCSDK)
import QCSDK

public final class QCSDKAdapter: VendorAdapter {
    public let capability: String = "w610_glasses"
    public let extraCapabilities: [String] = ["audio_frame", "glasses_frame"]

    private weak var attachedNode: FeralNode?

    public init() {}

    public func attach(to node: FeralNode) async throws {
        self.attachedNode = node
        // Real wire-up lives here; see the wire-up checklist above.
        // The throw is replaced with the actual QCSDKCmdCreator
        // discovery + handshake when the vendor drop completes.
        throw FeralNodeError.adapterNotWired(
            capability: capability,
            reason: "QCSDK.framework is present but the discovery / " +
                    "frame-forwarding wire-up is still in progress. " +
                    "See QCSDKAdapter.swift wire-up checklist steps 2-6."
        )
    }

    public func detach() async {
        attachedNode = nil
    }

    public func canHandleAction(named name: String) async -> Bool {
        return ["display_hud", "capture_frame", "start_recording", "stop_recording"].contains(name)
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        // Bridged to QCSDKCmdCreator opcodes per
        // iOS_SDK_Development_Guide.pdf §4 (HUD) / §5 (capture).
    }
}
#else
public final class QCSDKAdapter: VendorAdapter {
    public let capability: String = "w610_glasses"

    public init() {}

    public func attach(to node: FeralNode) async throws {
        throw FeralNodeError.adapterNotWired(
            capability: capability,
            reason: "QCSDK.framework is not linked into the host app. " +
                    "See QCSDKAdapter.swift wire-up checklist (step 1) " +
                    "and docs/VENDOR_SETUP.md for the NDA framework " +
                    "fetch."
        )
    }

    public func detach() async {
        // No-op until wire-up.
    }

    public func canHandleAction(named name: String) async -> Bool {
        return ["display_hud", "capture_frame", "start_recording", "stop_recording"].contains(name)
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        // No-op in stub mode — host UI surfaces adapterNotWired error
        // when the operator activates this capability.
    }
}
#endif
