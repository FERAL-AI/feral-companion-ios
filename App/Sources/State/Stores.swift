import Foundation

/// Phase-1 stubs. Real implementations land in Phase 3.
@MainActor public final class ConnectionStore: ObservableObject {
    @Published public private(set) var status: String = "disconnected"
    public init() {}
}

@MainActor public final class ChatStore: ObservableObject {
    @Published public private(set) var messages: [String] = []
    public init() {}
}

@MainActor public final class HealthStore: ObservableObject {
    @Published public private(set) var heartRate: Int? = nil
    @Published public private(set) var spo2: Int? = nil
    @Published public private(set) var steps: Int? = nil
    public init() {}
}

@MainActor public final class DeviceStore: ObservableObject {
    @Published public private(set) var connectedAdapters: [String] = []
    public init() {}
}
