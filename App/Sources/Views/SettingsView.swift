import SwiftUI

/// Settings — connection management, diagnostics, about.
///
/// Phase 7b-3 rebuild: glass-panel sections with the FERAL design
/// language instead of the stock Form. Sections are: Brain (status +
/// actions), Diagnostics, and About.
struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var showPairingSheet: Bool
    @State private var showLog = false
    @State private var probing = false
    @State private var lastProbeResult: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: FeralTheme.padLG) {
                brainCard
                actionsCard
                if env.connection.brainURL != nil {
                    diagnosticsCard
                }
                debugCard
                aboutCard
            }
            .padding(FeralTheme.padLG)
        }
        .background(FeralTheme.bgDeep.ignoresSafeArea())
        .sheet(isPresented: $showLog) {
            DebugLogView()
        }
    }

    // MARK: - Brain Card

    private var brainCard: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padMD) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(FeralTheme.accent)
                    .font(.title3)
                Text("Brain")
                    .font(.headline)
                    .foregroundStyle(FeralTheme.textPrimary)
                Spacer()
                statusPill
            }

            if let url = env.connection.brainURL {
                VStack(alignment: .leading, spacing: 6) {
                    labeledRow("URL", value: url.absoluteString)
                    labeledRow("Node ID", value: env.connection.nodeId)
                }
            } else {
                Text("Not paired with a FERAL brain.")
                    .font(.callout)
                    .foregroundStyle(FeralTheme.textTertiary)
            }
        }
        .feralCard(.regular, radius: .md)
    }

    // MARK: - Actions Card

    private var actionsCard: some View {
        VStack(spacing: FeralTheme.padSM) {
            if env.connection.brainURL == nil {
                actionButton(
                    title: "Pair with a brain",
                    icon: "qrcode.viewfinder",
                    style: .accent
                ) {
                    showPairingSheet = true
                }
            } else {
                if env.brain.state.isConnected {
                    actionButton(
                        title: "Disconnect",
                        icon: "wifi.slash",
                        style: .secondary
                    ) {
                        Task { await env.connection.disconnect() }
                    }
                } else {
                    actionButton(
                        title: "Connect",
                        icon: "wifi",
                        style: .accent
                    ) {
                        Task { await env.connection.connect() }
                    }
                }
                actionButton(
                    title: "Unpair brain",
                    icon: "xmark.circle",
                    style: .destructive
                ) {
                    Task { await env.connection.unpair() }
                }
            }
        }
        .feralCard(.thin, radius: .md)
    }

    // MARK: - Diagnostics Card

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(FeralTheme.textSecondary)
                Text("Diagnostics")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FeralTheme.textPrimary)
            }

            Button {
                Task {
                    probing = true
                    let ok = await env.connection.testBrainReachability(url: env.connection.brainURL!)
                    lastProbeResult = ok ? "Brain reachable" : "Brain unreachable"
                    probing = false
                }
            } label: {
                HStack(spacing: 8) {
                    if probing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(FeralTheme.textSecondary)
                    }
                    Text(probing ? "Probing…" : "Test brain reachability")
                        .font(.callout)
                        .foregroundStyle(FeralTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(FeralTheme.textTertiary)
                }
                .padding(FeralTheme.padSM)
                .background(FeralTheme.surface0, in: RoundedRectangle(cornerRadius: FeralTheme.radiusSM, style: .continuous))
            }
            .buttonStyle(.plain)

            if let result = lastProbeResult {
                HStack(spacing: 6) {
                    Image(systemName: result.contains("reachable") && !result.contains("un") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.contains("reachable") && !result.contains("un") ? FeralTheme.stateLive : FeralTheme.stateError)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("reachable") && !result.contains("un") ? FeralTheme.stateLive : FeralTheme.stateError)
                }
            }
        }
        .feralCard(.thin, radius: .md)
    }

    // MARK: - Debug Card

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(FeralTheme.textSecondary)
                Text("Debug Log")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FeralTheme.textPrimary)
            }
            Text("Pair attempts, brain probes, adapter activations, and errors.")
                .font(.caption)
                .foregroundStyle(FeralTheme.textTertiary)
            Button {
                showLog = true
            } label: {
                HStack {
                    Text("Open log viewer")
                        .font(.callout)
                        .foregroundStyle(FeralTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(FeralTheme.textTertiary)
                }
                .padding(FeralTheme.padSM)
                .background(FeralTheme.surface0, in: RoundedRectangle(cornerRadius: FeralTheme.radiusSM, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .feralCard(.thin, radius: .md)
    }

    // MARK: - About Card

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(FeralTheme.textSecondary)
                Text("About")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FeralTheme.textPrimary)
            }
            labeledRow("Companion", value: "0.5.0 (Phase 7b)")
            labeledRow("HUP", value: FeralNodeSDKInfo.hupVersion)
            labeledRow("Bundle", value: Bundle.main.bundleIdentifier ?? "?")
        }
        .feralCard(.thin, radius: .md)
    }

    // MARK: - Components

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.12), in: Capsule())
    }

    private func labeledRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(FeralTheme.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(FeralTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private enum ActionStyle { case accent, secondary, destructive }

    private func actionButton(title: String, icon: String, style: ActionStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body)
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .foregroundStyle(actionForeground(style))
            .padding(.horizontal, FeralTheme.padMD)
            .padding(.vertical, FeralTheme.padSM + 2)
            .background(actionBackground(style), in: RoundedRectangle(cornerRadius: FeralTheme.radiusSM, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func actionForeground(_ style: ActionStyle) -> Color {
        switch style {
        case .accent: return FeralTheme.accent
        case .secondary: return FeralTheme.textSecondary
        case .destructive: return FeralTheme.stateError
        }
    }

    private func actionBackground(_ style: ActionStyle) -> Color {
        switch style {
        case .accent: return FeralTheme.accentSoft
        case .secondary: return FeralTheme.surface0
        case .destructive: return FeralTheme.stateErrorSoft
        }
    }

    private var statusText: String {
        switch env.connection.status {
        case .unpaired: return "unpaired"
        case .pairing(let m): return "pairing — \(m)"
        case .paired: return "offline"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .error(let m): return "error — \(m)"
        }
    }

    private var statusColor: Color {
        switch env.connection.status {
        case .connected: return FeralTheme.stateLive
        case .error: return FeralTheme.stateError
        case .connecting, .reconnecting, .pairing: return FeralTheme.stateWarn
        case .paired: return .orange
        case .unpaired: return FeralTheme.textTertiary
        }
    }
}
