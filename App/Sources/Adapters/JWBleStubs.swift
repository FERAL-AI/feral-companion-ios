// JWBleStubs.swift — companion-onboarding fix (2026-05-15).
//
// Compiled ONLY when the proprietary JWBle.framework is NOT present in
// Vendor/. Provides no-op stub implementations of every JWBle-derived
// public symbol the rest of the app references, so a fresh `git clone`
// produces a binary that builds, runs, pairs with the brain, and
// exercises every Phase 4 / 4b / 7b / 13 surface — only the JieLi W300
// glasses + Theora BLE peripheral support is unavailable.
//
// Devs with access to the JieLi vendor portal can drop the real
// `Vendor/JWBle.framework/` in place; the `#if canImport(JWBle)`
// branches across the four BLE-implementation files take over and this
// file disappears from the compilation unit. See `Vendor/README.md`
// for the exact framework + folder layout.

#if !canImport(JWBle)

import Foundation
import SwiftUI
import Combine

// FeralNode is from FeralNodeSDK in the same compilation unit; no
// import needed (single target).

/// Stub for JieLi BLE peripheral metadata. The real type lives inside
/// the proprietary JWBle.framework and exposes the device model
/// enumeration; we surface the name as a string for the stub so views
/// referencing `Discovered.model` still compile.
public enum JWBleDeviceModel: Equatable, Sendable {
    case unknown(String)

    public var displayName: String {
        if case .unknown(let n) = self { return n }
        return "unknown"
    }
}

@MainActor
public final class JWBleSession: ObservableObject {

    public static let shared = JWBleSession()

    public enum Phase: Equatable {
        case idle
        case scanning
        case connecting(name: String)
        case ready(name: String)
        case failed(reason: String)
    }

    public struct Discovered: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let macAddress: String?
        public let rssi: Int
        public let model: JWBleDeviceModel

        public static func == (lhs: Discovered, rhs: Discovered) -> Bool {
            lhs.id == rhs.id && lhs.rssi == rhs.rssi
        }
    }

    @Published public private(set) var phase: Phase = .failed(
        reason: "JWBle.framework not installed — see Vendor/README.md"
    )
    @Published public private(set) var discovered: [Discovered] = []

    private init() {}

    public func bind(brainNode: FeralNode) {
        // No-op. Real implementation wires JWBle callbacks to
        // `node.emit("glasses_status", ...)`.
    }

    public func disconnect() {
        // No-op.
    }

    public func attemptAutoReconnect() {
        // No-op.
    }

    public func startScan() {
        // No-op. UI will reflect `.failed(reason: ...)` so the user
        // knows the BLE stack isn't available in this build.
    }

    public func stopScan() {
        // No-op.
    }

    public func connect(to: Discovered) {
        // No-op.
    }
}

/// Stub for the JieLi W300 vendor adapter. Conforms to
/// `VendorAdapter` (FeralNodeSDK) so `BrainClient.alwaysOnSkills()`
/// and `DeviceStore.attachAdapter(...)` see the same API as the real
/// implementation — they just receive `available=false` semantics.
public final class JWBleAdapterWired: VendorAdapter {

    public let capability: String = "jw_health_glasses"
    public let extraCapabilities: [String] = [
        "heart_rate", "spo2", "temperature", "uv", "steps", "vibration",
    ]

    public init() {}

    public var capabilities: [String] {
        [capability] + extraCapabilities
    }

    public func attach(to node: FeralNode) async throws {
        // JWBle.framework not present in this build — no BLE
        // operations to wire. The brain will receive no
        // glasses_status / heart_rate / etc frames from this node,
        // and `health.measure` HUP actions will be reported as
        // unavailable.
    }

    public func detach() async {
        // No-op.
    }

    public func canHandleAction(named name: String) async -> Bool {
        false
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        // Reply with a truthful unavailable response so the brain's
        // mesh future resolves promptly and the LLM sees the right
        // error string ("JWBle SDK not installed in this build").
        if case .string(let actionId) = frame.payload["action_id"] ?? .null {
            try? await node.sendActionResponse(
                actionId: actionId,
                success: false,
                error: (
                    "jw_health_glasses unavailable: this FERAL Companion "
                    + "build was compiled without the proprietary JWBle "
                    + "framework. See Vendor/README.md."
                )
            )
        }
    }

    /// Mirrors the real adapter's audit-r9 surface. No-op in the stub.
    public func setHealthStore(_ store: AnyObject) {
        // Real implementation pipes W300 sensor reads into HealthStore.
    }
}

/// SwiftUI scan view fallback. Matches the real `BLEScanView`
/// call-site signature in `App/Sources/Views/BLEScanView.swift` so
/// `DevicesView` and `PeripheralsStepView` compile across both
/// modes. Renders a single "JWBle SDK not installed" message
/// instead of a peripheral list, with a Close button bound to
/// `isPresented` so users can dismiss the sheet.
public struct BLEScanView: View {
    @Binding var isPresented: Bool
    let capabilityId: String
    let title: String

    public init(isPresented: Binding<Bool>, capabilityId: String, title: String) {
        _isPresented = isPresented
        self.capabilityId = capabilityId
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    Text("Bluetooth scan unavailable")
                        .font(.headline)
                }
                Text(
                    "This FERAL Companion build was compiled without the "
                    + "JieLi BLE framework. The W300 glasses + Theora "
                    + "wristband require the proprietary `JWBle.framework` "
                    + "to be present in `Vendor/` at compile time. "
                    + "See `Vendor/README.md` for the drop-in process."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Text("Capability: \(capabilityId)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { isPresented = false }
                }
            }
        }
    }
}

#endif
