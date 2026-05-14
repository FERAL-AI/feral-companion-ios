import SwiftUI

/// Live vitals dashboard. Pulls from `HealthStore`. Cards stay
/// vendor-agnostic: each shows the metric value + the source name
/// so you know whether it came from Apple Watch, W300 glasses, etc.
struct HealthView: View {
    @EnvironmentObject var env: AppEnvironment

    /// Drives the staleness label re-render every second so "5s ago"
    /// becomes "6s ago" without waiting for a new reading. The Vitals
    /// tab is a foreground-only screen so a 1Hz timer is acceptable.
    @State private var stalenessTick: Date = Date()
    private let stalenessTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let cols = [GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, spacing: 16) {
                    MetricCard(
                        title: "Heart Rate",
                        reading: env.health.heartRate,
                        formatter: { "\(Int($0))" },
                        defaultUnit: "bpm",
                        accent: .red,
                        icon: "heart.fill",
                        now: stalenessTick
                    )
                    MetricCard(
                        title: "SpO2",
                        reading: env.health.spo2,
                        formatter: { "\(Int($0))" },
                        defaultUnit: "%",
                        accent: .blue,
                        icon: "lungs.fill",
                        now: stalenessTick
                    )
                    MetricCard(
                        title: "Steps",
                        reading: env.health.steps,
                        formatter: { "\(Int($0))" },
                        defaultUnit: "today",
                        accent: .green,
                        icon: "figure.walk",
                        now: stalenessTick
                    )
                    MetricCard(
                        title: "Temperature",
                        reading: env.health.temperatureCelsius,
                        formatter: { String(format: "%.1f", $0) },
                        defaultUnit: "°C",
                        accent: .orange,
                        icon: "thermometer.medium",
                        now: stalenessTick
                    )
                }
                .padding(.horizontal)

                if !hasAnyReading {
                    NoVitalsHint()
                }
            }
            .padding(.vertical, 16)
        }
        .background(FeralTheme.bgDeep.ignoresSafeArea())
        .onReceive(stalenessTimer) { now in stalenessTick = now }
    }

    private var hasAnyReading: Bool {
        env.health.heartRate != nil
        || env.health.spo2 != nil
        || env.health.steps != nil
        || env.health.temperatureCelsius != nil
    }
}

private struct MetricCard: View {
    let title: String
    let reading: HealthStore.Reading?
    let formatter: (Double) -> String
    let defaultUnit: String
    let accent: Color
    let icon: String
    /// Re-rendered every second by the parent so "5s ago" → "6s ago"
    /// without needing a new reading.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(accent)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let stale = stalenessBadge {
                    Text(stale.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(stale.tint.opacity(0.18), in: Capsule())
                        .foregroundStyle(stale.tint)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.map { formatter($0.value) } ?? "—")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .opacity(stalenessBadge?.dimValue == true ? 0.55 : 1.0)
                Text(reading?.unit ?? defaultUnit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Phase-1 truthfulness: render the pipeline qualifier
            // (e.g. "Apple Health") + the actual sample-source name
            // (e.g. "Apple Watch") so the user knows whether this
            // number came through HealthKit or a direct BLE link.
            // The bare capability id ("apple_healthkit") was the
            // misleading label the Phase-1 audit flagged.
            Text(sourceLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // Audit-r8 brief #05: third line carries the staleness
            // detail. Operator caught the previous build showing a
            // constant "Heart Rate: 115" on a phone with no glasses
            // connected — the value was a real Apple Watch reading
            // from hours earlier, but nothing in the UI told the user
            // it was old. The Brain already gates stale values out of
            // chat / proactive alerts (perception/fusion.py
            // `to_system_context`); the Vitals tab now matches.
            if let detail = stalenessDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FeralTheme.padMD)
        .feralGlass(.thin, radius: .md)
        .overlay(
            RoundedRectangle(cornerRadius: FeralTheme.radiusMD, style: .continuous)
                .stroke(accent.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var sourceLabel: String {
        guard let r = reading else { return "no source paired" }
        if !r.sampleSource.isEmpty {
            return "\(r.pipeline) · \(r.sampleSource)"
        }
        return r.pipeline
    }

    private struct Badge {
        let label: String
        let tint: Color
        let dimValue: Bool
    }

    /// Mirrors the brain's freshness windows: live ≤ 60s, recent ≤ 5min,
    /// stale > 5min, "unknown" when the brain didn't tell us. Matches
    /// `_FRESH_WINDOW_S = 120s` in `agents/proactive_engine.py` for the
    /// "stale" cutoff so Vitals and proactive alerts agree.
    private var stalenessBadge: Badge? {
        guard let r = reading else { return nil }
        guard let at = r.sampleAt else {
            return Badge(label: "unknown", tint: .gray, dimValue: true)
        }
        let age = now.timeIntervalSince(at)
        if age < 0 {
            return Badge(label: "live", tint: .green, dimValue: false)
        }
        if age <= 60 { return Badge(label: "live", tint: .green, dimValue: false) }
        if age <= 120 { return Badge(label: "recent", tint: .yellow, dimValue: false) }
        return Badge(label: "stale", tint: .orange, dimValue: true)
    }

    private var stalenessDetail: String? {
        guard let r = reading else { return nil }
        guard let at = r.sampleAt else {
            return "Sample time not provided by source"
        }
        return "Sampled \(RelativeStalenessFormatter.shared.string(from: at, to: now))"
    }
}

/// Compact "5s ago" / "3 min ago" / "2h ago" / "Mar 4, 14:02" formatter
/// scaled to the Vitals card. Cached as a singleton because
/// `RelativeDateTimeFormatter` is pricey to construct.
enum RelativeStalenessFormatter {
    static let shared = Formatter()

    final class Formatter {
        private let absolute: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d, HH:mm"
            return f
        }()

        func string(from past: Date, to now: Date) -> String {
            let age = max(0, now.timeIntervalSince(past))
            if age < 1 { return "just now" }
            if age < 60 { return "\(Int(age))s ago" }
            if age < 3600 {
                let m = Int(age / 60)
                return "\(m) min ago"
            }
            if age < 86_400 {
                let h = Int(age / 3600)
                let mm = Int((age.truncatingRemainder(dividingBy: 3600)) / 60)
                if mm == 0 { return "\(h)h ago" }
                return "\(h)h \(mm)m ago"
            }
            return absolute.string(from: past)
        }
    }
}

private struct NoVitalsHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No vitals yet").font(.headline)
            Text("Connect Apple Health from the Devices tab to start streaming HR, SpO2, steps, and sleep.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
