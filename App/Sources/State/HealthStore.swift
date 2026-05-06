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
        public let source: String
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
    public func record(eventType: String, data: [String: AnyCodable], source: String) {
        let now = Date()
        switch eventType {
        case "heart_rate":
            if case .int(let bpm) = data["bpm"] ?? .null {
                heartRate = Reading(value: Double(bpm), unit: "bpm", source: source, timestamp: now)
            }
        case "spo2":
            if case .int(let pct) = data["current"] ?? .null {
                spo2 = Reading(value: Double(pct), unit: "%", source: source, timestamp: now)
            }
        case "steps":
            if case .int(let count) = data["count"] ?? .null {
                steps = Reading(value: Double(count), unit: "today", source: source, timestamp: now)
            }
        case "temperature":
            if case .double(let c) = data["celsius"] ?? .null {
                temperatureCelsius = Reading(value: c, unit: "°C", source: source, timestamp: now)
            }
        default:
            break
        }
    }
}
