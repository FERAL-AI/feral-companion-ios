import Foundation
import AVFoundation
import CoreImage
import UIKit
import Metal

/// Phone-camera-as-glasses fallback for THESIS_SCENARIOS S5.
///
/// When the user doesn't have a W610 (or any smart-glasses) paired,
/// the rear iPhone camera streams ~1 fps JPEGs to the brain as
/// HUP ``glasses_frame`` envelopes so the orchestrator's
/// vision-context-attach (Lane 08) has fresh frames to attach to
/// voice/chat turns. The protocol is identical to the real-glasses
/// path; the brain doesn't know the difference (other than the
/// ``source="camera_fallback"`` provenance label).
///
/// Gated by an explicit Settings toggle —
/// ``UserDefaults.standard.bool(forKey: "feral.demo.camera_as_glasses")``
/// — so the camera doesn't quietly run in the background of the
/// pre-paired app. The Settings tab surfaces the toggle as
/// "Demo mode: use phone camera as glasses". When the toggle is off
/// the adapter is fully detached (no AVCaptureSession running, no
/// permission prompt fired).
///
/// 1 fps is the documented default in
/// ``ASOS/AUDIT-r14/phase2/prompts/11-nodes-ios-hardware.md``
/// (under cost budget for vision LLM). The frame interval is
/// configurable via the public initialiser for the live verify
/// section so we can dial it up to ~3 fps when recording the demo
/// video without blowing the orchestrator's vision-cost budget.
@MainActor
public final class CameraGlassesAdapter: NSObject, VendorAdapter, AVCaptureVideoDataOutputSampleBufferDelegate {

    public let capability: String = "camera_glasses_fallback"

    private weak var attachedNode: FeralNode?
    private let captureQueue = DispatchQueue(label: "ai.feral.camera_glasses", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?

    /// Wall-clock seconds between emitted frames. Default 1.0 — the
    /// Lane 11 cost-budget contract. Public so the live-verify script
    /// can construct the adapter directly with a tighter interval.
    public let frameIntervalSeconds: TimeInterval

    /// JPEG quality. 0.6 keeps each frame comfortably below the
    /// 512 KiB ``glasses_frame`` cap on typical iPhone rear cameras.
    public let jpegQuality: CGFloat

    private var lastEmitWallclock: CFAbsoluteTime = 0
    private var frameSequence: Int = 0

    public init(
        frameIntervalSeconds: TimeInterval = 1.0,
        jpegQuality: CGFloat = 0.6
    ) {
        precondition(frameIntervalSeconds > 0, "frameIntervalSeconds must be > 0")
        self.frameIntervalSeconds = frameIntervalSeconds
        self.jpegQuality = jpegQuality
        super.init()
    }

    // MARK: - VendorAdapter

    public func attach(to node: FeralNode) async throws {
        // Honor the explicit demo toggle. We refuse to start the
        // camera otherwise even if a brain explicitly grants the
        // capability — the user must opt in from Settings first.
        guard UserDefaults.standard.bool(forKey: "feral.demo.camera_as_glasses") else {
            throw FeralNodeError.adapterNotWired(
                capability: capability,
                reason: "Demo toggle 'Use phone camera as glasses source' is off. " +
                        "Enable it in Settings -> Demo to start streaming frames."
            )
        }

        // Permission gate.
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                throw FeralNodeError.permissionDenied(
                    capability: capability,
                    reason: "User denied camera access; cannot stream glasses_frame."
                )
            }
        } else if auth == .denied || auth == .restricted {
            throw FeralNodeError.permissionDenied(
                capability: capability,
                reason: "Camera access denied. Open Settings -> Privacy -> Camera and enable FERAL."
            )
        }

        self.attachedNode = node
        try startCaptureSession()
    }

    public func detach() async {
        attachedNode = nil
        stopCaptureSession()
    }

    public func canHandleAction(named name: String) async -> Bool {
        // The adapter is observe-only (a video source). No
        // hup_action_request to handle; explicit false so the brain's
        // capability registry doesn't dispatch arbitrary actions here.
        return false
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        // No-op (see canHandleAction).
    }

    // MARK: - AVCaptureSession lifecycle

    private func startCaptureSession() throws {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480  // matches the ~1 fps cost-budget envelope

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            throw FeralNodeError.adapterNotWired(
                capability: capability,
                reason: "Rear camera unavailable (simulator? non-camera iPad?)."
            )
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw FeralNodeError.adapterNotWired(
                capability: capability,
                reason: "Capture session refused the rear camera input."
            )
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw FeralNodeError.adapterNotWired(
                capability: capability,
                reason: "Capture session refused the video output."
            )
        }
        session.addOutput(output)

        captureQueue.async { session.startRunning() }
        self.session = session
        self.output = output
    }

    private func stopCaptureSession() {
        if let session = session {
            captureQueue.async { session.stopRunning() }
        }
        session = nil
        output = nil
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    //
    // ``captureOutput`` runs on ``captureQueue`` (background), so the
    // throttle + JPEG encode happen off the main actor. The HUP emit
    // is scheduled back onto a Task so the FeralNode actor's
    // serialization handles the WS send.

    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Snapshot the throttle state on the main actor (the adapter
        // is @MainActor-isolated so the deltas are reconciled there).
        Task { @MainActor in
            self.handleFrameOnMainActor(pixelBuffer: pixelBuffer, capturedAt: now)
        }
    }

    private func handleFrameOnMainActor(pixelBuffer: CVPixelBuffer, capturedAt now: CFAbsoluteTime) {
        let elapsed = now - lastEmitWallclock
        guard elapsed >= frameIntervalSeconds else { return }
        lastEmitWallclock = now

        // Re-derive the device id from the brain-stable node id so the
        // brain's GlassesBuffer buckets across reboots without
        // colliding with a real W610. Lane 11 contract:
        // ``source="camera_fallback"``, ``device_id`` is the node id.
        guard let node = attachedNode else { return }
        let deviceId = node.nodeId

        Task.detached(priority: .utility) { [jpegQuality, weak self] in
            guard let jpegData = jpegFrom(pixelBuffer: pixelBuffer, quality: jpegQuality) else {
                return
            }
            let b64 = jpegData.base64EncodedString()
            await self?.emitFrame(deviceId: deviceId, jpegBase64: b64, pixelBuffer: pixelBuffer)
        }
    }

    private func emitFrame(deviceId: String, jpegBase64: String, pixelBuffer: CVPixelBuffer) async {
        guard let node = attachedNode else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        frameSequence &+= 1
        do {
            try await node.emitGlassesFrame(
                deviceId: deviceId,
                jpegBase64: jpegBase64,
                width: width,
                height: height,
                source: "camera_fallback",
                sequence: frameSequence
            )
        } catch {
            // Best-effort — the orchestrator handles missing frames
            // gracefully (falls back to ScreenLoop / VisionBuffer).
            DebugLog.shared.warning(
                "camera_glasses emit failed: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - JPEG encoder (nonisolated helper)

private let ciContext: CIContext = {
    if let device = MTLCreateSystemDefaultDevice() {
        return CIContext(mtlDevice: device)
    }
    return CIContext(options: nil)
}()

private func jpegFrom(pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
    let uiImage = UIImage(cgImage: cgImage)
    return uiImage.jpegData(compressionQuality: quality)
}
