import Foundation

/// Theora wristband adapter — wraps VeepooBleSDK.framework.
///
/// When VeepooBleSDK is linked into the host app, ``DeviceStore``
/// instantiates ``VeepooAdapterWired`` instead of this stub.
/// See App/Sources/Adapters/VeepooAdapterWired.swift and
/// App/Sources/Adapters/VeepooSession.swift.
public final class VeepooAdapter: VendorAdapter {
    public let capability: String = "veepoo_wristband"

    public init() {}

    public func attach(to node: FeralNode) async throws {
        throw FeralNodeError.adapterNotWired(
            capability: capability,
            reason: "VeepooBleSDK.framework is not linked into the host app. " +
                    "Drop VeepooBleSDK.framework (+ companion frameworks) into " +
                    "Vendor/ and run ./scripts/bootstrap.sh."
        )
    }

    public func detach() async {}

    public func canHandleAction(named name: String) async -> Bool {
        return ["health_measure", "get_heart_rate", "get_spo2", "buzz"].contains(name)
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        NSLog("VeepooAdapter.handleAction(%@) awaiting SDK wire-up", String(describing: frame.type))
    }
}
