import SwiftUI

@main
struct InfraLabApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .task {
                    await appState.refreshAll()
                    appState.startAutoRefresh()
                }
        }
    }
}
