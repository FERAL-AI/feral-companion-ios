import Foundation
import SwiftUI

/// Live vitals dashboard. Aggregates the most recent reading per
/// metric across every active adapter so the Health tab shows a
/// single number regardless of which device sourced it.
@MainActor
public final class HealthStore: ObservableObject {

    public struct Reading: Equatable {
        public let value: Double
        public let unit: String
        /// Capability id of the adapter that produced this reading
        /// (e.g. ``apple_healthkit``). Kept for legacy callers; the
        /// Vitals tab now renders ``pipeline`` + ``sampleSource``
        /// so the user knows whether it came from the HealthKit
        /// pipeline or a direct BLE link.
        public let source: String
        /// Human-readable pipeline name for the Vitals tab.
        /// ``"Apple Health"`` when read via HealthKit, ``"Theora
        /// glasses"`` when streamed direct from the W300 BLE link,
        /// etc. Truthfulness contract: every pipeline must map to
        /// the actual transport, not a marketing label.
        public let pipeline: String
        /// Optional HealthKit sample-source name extracted from
        /// ``HKQuantitySample.sourceRevision.source.name`` —
        /// ``"Apple Watch"``, ``"Whoop"``, etc. Empty when the
        /// pipeline is direct BLE.
        public let sampleSource: String
        public let timestamp: Date
    }

    @Published public private(set) var heartRate: Reading? = nil
    @Published public private(set) var spo2: Reading? = nil
    @Published public private(set) var steps: Reading? = nil
    @Published public private(set) var temperatureCelsius: Reading? = nil

    public init() {}

    /// Called by the `BrainClient` (or directly by an adapter in
    /// later phases) for every observed device_event so the UI can
    /// render the latest values.
    ///
    /// ``pipeline`` and ``sampleSource`` are optional for back-compat
    /// — older callers that only pass ``source`` get a derived
    /// pipeline label (``"Apple Health"`` for ``apple_healthkit``,
    /// ``"Theora glasses"`` for ``jw_health_glasses``, etc.) so the
    /// Vitals tab never shows the bare capability id.
    public func record(
        eventType: String,
        data: [String: AnyCodable],
        source: String,
        pipeline: String? = nil,
        sampleSource: String = ""
    ) {
        let now = Date()
        let resolvedPipeline = pipeline ?? Self.defaultPipelineLabel(for: source)
        let make = { (value: Double, unit: String) in
            Reading(
                value: value,
                unit: unit,
                source: source,
                pipeline: resolvedPipeline,
                sampleSource: sampleSource,
                timestamp: now
            )
        }
        switch eventType {
        case "heart_rate":
            if case .int(let bpm) = data["bpm"] ?? .null {
                heartRate = make(Double(bpm), "bpm")
            }
        case "spo2":
            if case .int(let pct) = data["current"] ?? .null {
                spo2 = make(Double(pct), "%")
            }
        case "steps":
            if case .int(let count) = data["count"] ?? .null {
                steps = make(Double(count), "today")
            }
        case "temperature":
            if case .double(let c) = data["celsius"] ?? .null {
                temperatureCelsius = make(c, "°C")
            }
        default:
            break
        }
    }

    /// Maps a capability id to a human-readable pipeline label.
    /// Centralised here so Vitals, Settings, and any future
    /// status-truthful surface render the same vocabulary.
    public static func defaultPipelineLabel(for capability: String) -> String {
        switch capability {
        case "apple_healthkit": return "Apple Health"
        case "jw_health_glasses": return "Theora glasses"
        case "veepoo_wristband": return "Veepoo wristband"
        case "w610_glasses": return "W610 open glasses"
        case "generic_ble_hr": return "BLE heart-rate sensor"
        default: return capability
        }
    }
}
