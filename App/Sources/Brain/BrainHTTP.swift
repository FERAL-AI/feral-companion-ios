import Foundation

/// Centralised HTTP helper for all brain REST calls.
///
/// Two responsibilities:
///
/// 1. Build pre-authed ``URLRequest``s for the brain's bearer-gated
///    REST surface (the brain's ``_PHONE_BEARER_GET_PATHS`` +
///    ``_PHONE_BEARER_POST_PATHS`` in ``api/server.py`` reject
///    unauthenticated GETs to ``/api/context/live``, ``/api/capabilities``,
///    ``/api/memory/search`` etc.).
/// 2. Provide ergonomic verbs that mirror the brain's tool surface
///    (Lane 11 — ``ingest`` + ``searchMemory``) so view code doesn't
///    hand-roll the JSON shapes.
///
/// The helper is deliberately stateless: ``bearer`` is passed in
/// explicitly so tests can drive the auth path with a stubbed value
/// and so ``ConnectionStore`` remains the single source of truth for
/// credential storage.
public enum BrainHTTP {

    public enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    /// Build a pre-populated ``URLRequest`` for a brain REST endpoint
    /// with the user's ``phone_bearer`` attached as a bearer token.
    ///
    /// Empty / nil bearer renders the request anonymous — callers that
    /// expect an authenticated response should treat that as a logic
    /// error.
    public static func authorized(
        _ url: URL,
        bearer: String?,
        method: Method = .get,
        jsonBody: Data? = nil,
        timeout: TimeInterval = 10
    ) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method.rawValue
        if let bearer = bearer, !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body = jsonBody {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("FeralCompanion/iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Resolve a relative path against the active brain HTTP base
    /// (``brainClient.brainHTTPBase``). Returns ``nil`` when the
    /// brain is not connected.
    @MainActor
    public static func endpoint(
        _ path: String,
        on brainClient: BrainClient
    ) -> URL? {
        guard let base = brainClient.brainHTTPBase else { return nil }
        return URL(string: path, relativeTo: base)
    }

    // MARK: - Lane 11 brain-memory bridges (audit-r14)

    /// Kinds of bridged ingest the brain accepts from the iOS
    /// companion. Each kind is a top-level brain REST route that
    /// fan-outs into the appropriate skill manifest + memory write.
    public enum IngestKind: String {
        /// THESIS_SCENARIOS S2 — Apple HealthKit metrics. Brain
        /// route: ``POST /api/health/ingest``. Backed by Lane 05's
        /// ``health_data`` manifest. Writes ``category=health``
        /// memory records with ``source=ios.healthkit``.
        case healthKit = "health"
        /// THESIS_SCENARIOS S3 — BLE peripheral discovery. Brain
        /// route: ``POST /api/hardware/device_announce``. Routes
        /// through ``HardwareMesh.ingest_device_announce`` and
        /// writes a ``category=device`` KG entity.
        case bleDevice = "hardware/device_announce"
    }

    /// Encodable wrapper so call sites can pass typed Swift dicts
    /// without falling back to ``[String: Any]`` + JSONSerialization
    /// (which would force them to add ``NSObject`` casts at every
    /// numeric / boolean leaf).
    public struct IngestSample {
        public let payload: [String: AnyCodable]
        public init(_ payload: [String: AnyCodable]) {
            self.payload = payload
        }
    }

    /// THESIS_SCENARIOS S2 — bridged HealthKit ingest.
    ///
    /// Sends ``samples`` to ``POST /api/{kind}/ingest`` so the brain
    /// writes one memory record per sample. The brain echoes the
    /// number of records actually persisted via
    /// ``{"persisted": <int>, "skipped": <int>}`` — useful for the
    /// Devices tab to render "Synced 5 / 5 samples" without polling
    /// the memory tool.
    @MainActor
    public static func ingest(
        _ kind: IngestKind,
        samples: [IngestSample],
        bearer: String?,
        on brainClient: BrainClient
    ) async throws -> [String: Any] {
        guard let url = endpoint("/api/\(kind.rawValue)/ingest", on: brainClient) else {
            throw URLError(.badURL)
        }
        let isoFormatter = ISO8601DateFormatter()
        let serializedSamples = samples.map { sample -> Any in
            sample.payload.mapValues { $0.toJSON() }
        }
        let body: [String: Any] = [
            "source": "ios.healthkit",
            "samples": serializedSamples,
            "ingested_at": isoFormatter.string(from: Date()),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let req = authorized(url, bearer: bearer, method: .post, jsonBody: payload, timeout: 8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "FeralBrainHTTP",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "ingest failed HTTP \(http.statusCode): \(detail)"]
            )
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return parsed ?? [:]
    }

    /// THESIS_SCENARIOS S2 — brain memory search from the phone.
    ///
    /// Walks ``POST /api/memory/search`` (Lane 05's KG entity /
    /// episodic fused search). The phone chat surface uses this so
    /// "What was my heart rate this morning?" returns the same answer
    /// the WebUI does — both go through the same memory tool path.
    @MainActor
    public static func searchMemory(
        _ query: String,
        bearer: String?,
        on brainClient: BrainClient,
        limit: Int = 20
    ) async throws -> [[String: Any]] {
        guard let url = endpoint("/api/memory/search", on: brainClient) else {
            throw URLError(.badURL)
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "limit": limit,
        ])
        let req = authorized(url, bearer: bearer, method: .post, jsonBody: payload, timeout: 8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (parsed?["results"] as? [[String: Any]]) ?? []
    }
}

// MARK: - AnyCodable JSON helper

public extension AnyCodable {
    /// Convert to a JSON-serialisable value that ``JSONSerialization``
    /// accepts. Mirrors the ``encode(to:)`` switch in
    /// ``Sources/FeralNodeSDK/HUPFrame.swift`` so we can pass the
    /// same payload shape through ``JSONSerialization`` for REST
    /// calls.
    func toJSON() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let v):
            return v
        case .int(let v):
            return v
        case .double(let v):
            return v
        case .string(let v):
            return v
        case .array(let v):
            return v.map { $0.toJSON() }
        case .object(let v):
            var dict: [String: Any] = [:]
            for (k, anyVal) in v {
                dict[k] = anyVal.toJSON()
            }
            return dict
        }
    }
}
