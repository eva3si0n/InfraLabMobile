import Foundation
import UIKit

@MainActor
final class AppState: ObservableObject {

    // MARK: - Persisted settings (UserDefaults)

    @Published var kumaBaseURL: String { didSet { ud.set(kumaBaseURL, forKey: "kumaBaseURL") } }
    @Published var kumaSlug: String { didSet { ud.set(kumaSlug, forKey: "kumaSlug") } }
    @Published var grafanaBaseURL: String { didSet { ud.set(grafanaBaseURL, forKey: "grafanaBaseURL") } }
    @Published var grafanaDatasourceUID: String { didSet { ud.set(grafanaDatasourceUID, forKey: "grafanaDatasourceUID") } }
    @Published var homePageBaseURL: String { didSet { ud.set(homePageBaseURL, forKey: "homePageBaseURL") } }
    @Published var refreshInterval: Double { didSet { ud.set(refreshInterval, forKey: "refreshInterval") } }

    // Secure tokens (Keychain)
    var kumaAPIKey: String {
        get { Keychain.get("kumaAPIKey") ?? "" }
        set { objectWillChange.send(); Keychain.set("kumaAPIKey", value: newValue) }
    }
    var grafanaToken: String {
        get { Keychain.get("grafanaToken") ?? "" }
        set { objectWillChange.send(); Keychain.set("grafanaToken", value: newValue) }
    }

    // MARK: - Runtime data

    @Published var monitors: [MonitorStatus] = []
    @Published var monitorsLoading = false
    @Published var monitorsError: String?

    @Published var dashboards: [DashboardInfo] = []
    @Published var dashboardsLoading = false
    @Published var dashboardsError: String?

    // MARK: - Private

