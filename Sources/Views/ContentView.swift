import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            MonitorsView()
                .tabItem { Label("Monitors", systemImage: "dot.radiowaves.up.forward") }

            CascadeView()
                .tabItem { Label("Cascade", systemImage: "arrow.triangle.branch") }

            MetricsView()
                .tabItem { Label("Metrics", systemImage: "chart.xyaxis.line") }

            HomePageView()
                .tabItem { Label("HomePage", systemImage: "house") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
