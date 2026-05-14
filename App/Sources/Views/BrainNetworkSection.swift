import SwiftUI

// Phase 10 (audit-r10 overhaul) — visibility into what's connected
// to the brain. Closes the operator complaint that the iOS app shows
// only phone-local devices and gives no clue what the BRAIN can see.
//
// Renders inside `DevicesView` as a top section. Each row is one
// node the brain has in its capability registry right now, with the
// per-node action count + surface (phone_actuator / glasses_actuator
// / brain_host) so the user can answer "if I ask FERAL to call
// John, will it actually have a phone to dial through?" at a glance.

struct BrainNetworkSection: View {
    @StateObject private var store = BrainCapabilitiesStore()
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        Section {
            if store.connectedNodes.isEmpty {
                BrainNetworkEmptyRow(
                    lastError: store.lastRefreshError,
                    brainHostSkillCount: store.brainHostSkillCount
                )
            } else {
                ForEach(store.connectedNodes) { node in
                    BrainNodeRow(node: node)
                }
                BrainHostFooterRow(
                    brainHostSkillCount: store.brainHostSkillCount,
                    lastRefreshAt: store.lastRefreshAt
                )
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text("BRAIN NETWORK")
                    .font(.caption.bold())
                    .tracking(1)
                Spacer()
                if store.lastRefreshAt != nil {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        } footer: {
            Text(
                "Live view of what the brain has connected right now. "
                + "Updates every 5s while this tab is open. Each row "
                + "is a node the brain can route HUP actions to "
                + "(your iPhone, glasses, wristbands, plus any other "
                + "surface paired with the brain)."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .onAppear {
            store.bind(to: env.brain)
            store.start()
        }
        .onDisappear {
            store.stop()
        }
    }
}

private struct BrainNodeRow: View {
    let node: BrainConnectedNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: node.nodeType))
                    .foregroundStyle(.green)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.id)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(node.nodeType.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if !node.platform.isEmpty {
                            Text("· \(node.platform)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        if !node.surface.isEmpty {
                            Text("· \(node.surface)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Text("\(node.skillCount) skill\(node.skillCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !node.actionNames.isEmpty {
                Text(node.actionNames.prefix(4).joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for kind: String) -> String {
        switch kind.lowercased() {
        case "phone": return "iphone"
        case "tablet": return "ipad"
        case "glasses": return "eyeglasses"
        case "wearable": return "applewatch"
        case "desktop", "server": return "desktopcomputer"
        case "camera", "browser_camera": return "camera"
        case "actuator", "robot": return "gearshape.2"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
}

private struct BrainNetworkEmptyRow: View {
    let lastError: String?
    let brainHostSkillCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No nodes connected to the brain")
                    .font(.body.weight(.medium))
                if let lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if brainHostSkillCount > 0 {
                    Text("Brain-host has \(brainHostSkillCount) skill\(brainHostSkillCount == 1 ? "" : "s") available.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Pair a device or open the FERAL companion on another surface.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct BrainHostFooterRow: View {
    let brainHostSkillCount: Int
    let lastRefreshAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "macpro.gen3")
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Brain host")
                    .font(.body.weight(.semibold))
                Text("\(brainHostSkillCount) brain-host skill\(brainHostSkillCount == 1 ? "" : "s") available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let when = lastRefreshAt {
                Text(when, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
