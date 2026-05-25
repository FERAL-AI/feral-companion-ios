import Foundation
import Network

/// Authoritative probe for the iOS 14+ Local Network permission gate.
///
/// iOS does not expose a public API to read the current Local Network
/// authorisation state directly. The Apple-recommended pattern (used by
/// `NetworkExtension`, MFi/CarPlay sample code, and reverse-engineered
/// from `nw_browser_fail_on_dns_error_locked` / `NoAuth(-65555)` traces
/// in our own pairing log) is to:
///
///   1. Start an `NWListener` advertising a tiny Bonjour service of a
///      type the app already declares in `NSBonjourServices` (here
///      `_feral-probe._tcp`, which we register alongside `_feral._tcp`).
///   2. Start an `NWBrowser` for the same type.
///   3. Wait for either of:
///        * `browseResultsChangedHandler` firing with our own
///          advertisement (-> Local Network is **granted**),
///        * the browser entering `.failed(.posix(.ENOAUTH))` (-> Local
///          Network is **denied**, the user previously tapped Deny),
///        * a 4s timeout (-> **undetermined**, prompt has not fired or
///          the user has not answered yet).
///
/// This is the same probe Apple's "Local Network Privacy FAQ"
/// recommends and is intentionally **not** a workaround — calling it
/// is what causes iOS to surface the system Local Network alert in
/// the first place. Run it before any HTTP request to an RFC-1918
/// address so the misleading `-1009 "Internet connection appears to
/// be offline"` error never reaches the user.
@MainActor
final class LocalNetworkAuthorization: ObservableObject {

    enum State: Equatable {
        case undetermined
        case granted
        case denied
    }

    @Published private(set) var state: State = .undetermined

    private let serviceType = "_feral-probe._tcp"

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var continuation: CheckedContinuation<State, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var inflight = false

    /// Trigger the iOS Local Network prompt and resolve to the current
    /// authorisation state. Safe to call repeatedly — concurrent or
    /// duplicate invocations short-circuit on the cached state.
    @discardableResult
    func prime(timeout: TimeInterval = 4.0) async -> State {
        if state != .undetermined { return state }
        if inflight { return state }
        inflight = true

        let result = await withCheckedContinuation { (cont: CheckedContinuation<State, Never>) in
            continuation = cont
            startProbe(timeout: timeout)
        }

        state = result
        inflight = false
        return result
    }

    /// Re-arm the probe after the user toggles Settings → Local Network.
    /// Call this from the foreground-restored path in the pair screen so
    /// the banner reflects the new state.
    func reset() {
        teardown()
        state = .undetermined
        inflight = false
    }

    // MARK: - Internals

    private func startProbe(timeout: TimeInterval) {
        let serviceName = "feral-probe-\(UUID().uuidString.prefix(8))"

        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: serviceName, type: serviceType)
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            listener.stateUpdateHandler = { _ in }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            finish(with: .undetermined)
            return
        }

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failed(let err) = state {
                    if Self.isAuthError(err) {
                        self.finish(with: .denied)
                    } else {
                        self.finish(with: .undetermined)
                    }
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard !results.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.finish(with: .granted)
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await MainActor.run {
                self?.finish(with: .undetermined)
            }
        }
    }

    private func finish(with newState: State) {
        guard let cont = continuation else { return }
        continuation = nil
        teardown()
        cont.resume(returning: newState)
    }

    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
    }

    private static func isAuthError(_ err: NWError) -> Bool {
        switch err {
        case .posix(let code):
            // ENOAUTH is exposed only on macOS; on iOS POSIXErrorCode does
            // not list it, so the browser surfaces it through .dns instead.
            return code.rawValue == 81 // ENOAUTH on Darwin
        case .dns(let code):
            // kDNSServiceErr_NoAuth = -65555 (dns_sd.h). Network framework
            // surfaces NoAuth here when the Local Network entitlement is
            // missing or the user denied the permission.
            return code == -65555
        default:
            return false
        }
    }
}
