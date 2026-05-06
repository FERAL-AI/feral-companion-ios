import Foundation

/// HTTP REST client for the brain's `/api/devices/pair/*` flow.
/// All endpoints in this surface are documented in
/// `feral-core/api/routes/devices.py` and are explicitly listed in
/// `_OPEN_PATHS` (no master API key required). The phone uses these
/// to convert a paste-or-scanned pair URL into a long-lived
/// `phone_bearer` it then uses on `/v1/node`.
public final class PairingClient {

    public struct Decoded {
        public let brainURL: URL
        public let token: String
        public let brainId: String?
        public let name: String?
        public let isLegacy: Bool

        public init(brainURL: URL, token: String, brainId: String?, name: String?, isLegacy: Bool) {
            self.brainURL = brainURL
            self.token = token
            self.brainId = brainId
            self.name = name
            self.isLegacy = isLegacy
        }
    }

    public struct UnifiedV1Payload: Codable {
        public let v: Int
        public let mode: String
        public let url: String
        public let token: String
        public let brain_id: String
        public let expires: Int
        public let name: String?
    }

    public init() {}

    // MARK: - Payload decoding (mirrors the unified parser in feral-core)

    /// Accepts every supported pair payload and returns a normalised
    /// `(brainURL, token)` tuple regardless of which legacy or
    /// unified shape was supplied.
    ///
    /// Supported inputs:
    ///   1. Unified v1 JSON `{v:1, mode, url, token, brain_id, …}`
    ///   2. Legacy `{host, port, apiKey, nodeName}` (pre-2026.5.8 iOS)
    ///   3. Legacy `{host, port, token, name}` (pre-2026.5.8 brain)
    ///   4. URL form `feral://pair?p=<base64url-json>`
    ///   5. Plain `https://<brain>/pair?t=<token>` URLs
    public static func decode(_ raw: String) -> Decoded? {
        // 1. Unified v1.
        if let data = raw.data(using: .utf8),
           let unified = try? JSONDecoder().decode(UnifiedV1Payload.self, from: data),
           unified.v == 1, let url = URL(string: unified.url) {
            return Decoded(
                brainURL: url,
                token: unified.token,
                brainId: unified.brain_id.isEmpty ? nil : unified.brain_id,
                name: unified.name,
                isLegacy: false
            )
        }

        // 2 + 3. Legacy {host, port, apiKey|token, nodeName|name}.
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let host = json["host"] as? String {
            let port: Int = (json["port"] as? Int) ?? Int(json["port"] as? String ?? "") ?? 9090
            let token = (json["token"] as? String) ?? (json["apiKey"] as? String) ?? ""
            let name = (json["name"] as? String) ?? (json["nodeName"] as? String)
            if !token.isEmpty,
               let url = URL(string: "http://\(host):\(port)") {
                return Decoded(brainURL: url, token: token, brainId: nil, name: name, isLegacy: true)
            }
        }

        // 4. feral://pair?p=<base64url>
        if let url = URL(string: raw),
           url.scheme == "feral", url.host == "pair",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let pParam = comps.queryItems?.first(where: { $0.name == "p" })?.value,
           let jsonData = decodeBase64URL(pParam),
           let inner = String(data: jsonData, encoding: .utf8) {
            return decode(inner)
        }

        // 5. https://<brain>/pair?t=<token>
        if let url = URL(string: raw),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let token = comps.queryItems?.first(where: { $0.name == "t" })?.value,
           !token.isEmpty,
           let scheme = url.scheme, (scheme == "https" || scheme == "http"),
           let host = url.host {
            var base = URLComponents()
            base.scheme = scheme
            base.host = host
            base.port = url.port
            if let baseURL = base.url {
                return Decoded(brainURL: baseURL, token: token, brainId: nil, name: nil, isLegacy: false)
            }
        }

        return nil
    }

    private static func decodeBase64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - t.count % 4) % 4
        t += String(repeating: "=", count: pad)
        return Data(base64Encoded: t)
    }

    // MARK: - REST helpers

    public struct PairCheckResponse: Decodable {
        public let pin_required: Bool
        public let pin_length: Int?
    }

    public struct PairCompleteResponse: Decodable {
        public let ok: Bool?
        public let phone_bearer: String?
        public let device_id: String?
    }

    /// `GET /api/devices/pair/check?t=<token>` — discover whether a
    /// PIN is required.
    public func checkPair(brainURL: URL, token: String) async throws -> PairCheckResponse {
        var comps = URLComponents(url: brainURL.appendingPathComponent("api/devices/pair/check"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "t", value: token)]
        guard let url = comps.url else { throw BrainClientError.invalidBrainURL(brainURL.absoluteString) }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(PairCheckResponse.self, from: data)
    }

    /// `POST /api/devices/pair/verify_pin` — present the PIN.
    public func verifyPin(brainURL: URL, token: String, pin: String) async throws {
        let url = brainURL.appendingPathComponent("api/devices/pair/verify_pin")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "pin": pin])
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BrainClientError.invalidBrainURL("PIN verify failed: \(http.statusCode)")
        }
    }

    /// `POST /api/devices/pair/complete` with `kind: "browser_node_v2"`
    /// to receive a `phone_bearer` we can use long-term on `/v1/node`.
    public func completePair(brainURL: URL, token: String) async throws -> PairCompleteResponse {
        let url = brainURL.appendingPathComponent("api/devices/pair/complete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "kind": "browser_node_v2",
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(PairCompleteResponse.self, from: data)
    }

    /// Convert an HTTP brain URL into the WebSocket URL for `/v1/node`.
    public static func websocketURL(from brainURL: URL) -> URL? {
        var comps = URLComponents(url: brainURL, resolvingAgainstBaseURL: false)
        let scheme = (comps?.scheme == "https") ? "wss" : "ws"
        comps?.scheme = scheme
        comps?.path = "/v1/node"
        return comps?.url
    }
}
