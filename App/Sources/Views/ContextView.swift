import SwiftUI

/// "Context" tab — shows what the brain currently knows.
///
/// Replaces the old Vitals tab (raw metric cards). Instead of exposing
/// individual sensor values, this renders the brain's live perception
/// context: what it sees, hears, and infers. The operator can verify
/// at a glance whether the brain is stale, what data sources are live,
/// and what the LLM system prompt actually contains.
struct ContextView: View {
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var contextStore = BrainContextStore()

    var body: some View {
        ScrollView {
            VStack(spacing: FeralTheme.padLG) {
                if !env.brain.state.isConnected {
                    disconnectedState
                } else if contextStore.perceptionText.isEmpty && contextStore.lastError != nil {
                    errorState
                } else {
                    perceptionSection
                    if contextStore.sensors != .empty {
                        sensorsSection
                    }
                    if contextStore.vision.active {
                        visionSection
                    }
                    if contextStore.somatic != .empty {
                        somaticSection
                    }
                    if !contextStore.hardwareContext.isEmpty {
                        hardwareSection
                    }
                }
            }
            .padding(FeralTheme.padLG)
        }
        .background(FeralTheme.bgDeep.ignoresSafeArea())
        .onAppear {
            contextStore.bind(to: env.brain)
            contextStore.start()
        }
        .onDisappear { contextStore.stop() }
    }

    // MARK: - Sections

    private var perceptionSection: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            sectionHeader(title: "Brain Context", icon: "brain", color: FeralTheme.accent)
            Text(contextStore.perceptionText.isEmpty ? "No sensor data available." : contextStore.perceptionText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(contextStore.perceptionText.isEmpty ? FeralTheme.textTertiary : FeralTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let at = contextStore.lastRefreshAt {
                Text("Updated \(at, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(FeralTheme.textTertiary)
            }
        }
        .feralCard(.thin, radius: .md)
    }

    private var sensorsSection: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            sectionHeader(title: "Sensors", icon: "waveform.path.ecg", color: FeralTheme.stateError)
            let s = contextStore.sensors
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let hr = s.heartRate {
                    sensorPill(
                        label: "HR",
                        value: "\(hr) bpm",
                        fresh: s.heartRateFresh,
                        source: s.heartRateSource
                    )
                }
                if let spo2 = s.spo2 {
                    sensorPill(
                        label: "SpO2",
                        value: "\(spo2)%",
                        fresh: s.spo2Fresh,
                        source: nil
                    )
                }
                if let temp = s.temperatureC {
                    sensorPill(
                        label: "Temp",
                        value: String(format: "%.1f°C", temp),
                        fresh: true,
                        source: nil
                    )
                }
                if let activity = s.activityState {
                    sensorPill(
                        label: "Activity",
                        value: activity.capitalized,
                        fresh: true,
                        source: nil
                    )
                }
            }
        }
        .feralCard(.thin, radius: .md)
    }

    private var visionSection: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            sectionHeader(title: "Vision", icon: "eye", color: FeralTheme.stateLive)
            if let scene = contextStore.vision.sceneDescription {
                Text(scene)
                    .font(.callout)
                    .foregroundStyle(FeralTheme.textPrimary)
            }
            if !contextStore.vision.objects.isEmpty {
                FlowText(label: "Objects", items: contextStore.vision.objects)
            }
            if !contextStore.vision.text.isEmpty {
                FlowText(label: "Text visible", items: contextStore.vision.text)
            }
        }
        .feralCard(.thin, radius: .md)
    }

    private var somaticSection: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            sectionHeader(title: "Somatic", icon: "figure.mind.and.body", color: FeralTheme.stateWarn)
            let sm = contextStore.somatic
            HStack(spacing: FeralTheme.padLG) {
                if let cl = sm.cognitiveLoad {
                    miniGauge(label: "Cognitive", value: cl)
                }
                if let al = sm.activityLevel {
                    miniGauge(label: "Activity", value: al)
                }
                if let phase = sm.circadianPhase {
                    VStack(spacing: 2) {
                        Text(phase.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FeralTheme.textPrimary)
                        Text("Circadian")
                            .font(.caption2)
                            .foregroundStyle(FeralTheme.textTertiary)
                    }
                }
            }
        }
        .feralCard(.thin, radius: .md)
    }

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            sectionHeader(title: "Hardware", icon: "cpu", color: FeralTheme.textSecondary)
            Text(contextStore.hardwareContext)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(FeralTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .feralCard(.thin, radius: .md)
    }

    private var disconnectedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(FeralTheme.textTertiary)
            Text("No brain connected")
                .font(.headline)
                .foregroundStyle(FeralTheme.textPrimary)
            Text("Connect to a FERAL brain to see its live context — what it sees, hears, and knows about you right now.")
                .font(.callout)
                .foregroundStyle(FeralTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var errorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(FeralTheme.stateWarn)
            Text("Context unavailable")
                .font(.headline)
                .foregroundStyle(FeralTheme.textPrimary)
            if let err = contextStore.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(FeralTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.subheadline)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FeralTheme.textPrimary)
            Spacer()
        }
    }

    private func sensorPill(label: String, value: String, fresh: Bool, source: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(fresh ? FeralTheme.stateLive : FeralTheme.stateWarn)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(FeralTheme.textTertiary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(fresh ? FeralTheme.textPrimary : FeralTheme.textSecondary)
            if let src = source {
                Text(src)
                    .font(.caption2)
                    .foregroundStyle(FeralTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FeralTheme.padSM)
        .background(FeralTheme.surface0, in: RoundedRectangle(cornerRadius: FeralTheme.radiusSM, style: .continuous))
    }

    private func miniGauge(label: String, value: Double) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(FeralTheme.surface2, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(FeralTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value * 100))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FeralTheme.textPrimary)
            }
            .frame(width: 36, height: 36)
            Text(label)
                .font(.caption2)
                .foregroundStyle(FeralTheme.textTertiary)
        }
    }
}

private struct FlowText: View {
    let label: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(FeralTheme.textTertiary)
            Text(items.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(FeralTheme.textSecondary)
        }
    }
}
