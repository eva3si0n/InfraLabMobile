import Foundation

// MARK: - Dashboard list

struct DashboardInfo: Identifiable, Codable, Hashable {
    let uid: String
    let title: String
    var id: String { uid }
}

// MARK: - Grafana dashboard definition (decode)

struct GDashResponse: Codable { let dashboard: GDash }

struct GDash: Codable {
    let title: String
    let panels: [GPanel]
}

struct GPanel: Codable {
    let id: Int?
    let type: String
    let title: String?
    let targets: [GTarget]?
    let panels: [GPanel]?            // nested inside collapsed rows
    let fieldConfig: GFieldConfig?
}

struct GTarget: Codable {
    let expr: String?
    let legendFormat: String?
}

struct GFieldConfig: Codable {
    let defaults: GFieldDefaults?
}

struct GFieldDefaults: Codable {
    let unit: String?
}

// MARK: - Flattened panel ready to render

enum PanelKind {
    case timeseries, stat, gauge, bargauge, table, row, unsupported
}

struct PanelDef: Identifiable {
    let id = UUID()
    let title: String
    let kind: PanelKind
    let unit: String       // grafana unit id (percent, bytes, celsius, bps, short…)
    let targets: [(expr: String, legend: String)]
}

// MARK: - Prometheus instant query (vector)

struct PromInstantResponse: Codable {
    let data: PromInstantData
}

struct PromInstantData: Codable {
    let resultType: String
    let result: [PromInstantSeries]
}

struct PromInstantSeries: Codable {
    let metric: [String: String]
    let value: [PromValue]   // [ts, "value"]
}

/// A single label/value row for stat/table/bargauge panels.
struct InstantRow: Identifiable {
    let id = UUID()
    let name: String
    let labels: [String: String]
    let value: Double
}
