import Foundation
import SwiftUI

/// Catalog of every adapter the app knows about. Each entry can be
/// in one of three states: not-tried, active (attached), or failed.
/// The Devices tab binds to this directly so the user can flip
/// adapters on or off without touching code.
@MainActor
public final class DeviceStore: ObservableObject {

    public struct Entry: Identifiable, Equatable {
        public let id: String                // capability string
        public let displayName: String
        public let summary: String
        public let category: Category
        public var status: Status

        public enum Category: String, CaseIterable {
            case iphoneBuiltin = "iPhone built-ins"
            case bluetooth = "Bluetooth devices"
            case healthKitMediated = "Sync from Apple Health"

            public var icon: String {
                switch self {
                case .iphoneBuiltin: return "iphone"
                case .bluetooth: return "antenna.radiowaves.left.and.right"
                case .healthKitMediated: return "heart.text.square"
                }
            }
        }

        public enum Status: Equatable {
            case available
            case active
            case failed(reason: String)
            case unsupported(reason: String)
        }
    }

    @Published public private(set) var entries: [Entry] = []
    public private(set) var activeAdapters: [VendorAdapter] = []

    /// Lazily-initialized adapter instances keyed by capability.
    private var adapterByCapability: [String: VendorAdapter] = [:]

    public init() {
        seedCatalog()
    }

    // MARK: - Catalog

    private func seedCatalog() {
        entries = [
            Entry(
                id: "apple_healthkit",
                displayName: "Apple Health",
                summary: "Reads HR, SpO2, steps, sleep from any wearable that syncs to Apple Health (Apple Watch, Whoop, Garmin, Oura, Fitbit, Polar, …)",
                category: .healthKitMediated,
                status: .available
            ),
            Entry(
                id: "iphone_camera",
                displayName: "iPhone camera + microphone",
                summary: "Phone-as-glasses fallback. Streams camera frames + voice when no external glasses are paired.",
                category: .iphoneBuiltin,
                status: .available
            ),
            Entry(
                id: "jw_health_glasses",
                displayName: "JieLi Health Glasses (W300)",
                summary: "FERAL prototype glasses. HR, SpO2, body temp, UV, steps, vibration over BLE.",
                category: .bluetooth,
                status: .available
            ),
            Entry(
                id: "veepoo_wristband",
                displayName: "Veepoo Wristband",
                summary: "First-party FERAL wristband. HR, SpO2, body temp, ECG over BLE.",
                category: .bluetooth,
                status: .unsupported(reason: "Vendor frameworks not yet linked into this build")
            ),
            Entry(
                id: "w610_glasses",
                displayName: "W610 Open Glasses (QCSDK)",
                summary: "Open-source Meta-Ray-Ban-style glasses. Camera, audio, IMU.",
                category: .bluetooth,
                status: .unsupported(reason: "Vendor frameworks not yet linked into this build")
            ),
            Entry(
                id: "generic_ble_hr",
                displayName: "Standard BLE Heart Rate (any chest strap / monitor)",
                summary: "Auto-discover any BLE device implementing the standard Heart Rate Service (0x2A37). Polar, Wahoo, generic chest straps.",
                category: .bluetooth,
                status: .unsupported(reason: "Generic GATT adapter is post-demo (planned)")
            ),
        ]
    }

    // MARK: - Activation

    /// Activate (instantiate + attempt to attach when connected) the
    /// adapter for a given capability. The actual `attach(to:)` is
    /// wired by `ConnectionStore.connect()`.
    public func activate(_ capability: String) {
        guard let adapter = makeAdapter(for: capability) else {
            updateStatus(capability, to: .unsupported(reason: "Adapter not implemented in this build"))
            return
        }
        adapterByCapability[capability] = adapter
        if !activeAdapters.contains(where: { $0.capability == capability }) {
            activeAdapters.append(adapter)
        }
        updateStatus(capability, to: .active)
    }

    public func deactivate(_ capability: String) {
        adapterByCapability.removeValue(forKey: capability)
        activeAdapters.removeAll { $0.capability == capability }
        updateStatus(capability, to: .available)
    }

    private func makeAdapter(for capability: String) -> VendorAdapter? {
        switch capability {
        case "apple_healthkit":
            return HealthKitAdapter()
        case "iphone_camera":
            return CameraPermissionAdapter()
        case "jw_health_glasses":
            // Real wired adapter — Vendor frameworks must be present
            // at Vendor/JWBle.framework. The companion app target
            // links + embeds them via project.yml.
            return JWBleAdapterWired()
        case "veepoo_wristband":
            return VeepooAdapter()
        case "w610_glasses":
            return QCSDKAdapter()
        default:
            return nil
        }
    }

    private func updateStatus(_ capability: String, to status: Entry.Status) {
        guard let idx = entries.firstIndex(where: { $0.id == capability }) else { return }
        entries[idx].status = status
    }
}
