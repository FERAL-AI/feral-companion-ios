import SwiftUI

@main
struct FeralCompanionApp: App {
    @StateObject private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    environment.handleDeepLink(url)
                }
        }
    }
}
