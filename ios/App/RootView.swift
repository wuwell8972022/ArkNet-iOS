import SwiftUI

/// Four-tab root — mirrors the Android IA:
/// MainHomeActivity / MemberActivity / NavActivity / MineActivity.
struct RootView: View {

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "bolt.horizontal.fill") }
            MemberView()
                .tabItem { Label("会员", systemImage: "crown.fill") }
            NavView()
                .tabItem { Label("导航", systemImage: "safari") }
            MineView()
                .tabItem { Label("我的", systemImage: "person.fill") }
        }
        .onAppear {
            // Warm up the engine status socket early.
            TunnelCommandClient.shared.connect()
        }
    }
}
