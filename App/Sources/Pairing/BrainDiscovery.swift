import Foundation
import Network

/// Discovered brain instance on the LAN.
struct DiscoveredBrain: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int

    var httpURL: URL? {
        URL(string: "http://\(host):\(port)")
    }
}

/// Scans the local network for FERAL brains advertising `_feral._tcp`
/// via Bonjour/mDNS. Publishes discovered brains for the onboarding
/// wizard's brain-discover step.
@MainActor
final class BrainDiscovery: ObservableObject {
    @Published private(set) var discovered: [DiscoveredBrain] = []
    @Published private(set) var isScanning: Bool = false

    private var browser: NWBrowser?

    func startScan() {
        guard !isScanning else { return }
        discovered = []
        isScanning = true

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_feral._tcp", domain: nil)
        let b = NWBrowser(for: descriptor, using: params)

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .failed:
                    self?.isScanning = false
                case .cancelled:
                    self?.isScanning = false
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results)
            }
        }

        b.start(queue: .main)
        self.browser = b
    }

    func stopScan() {
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var brains: [DiscoveredBrain] = []
        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                let brain = DiscoveredBrain(
                    id: "\(name).\(type).\(domain ?? "")",
                    name: name,
                    host: name,
                    port: 9090
                )
                brains.append(brain)
            }
        }
        discovered = brains
    }

    /// Resolve a discovered brain's host + port via an NWConnection
    /// endpoint resolution. Falls back to the name if resolution fails.
    func resolve(_ brain: DiscoveredBrain, completion: @escaping (String, Int) -> Void) {
        let endpoint: NWEndpoint
        if case let name = brain.name {
            endpoint = .service(name: name, type: "_feral._tcp", domain: "local.", interface: nil)
        }

        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {
                    let hostStr: String
                    switch host {
                    case .ipv4(let addr):
                        hostStr = "\(addr)"
                    case .ipv6(let addr):
                        hostStr = "\(addr)"
                    case .name(let n, _):
                        hostStr = n
                    @unknown default:
                        hostStr = brain.host
                    }
                    DispatchQueue.main.async {
                        completion(hostStr, Int(port.rawValue))
                    }
                }
                connection.cancel()
            } else if case .failed = state {
                DispatchQueue.main.async {
                    completion(brain.host, brain.port)
                }
                connection.cancel()
            }
        }
        connection.start(queue: .global())
    }
}
