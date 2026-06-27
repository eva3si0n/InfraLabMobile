import SwiftUI
import WebKit

struct HomePageView: View {
    @EnvironmentObject var appState: AppState
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if let url = url {
                    WebView(url: url, reloadToken: reloadToken)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "HomePage Not Configured",
                        systemImage: "house",
                        description: Text("Add HomePage URL in Settings")
                    )
                }
            }
            .navigationTitle("HomePage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if url != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { reloadToken += 1 } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    private var url: URL? {
        let s = appState.homePageBaseURL.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return URL(string: s)
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            wv.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastToken = 0 }
}
