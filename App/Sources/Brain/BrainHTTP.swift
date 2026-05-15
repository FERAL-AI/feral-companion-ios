import Foundation

/// Single source of truth for authed REST calls to the brain.
///
/// The brain's `APIKeyMiddleware` only accepts `Authorization: Bearer
/// <token>` on HTTP — there is no query-string fallback for REST
/// endpoints (only WebSockets get that). Several iOS surfaces poll the
/// brain over REST today (Context tab, Devices Brain Network section,
/// onboarding wizard's permissions probe, transcript reconcile after
/// foreground), and they all previously sent unauthenticated GETs.
///
/// Operator log 2026-05-14T23:27:02 captured the symptom: every
/// `/api/context/live` poll returned 401 because the brain side only
/// honors `FERAL_API_KEY` while iOS holds a `phone_bearer` minted by
/// `/api/devices/pair/complete`. The matching brain change extends
/// `APIKeyMiddleware` to also accept `phone_bearer` / `pair_token`
/// via the existing `_verify_credential` helper. Until that change
/// lands, iOS pre-ships the header so REST polling lights up the
/// moment the brain is updated.
extension BrainClient {

    /// Build an authed `URLRequest` for `path` (relative to the brain's
    /// HTTP base). Returns `nil` if there is no live brain connection
    /// (e.g. before pairing or after `unpair()` cleared the bearer).
    ///
    /// `path` is a brain-relative URL like `"/api/context/live"`. We
    /// resolve it against the WS-derived `brainHTTPBase` so the same
    /// request format works for `http://` lab brains and `https://`
    /// production brains.
    public func authedRequest(path: String, timeout: TimeInterval = 10) -> URLRequest? {
        guard let httpBase = brainHTTPBase,
              let url = URL(string: path, relativeTo: httpBase)
        else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if let bearer = httpBearer, !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
}

/// Lightweight categorisation of HTTP failures so callers can render
/// truth-in-status messages without inventing prose. The Context tab
/// uses this to swap "Status 401" for an operator-friendly explanation
/// when the brain hasn't yet been updated to honor `phone_bearer` on
/// HTTP. Operator complaint 2026-05-14: a bare "Status 401" gives no
/// signal whether the bug is on the phone, the brain, or the network.
public enum BrainHTTPFailure: Error, Equatable {
    /// Brain reachable but rejected the request because the bearer
    /// wasn't accepted. Typically means the brain hasn't been
    /// updated to honor `phone_bearer` on HTTP yet.
    case unauthorized
    /// Brain reachable but returned a non-401 error status.
    case status(Int)
    /// Lower-level transport error (DNS, TCP, TLS, timeout). The
    /// underlying `Error.localizedDescription` is captured so the UI
    /// can surface the OS message when relevant.
    case transport(String)
    /// Body wasn't valid JSON.
    case invalidJSON

    /// Operator-facing message. Phrased so the reader can act on the
    /// failure without needing to crack open the device log.
    public var userMessage: String {
        switch self {
        case .unauthorized:
            return "Brain rejected this request (401). The brain needs to accept the phone bearer on HTTP — update the brain or re-pair."
        case .status(let code):
            return "Brain returned status \(code)."
        case .transport(let reason):
            return reason
        case .invalidJSON:
            return "Brain response wasn't JSON."
        }
    }
}

extension BrainClient {
    /// Run an authed JSON GET and report a structured failure rather
    /// than a stringified status code so callers can render targeted
    /// UI copy (see `BrainHTTPFailure.userMessage`). On success returns
    /// the decoded JSON object; on any failure mode returns the
    /// matching ``BrainHTTPFailure``.
    public func authedJSONGET(_ path: String, timeout: TimeInterval = 10) async -> Result<[String: Any], BrainHTTPFailure> {
        guard let req = authedRequest(path: path, timeout: timeout) else {
            return .failure(.transport("Not connected to a brain."))
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("No HTTP response."))
            }
            if http.statusCode == 401 {
                return .failure(.unauthorized)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.status(http.statusCode))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.invalidJSON)
            }
            return .success(json)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