    private let ud = UserDefaults.standard
    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        kumaBaseURL = ud.string(forKey: "kumaBaseURL") ?? ""
        kumaSlug = ud.string(forKey: "kumaSlug") ?? ""
        grafanaBaseURL = ud.string(forKey: "grafanaBaseURL") ?? ""
        grafanaDatasourceUID = ud.string(forKey: "grafanaDatasourceUID") ?? "prometheus"
        homePageBaseURL = ud.string(forKey: "homePageBaseURL") ?? ""
        let stored = ud.double(forKey: "refreshInterval")
        refreshInterval = stored > 0 ? stored : 30
        seedFromBundleIfNeeded()
    }

    var isConfigured: Bool {
        !kumaBaseURL.isEmpty || !grafanaBaseURL.isEmpty || !homePageBaseURL.isEmpty
    }

    /// Pre-fill Settings from a bundled `seed.json` on first launch (personal builds).
    /// The file is gitignored — never committed; absent in public clones (then no-op).
    private struct SeedConfig: Codable {
        var kumaBaseURL, kumaSlug, kumaAPIKey: String?
        var grafanaBaseURL, grafanaDatasourceUID, grafanaToken: String?
        var homePageBaseURL: String?
    }

    private func seedFromBundleIfNeeded() {
        guard !isConfigured else { return }
        guard let url = Bundle.main.url(forResource: "seed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SeedConfig.self, from: data) else { return }
        if let v = s.kumaBaseURL { kumaBaseURL = v }
        if let v = s.kumaSlug { kumaSlug = v }
        if let v = s.grafanaBaseURL { grafanaBaseURL = v }
        if let v = s.grafanaDatasourceUID, !v.isEmpty { grafanaDatasourceUID = v }
        if let v = s.homePageBaseURL { homePageBaseURL = v }
        if let v = s.kumaAPIKey, !v.isEmpty { kumaAPIKey = v }
        if let v = s.grafanaToken, !v.isEmpty { grafanaToken = v }
    }

    // MARK: - Refresh orchestration

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            if !kumaBaseURL.isEmpty && !kumaSlug.isEmpty {
                group.addTask { await self.refreshMonitors() }
            }
            if !grafanaBaseURL.isEmpty {
                group.addTask { await self.loadDashboards() }
            }
        }
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.refreshMonitors()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Kuma

    func refreshMonitors() async {
        guard !kumaBaseURL.isEmpty, !kumaSlug.isEmpty else { return }
        monitorsLoading = true
        monitorsError = nil
        defer { monitorsLoading = false }

        let base = kumaBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        let slug = kumaSlug
        let token = kumaAPIKey

        do {
            async let pageTask = apiGet("\(base)/api/status-page/\(slug)", token: token)
            async let beatTask = apiGet("\(base)/api/status-page/heartbeat/\(slug)", token: token)
            let (pageData, beatData) = try await (pageTask, beatTask)

            let page = try JSONDecoder().decode(KumaStatusPageResponse.self, from: pageData)
            let beats = try JSONDecoder().decode(KumaHeartbeatResponse.self, from: beatData)

            var result: [MonitorStatus] = []
            for group in page.publicGroupList {
                for monitor in group.monitorList {
                    let key = String(monitor.id)
                    let heartbeats = beats.heartbeatList[key] ?? []
                    result.append(MonitorStatus(
                        id: monitor.id,
                        name: monitor.name,
                        groupName: group.name,
                        isUp: heartbeats.last?.status == 1,
                        latency: heartbeats.last?.ping.map { Int($0.rounded()) },
                        uptime24h: beats.uptimeList["\(key)_24"] ?? 0,
                        recentBeats: Array(heartbeats.suffix(25))
                    ))
                }
            }
            monitors = result
        } catch {
            monitorsError = error.localizedDescription
        }
    }

    // MARK: - Grafana dashboards (native, auto-extracted)

    func loadDashboards() async {
        guard !grafanaBaseURL.isEmpty else { return }
        dashboardsLoading = true
        dashboardsError = nil
        defer { dashboardsLoading = false }
        do {
            let base = grafanaBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
            let data = try await apiGet("\(base)/api/search?type=dash-db&limit=200", token: grafanaToken)
            dashboards = try JSONDecoder().decode([DashboardInfo].self, from: data)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            dashboardsError = error.localizedDescription
        }
    }

    /// Fetch a dashboard and flatten its panels (rows become `.row` headers).
    func fetchPanels(uid: String) async throws -> [PanelDef] {
        let base = grafanaBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        let data = try await apiGet("\(base)/api/dashboards/uid/\(uid)", token: grafanaToken)
        let resp = try JSONDecoder().decode(GDashResponse.self, from: data)
        var out: [PanelDef] = []
        func add(_ p: GPanel) {
            let kind = panelKind(p.type)
            if kind == .row {
                out.append(PanelDef(title: p.title ?? "", kind: .row, unit: "", targets: []))
                (p.panels ?? []).forEach(add)
                return
            }
            let targets = (p.targets ?? []).compactMap { t -> (String, String)? in
                guard let e = t.expr, !e.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return (e, t.legendFormat ?? "")
            }
            guard !targets.isEmpty else { return }
            out.append(PanelDef(
                title: p.title ?? "",
                kind: kind,
                unit: p.fieldConfig?.defaults?.unit ?? "",
                targets: targets
            ))
        }
        resp.dashboard.panels.forEach(add)
        return out
    }

    private func panelKind(_ type: String) -> PanelKind {
        switch type {
        case "row": return .row
        case "timeseries", "graph", "barchart", "state-timeline": return .timeseries
        case "stat", "singlestat": return .stat
        case "gauge": return .gauge
        case "bargauge": return .bargauge
        case "table", "table-old": return .table
        default: return .unsupported
        }
    }

    // MARK: - Prometheus queries (via Grafana datasource proxy)

    func promRange(_ expr: String, legend: String) async throws -> [MetricSeries] {
        let end = Date(); let start = end.addingTimeInterval(-6 * 3600)
        var comps = proxyComponents(path: "query_range")
        comps?.queryItems = [
            .init(name: "query", value: expr),
            .init(name: "start", value: String(Int(start.timeIntervalSince1970))),
            .init(name: "end", value: String(Int(end.timeIntervalSince1970))),
            .init(name: "step", value: "300")
        ]
        let data = try await get(comps)
        let decoded = try JSONDecoder().decode(PromResponse.self, from: data)
        return decoded.data.result.map { s in
            let points: [MetricPoint] = s.values.compactMap { pair in
                guard pair.count == 2, let t = pair[0].asDouble,
                      let v = pair[1].asDouble, v.isFinite else { return nil }
                return MetricPoint(time: Date(timeIntervalSince1970: t), value: v)
            }
            return MetricSeries(name: seriesName(s.metric, legend: legend), points: points)
        }.filter { !$0.points.isEmpty }
    }

    func promInstant(_ expr: String, legend: String) async throws -> [InstantRow] {
        var comps = proxyComponents(path: "query")
        comps?.queryItems = [.init(name: "query", value: expr)]
        let data = try await get(comps)
        let decoded = try JSONDecoder().decode(PromInstantResponse.self, from: data)
        return decoded.data.result.compactMap { s in
            guard s.value.count == 2, let v = s.value[1].asDouble, v.isFinite else { return nil }
            return InstantRow(name: seriesName(s.metric, legend: legend), labels: s.metric, value: v)
        }
    }

    private func proxyComponents(path: String) -> URLComponents? {
        let base = grafanaBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        let uid = grafanaDatasourceUID.isEmpty ? "prometheus" : grafanaDatasourceUID
        return URLComponents(string: "\(base)/api/datasources/proxy/uid/\(uid)/api/v1/\(path)")
    }

    private func get(_ comps: URLComponents?) async throws -> Data {
        guard let url = comps?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let token = grafanaToken
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "Prom", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return data
    }

    /// Resolve a series name. Honours Grafana's `{{label}}` legend templating.
    private func seriesName(_ metric: [String: String], legend: String) -> String {
        if !legend.isEmpty {
            var out = legend
            for (k, v) in metric {
                out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
                out = out.replacingOccurrences(of: "{{ \(k) }}", with: v)
            }
            // strip any leftover {{...}} placeholders
            out = out.replacingOccurrences(of: #"\{\{[^}]*\}\}"#, with: "", options: .regularExpression)
            let trimmed = out.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return metric["host"] ?? metric["instance"] ?? metric["name"]
            ?? metric.values.first ?? "value"
    }

    // MARK: - Networking

    private func apiGet(_ urlStr: String, token: String) async throws -> Data {
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "API", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return data
    }
}
