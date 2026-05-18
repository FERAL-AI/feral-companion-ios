import Foundation

/// Centralises the pair logic so the onboarding wizard step and the
/// Settings "Re-pair" button share one code path.
///
/// Accepts a brain URL (discovered, QR-scanned, or manually entered),
/// runs the pair-check → verify-PIN → complete handshake, stores the
/// bearer in ConnectionStore, and connects.
@MainActor
final class BrainPairFlow: ObservableObject {
    @Published var isPairing = false
    @Published var error: String?
    @Published var succeeded = false

    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Pair using a discovered brain's HTTP URL. Builds a pair URL
    /// from the discovery endpoint and applies it through the existing
    /// ConnectionStore path.
    func pairWithDiscovered(host: String, port: Int) async {
        guard let brainURL = URL(string: "http://\(host):\(port)") else {
            error = "Invalid brain address: \(host):\(port)"
            return
        }
        await pairWithURL(brainURL)
    }

    /// Pair from a raw string (QR payload, pasted link, etc.)
    func pairFromRaw(_ raw: String, pin: String? = nil) async {
        guard let decoded = PairingClient.decode(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Could not parse this pair link."
            return
        }
        isPairing = true
        error = nil
        defer { isPairing = false }

        await env.connection.applyPairing(decoded, pin: pin)
        await finishPairing()
    }

    /// Pair using a known brain URL (from mDNS discovery or manual entry).
    /// Hits `POST /api/devices/pair` with `kind: browser_node_v2` to get
    /// a fresh pair token, then runs the standard apply-pairing flow.
    func pairWithURL(_ brainURL: URL) async {
        isPairing = true
        error = nil
        defer { isPairing = false }

        let pairEndpoint = brainURL.appendingPathComponent("api/devices/pair")
        do {
            var request = URLRequest(url: pairEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "kind": "browser_node_v2",
                "name": "FERAL iPhone",
            ])
            request.timeoutInterval = 10

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                // iOS reports Local Network denials as URLError(-1009)
                // "Internet connection appears to be offline" even when
                // the LAN is healthy. Map to a precise error before the
                // string reaches the user.
                throw PairingClient.mapLocalNetworkError(error, brainURL: brainURL)
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.error = "Brain returned HTTP \(code). Use QR or paste-link pairing instead."
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String else {
                self.error = "Brain didn't return a pair token. Use QR or paste-link pairing instead."
                return
            }

            let decoded = PairingClient.Decoded(
                brainURL: brainURL,
                token: token,
                brainId: json["brain_id"] as? String,
                name: json["name"] as? String,
                isLegacy: false
            )
            await env.connection.applyPairing(decoded)
            await finishPairing()
        } catch let brain as BrainClientError {
            self.error = brain.errorDescription ?? "\(brain)"
        } catch {
            self.error = "Connection failed: \(error.localizedDescription)"
        }
    }

    private func finishPairing() async {
        switch env.connection.status {
        case .paired:
            await env.connection.connect()
            // Brief wait for node_ack
            for _ in 0..<10 {
                if env.brain.state.isConnected {
                    succeeded = true
                    return
                }
                if case .error(let m) = env.connection.status {
                    error = m
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            // Even without a confirmed connection, pair stored OK
            succeeded = true
        case .error(let m):
            error = m
        case .connected:
            succeeded = true
        default:
            error = "Unexpected pairing state: \(env.connection.status)"
        }
    }
}
