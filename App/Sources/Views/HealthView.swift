import SwiftUI

/// Live vitals dashboard. Pulls from `HealthStore`. Cards stay
/// vendor-agnostic: each shows the metric value + the source name
/// so you know whether it came from Apple Watch, W300 glasses, etc.
struct HealthView: View {
    @EnvironmentObject var env: AppEnvironment

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
                        icon: "heart.fill"
                    )
                    MetricCard(
                        title: "SpO2",
                        reading: env.health.spo2,
                        formatter: { "\(Int($0))" },
                        defaultUnit: "%",
                        accent: .blue,
                        icon: "lungs.fill"
                    )
                    MetricCard(
                        title: "Steps",
                        reading: env.health.steps,
                        formatter: { "\(Int($0))" },
                        defaultUnit: "today",
                        accent: .green,
                        icon: "figure.walk"
                    )
                    MetricCard(
                        title: "Temperature",
                        reading: env.health.temperatureCelsius,
                        formatter: { String(format: "%.1f", $0) },
                        defaultUnit: "°C",
                        accent: .orange,
                        icon: "thermometer.medium"
                    )
                }
                .padding(.horizontal)

                if !hasAnyReading {
                    NoVitalsHint()
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color.black.ignoresSafeArea())
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(accent)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.map { formatter($0.value) } ?? "—")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.15), lineWidth: 1)
        )
    }

    private var sourceLabel: String {
        guard let r = reading else { return "no source paired" }
        if !r.sampleSource.isEmpty {
            return "\(r.pipeline) · \(r.sampleSource)"
        }
        return r.pipeline
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
