import Foundation

// MARK: - Kuma

struct KumaStatusPageResponse: Codable {
    let config: KumaPageConfig
    let publicGroupList: [KumaGroup]
}

struct KumaPageConfig: Codable {
    let title: String
    let slug: String
}

struct KumaGroup: Codable {
    let id: Int
    let name: String
    let monitorList: [KumaMonitorInfo]
}

struct KumaMonitorInfo: Codable, Identifiable {
    let id: Int
    let name: String
    let type: String?
}

struct KumaHeartbeatResponse: Codable {
    let heartbeatList: [String: [KumaHeartbeat]]
    let uptimeList: [String: Double]
}

struct KumaHeartbeat: Codable {
    let status: Int  // 1=up, 0=down
    let ping: Double?  // Kuma reports latency in ms as a fractional value (e.g. 46.1)
    let time: String
}

struct MonitorStatus: Identifiable {
    let id: Int
    let name: String
    let groupName: String
    let isUp: Bool
    let latency: Int?
    let uptime24h: Double
    let recentBeats: [KumaHeartbeat]
}

// MARK: - Prometheus (native charts via Grafana datasource proxy)

/// One time-series line ready to render.
struct MetricSeries: Identifiable {
    let id = UUID()
    let name: String
    let points: [MetricPoint]
}

struct MetricPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

// Prometheus query_range response
struct PromResponse: Codable {
    let status: String
    let data: PromData
}

struct PromData: Codable {
    let resultType: String
    let result: [PromSeries]
}

struct PromSeries: Codable {
    let metric: [String: String]
    let values: [[PromValue]]
}

// Each value is [unixSeconds(Double), "stringValue"]
enum PromValue: Codable {
    case num(Double)
    case str(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .num(d) }
        else { self = .str((try? c.decode(String.self)) ?? "") }
    }
    func encode(to encoder: Encoder) throws {}

    var asDouble: Double? {
        switch self {
        case .num(let d): return d
        case .str(let s): return Double(s)
        }
    }
}
