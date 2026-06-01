import Foundation
import SwiftUI

// Phase 10 (audit-r10 overhaul) — visibility into what the brain
// can talk to right now.
//
// Operator complaint:
//   "the app doesn't show connected devices/HUPs to the brain or how
//    to communicate with them via chat"
//
// The brain's Phase 5 capability registry tracks every connected
// node's structured skill manifest. This store polls
// `GET /api/capabilities` every few seconds while the Devices view
// is on-screen so the user sees real-time which nodes are alive on
// the brain side (their own iPhone, glasses, wristband, plus any
// other surface they've paired) and which `phone.*` / `glasses.*`
// actions are routable right now.

/// Per-node snapshot the Brain Network UI renders. Matches the
/// shape returned by the brain's `GET /api/capabilities` endpoint
/// (the `nodes[]` array entries) — see
/// `feral-core/memory/capability_registry.py:CapabilityRegistry.snapshot_nodes`.
public struct BrainConnectedNode: Identifiable, Equatable {
    public let id: String  // node_id
    public let nodeType: String
    public let platform: String
    public let surface: String
    public let skillCount: Int
    public let actionNames: [String]
}

@MainActor
public final class BrainCapabilitiesStore: ObservableObject {

    @Published public private(set) var connectedNodes: [BrainConnectedNode] = []
    @Published public private(set) var brainHostSkillCount: Int = 0
    @Published public private(set) var lastRefreshError: String? = nil
    @Published public private(set) var lastRefreshAt: Date? = nil

    private weak var brainClient: BrainClient?
    private var pollTask: Task<Void, Never>?

    public init() {}

    public func bind(to client: BrainClient) {
        brainClient = client
    }

    /// Start polling. Idempotent — repeated calls cancel the prior
    /// task before spinning a new one. ChatView / DevicesView call
    /// this from `onAppear` and pair it with `stop()` in `onDisappear`
    /// so the app doesn't keep hammering the brain while the user
    /// is on an unrelated tab.
    public func start(intervalSeconds: Double = 5) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        guard let httpBase = brainClient?.brainHTTPBase else {
            connectedNodes = []
            brainHostSkillCount = 0
            lastRefreshError = "Not connected to a brain."
            return
        }
        guard let url = URL(string: "/api/capabilities", relativeTo: httpBase) else {
            lastRefreshError = "Could not build /api/capabilities URL"
            return
        }
        do {
            // /api/capabilities is on the brain's phone-bearer GET allowlist —
            // an unauthenticated LAN fetch is rejected with 401. Attach the
            // paired phone bearer.
            let req = BrainHTTP.authorized(url, bearer: brainClient?.phoneBearer, method: .get)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastRefreshError = "Brain returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastRefreshError = "Brain response wasn't JSON"
                return
            }

            let brainHost = (json["brain_host"] as? [Any]) ?? []
            let nodesRaw = (json["nodes"] as? [[String: Any]]) ?? []

            let parsed: [BrainConnectedNode] = nodesRaw.compactMap { dict in
                guard let nodeId = dict["node_id"] as? String else { return nil }
                let nodeType = (dict["node_type"] as? String) ?? "unknown"
                let platform = (dict["platform"] as? String) ?? ""
                let surface = (dict["surface"] as? String) ?? ""
                let skills = (dict["skills"] as? [[String: Any]]) ?? []
                var actions: [String] = []
                for skill in skills {
                    if let acts = skill["actions"] as? [[String: Any]] {
                        for a in acts {
                            if let name = a["name"] as? String { actions.append(name) }
                        }
                    }
                }
                return BrainConnectedNode(
                    id: nodeId,
                    nodeType: nodeType,
                    platform: platform,
                    surface: surface,
                    skillCount: skills.count,
                    actionNames: actions
                )
            }

            connectedNodes = parsed
            brainHostSkillCount = brainHost.count
            lastRefreshAt = Date()
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }
}
