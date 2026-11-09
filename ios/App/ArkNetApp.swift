import SwiftUI

@main
struct ArkNetApp: App {
    @StateObject private var session = UserSession.shared
    @StateObject private var vpn = VPNManager.shared
    @StateObject private var engine = TunnelCommandClient.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(vpn)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
