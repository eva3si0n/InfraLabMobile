import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var kumaKeyInput = ""
    @State private var grafanaTokenInput = ""

    var body: some View {
        NavigationStack {
            Form {
                kumaSection
                grafanaSection
                homePageSection
                generalSection
                actionsSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sections

    private var kumaSection: some View {
        Section {
            TextField("https://kuma.example.com", text: $appState.kumaBaseURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)

            TextField("Slug (e.g. default)", text: $appState.kumaSlug)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            tokenField(
                placeholder: "API Key (optional for public pages)",
                input: $kumaKeyInput,
                isSaved: !appState.kumaAPIKey.isEmpty
            )
        } header: {
            Label("Uptime Kuma", systemImage: "dot.radiowaves.up.forward")
        } footer: {
            Text("Leave API Key empty for public status pages")
        }
    }

    private var grafanaSection: some View {
        Section {
            TextField("https://grafana.example.com", text: $appState.grafanaBaseURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)

            TextField("Datasource UID (default: prometheus)", text: $appState.grafanaDatasourceUID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            tokenField(
                placeholder: "Service Account Token",
                input: $grafanaTokenInput,
                isSaved: !appState.grafanaToken.isEmpty
            )
        } header: {
            Label("Grafana", systemImage: "chart.xyaxis.line")
        } footer: {
            Text("Native charts query Prometheus via Grafana's datasource proxy")
        }
    }

    private var homePageSection: some View {
        Section {
            TextField("https://home.example.com", text: $appState.homePageBaseURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
        } header: {
            Label("HomePage", systemImage: "house")
        } footer: {
            Text("Shown as a web page inside the app")
        }
    }

    private var generalSection: some View {
        Section {
            Picker("Auto-refresh", selection: $appState.refreshInterval) {
                Text("15 s").tag(15.0)
                Text("30 s").tag(30.0)
                Text("1 min").tag(60.0)
                Text("5 min").tag(300.0)
            }
        } header: {
            Label("General", systemImage: "gearshape")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                saveTokens()
                Task {
                    appState.stopAutoRefresh()
                    await appState.refreshAll()
                    appState.startAutoRefresh()
                }
            } label: {
                Label("Save & Refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(.init())
            .padding(.horizontal)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func tokenField(placeholder: String, input: Binding<String>, isSaved: Bool) -> some View {
        HStack {
            SecureField(placeholder, text: input)
            if isSaved && input.wrappedValue.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    private func saveTokens() {
        if !kumaKeyInput.isEmpty {
            appState.kumaAPIKey = kumaKeyInput
            kumaKeyInput = ""
        }
        if !grafanaTokenInput.isEmpty {
            appState.grafanaToken = grafanaTokenInput
            grafanaTokenInput = ""
        }
    }
}
