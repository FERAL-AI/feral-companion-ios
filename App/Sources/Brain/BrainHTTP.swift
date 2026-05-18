import Foundation

/// Centralised HTTP helper for all brain REST calls.
///
/// Audit-r11 — Bug 2 (iOS "Context unavailable / Status 401"). Before
/// this helper, every store rolled its own `URLSession.shared.data(from:)`
/// against `/api/context/live`, `/api/capabilities`,
/// `/api/sessions/primary/transcript`, and `/api/system/permissions[/open]`.
/// None of those callers attached an ``Authorization`` header, so the
/// brain's `_PHONE_BEARER_GET_PATHS` gate (see `feral-core/api/server.py`
/// line ~374) responded `401 unauthorized` and the Context tab rendered
/// "Status 401". The fix is to route every such call through
/// ``BrainHTTP.authorized`` which attaches the cached `phone_bearer`
/// from ``BrainClient``.
///
/// The helper deliberately keeps zero internal state — `bearer` is
/// passed in explicitly so unit tests can drive the auth path with a
/// stubbed value and so `ConnectionStore` remains the single source of
/// truth for credential storage.
public enum BrainHTTP {

    /// HTTP methods we round-trip through here. Restricted to the
    /// verbs the iOS app actually issues today; adding a new one is
    /// a one-line change.
    public enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    /// Build a pre-populated ``URLRequest`` for a brain REST endpoint
    /// with the user's `phone_bearer` attached as a bearer token.
    ///
    /// Empty / nil bearer renders the request anonymous — callers that
    /// expect an authenticated response should treat that as a logic
    /// error (we don't crash here because the brain still serves a few
    /// public paths and the regression test suite asserts the header
    /// SHAPE, not its presence).
    ///
    /// - Parameters:
    ///   - url: Fully-resolved endpoint URL.
    ///   - bearer: The cached `phone_bearer` from
    ///     ``BrainClient/phoneBearer`` (mirrored from ``ConnectionStore``).
    ///   - method: HTTP verb. Defaults to ``Method/get``.
    ///   - jsonBody: Optional JSON payload — sets the
    ///     ``Content-Type: application/json`` header for you.
    ///   - timeout: Per-request timeout in seconds. Defaults to 10s to
    ///     stay below the ConnectionStore polling cadence so a slow
    ///     brain never queues up overlapping refreshes.
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
        // Phone bearer auth follows the same shape the brain uses for
        // its WebSocket envelopes, so mirroring the User-Agent string
        // makes the brain audit log easy to filter ("which surface hit
        // this endpoint" today is a guessing game).
        req.setValue("FeralCompanion/iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Resolve a relative path against the active brain HTTP base
    /// (`brainClient.brainHTTPBase`). Returns `nil` when the brain is
    /// not connected — callers should treat that as "no-op" instead of
    /// surfacing as an error since the views guard on connection state
    /// elsewhere.
    ///
    /// `@MainActor` because ``BrainClient`` is `@MainActor`-isolated and
    /// reading `brainHTTPBase` from a nonisolated context fails to
    /// compile under Swift 5.10+ strict concurrency.
    @MainActor
    public static func endpoint(
        _ path: String,
        on brainClient: BrainClient
    ) -> URL? {
        guard let base = brainClient.brainHTTPBase else { return nil }
        return URL(string: path, relativeTo: base)
    }
}
