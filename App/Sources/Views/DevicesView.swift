import SwiftUI

/// "Devices" tab — the platform play. Lists every adapter the app
/// knows about, grouped by integration class (iPhone built-ins,
/// BLE devices, HealthKit-mediated). Tapping toggles activation.
struct DevicesView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        List {
            ForEach(DeviceStore.Entry.Category.allCases, id: \.rawValue) { category in
                let entries = env.devices.entries.filter { $0.category == category }
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            DeviceRow(entry: entry)
                        }
                    } header: {
                        HStack {
                            Image(systemName: category.icon)
                            Text(category.rawValue.uppercased())
                                .font(.caption.bold())
                                .tracking(1)
                        }
                    } footer: {
                        Text(footerFor(category))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
    }

    private func footerFor(_ category: DeviceStore.Entry.Category) -> String {
        switch category {
        case .iphoneBuiltin:
            return "Always available. No external hardware required."
        case .bluetooth:
            return "Direct BLE pairing. Each vendor needs its iOS framework dropped into this app build."
        case .healthKitMediated:
            return "Universal path. Anything that syncs to Apple Health (Apple Watch, Whoop, Garmin, Fitbit, Oura, Polar, etc.) works through this single integration."
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var env: AppEnvironment
    let entry: DeviceStore.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName).font(.body.weight(.semibold))
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                statusLabel
            }
            Spacer()
            actionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch entry.status {
        case .available:
            Text("Ready to connect").font(.caption2).foregroundStyle(.tertiary)
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(2)
        case .unsupported(let reason):
            Label(reason, systemImage: "wrench.and.screwdriver")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch entry.status {
        case .available:
            Button("Connect") { env.devices.activate(entry.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .active:
            Button("Disconnect", role: .destructive) { env.devices.deactivate(entry.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .failed:
            Button("Retry") { env.devices.activate(entry.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .unsupported:
            Text("Soon").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
