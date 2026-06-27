import SwiftUI
import Charts

// MARK: - Dashboard list

struct MetricsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            Group {
                if appState.grafanaBaseURL.isEmpty {
                    ContentUnavailableView(
                        "Grafana Not Configured",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Add Grafana URL and token in Settings")
                    )
                } else if appState.dashboards.isEmpty && appState.dashboardsLoading {
                    ProgressView("Loading dashboards…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = appState.dashboardsError, appState.dashboards.isEmpty {
                    ContentUnavailableView("Failed to Load", systemImage: "exclamationmark.triangle", description: Text(e))
                } else {
                    List(appState.dashboards) { dash in
                        NavigationLink(value: dash) {
                            Label(dash.title, systemImage: "rectangle.3.group")
                        }
                    }
                    .refreshable { await appState.loadDashboards() }
                }
            }
            .navigationTitle("Metrics")
            .navigationDestination(for: DashboardInfo.self) { DashboardDetailView(dashboard: $0) }
            .task { if appState.dashboards.isEmpty { await appState.loadDashboards() } }
        }
    }
}

// MARK: - One dashboard → all panels

struct DashboardDetailView: View {
    @EnvironmentObject var appState: AppState
    let dashboard: DashboardInfo

    @State private var panels: [PanelDef] = []
    @State private var loading = true
    @State private var error: String?
    @State private var reloadToken = 0

    var body: some View {
        ScrollView {
            if loading && panels.isEmpty {
                ProgressView().padding(.top, 40)
            } else if let error {
                ContentUnavailableView("Failed to Load", systemImage: "exclamationmark.triangle", description: Text(error))
                    .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(panels) { panel in
                        if panel.kind == .row {
                            Text(panel.title.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        } else {
                            NativePanelView(panel: panel, reloadToken: reloadToken)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(dashboard.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task(id: dashboard.uid) { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do { panels = try await appState.fetchPanels(uid: dashboard.uid) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

// MARK: - A single panel, rendered natively by type

struct NativePanelView: View {
    @EnvironmentObject var appState: AppState
    let panel: PanelDef
    let reloadToken: Int

    @State private var series: [MetricSeries] = []
    @State private var rows: [InstantRow] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(panel.title.isEmpty ? " " : panel.title)
                .font(.subheadline.weight(.semibold))

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .task(id: reloadToken) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && series.isEmpty && rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        } else if let error, series.isEmpty, rows.isEmpty {
            Text(error).font(.caption).foregroundStyle(.secondary).frame(minHeight: 60)
        } else {
            switch panel.kind {
            case .timeseries: TimeseriesChart(series: series, unit: panel.unit)
            case .stat:       StatView(rows: rows, unit: panel.unit)
            case .gauge:      GaugeView(rows: rows, unit: panel.unit)
            case .bargauge:   BarGaugeView(rows: rows, unit: panel.unit)
            case .table:      TableView(rows: rows, unit: panel.unit)
            default:          Text("Unsupported panel").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            switch panel.kind {
            case .timeseries:
                var all: [MetricSeries] = []
                for t in panel.targets { all += try await appState.promRange(t.expr, legend: t.legend) }
                series = all
            default:
                var all: [InstantRow] = []
                for t in panel.targets { all += try await appState.promInstant(t.expr, legend: t.legend) }
                rows = all
            }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

// MARK: - Renderers

struct TimeseriesChart: View {
    let series: [MetricSeries]
    let unit: String

    var body: some View {
        if series.isEmpty {
            Text("No data").font(.caption).foregroundStyle(.secondary).frame(minHeight: 60)
        } else {
            Chart {
                ForEach(series) { s in
                    ForEach(s.points) { p in
                        LineMark(x: .value("t", p.time), y: .value("v", p.value))
                            .foregroundStyle(by: .value("s", s.name))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartLegend(.hidden)
            .frame(height: 160)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(series) { s in
                        Text(s.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

struct StatView: View {
    let rows: [InstantRow]
    let unit: String
    var body: some View {
        if rows.count <= 1 {
            Text(rows.first.map { GUnit.format($0.value, unit: unit) } ?? "—")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { r in
                    HStack {
                        Text(r.name).font(.subheadline).lineLimit(1)
                        Spacer()
                        Text(GUnit.format(r.value, unit: unit))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
    }
}

struct GaugeView: View {
    let rows: [InstantRow]
    let unit: String
    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows) { r in
                if unit == "percent" || unit == "percentunit" {
                    let pct = unit == "percentunit" ? r.value * 100 : r.value
                    Gauge(value: min(max(pct, 0), 100), in: 0...100) {
                        Text(r.name).font(.caption2)
                    } currentValueLabel: {
                        Text("\(Int(pct))%").font(.caption.monospacedDigit())
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                } else {
                    HStack {
                        Text(r.name).font(.subheadline)
                        Spacer()
                        Text(GUnit.format(r.value, unit: unit)).font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
    }
}

struct BarGaugeView: View {
    let rows: [InstantRow]
    let unit: String
    private var maxVal: Double { max(rows.map(\.value).max() ?? 1, 0.0001) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(GUnit.format(r.value, unit: unit)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.gray.opacity(0.2))
                            Capsule().fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(min(r.value / maxVal, 1)))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
    }
}

struct TableView: View {
    let rows: [InstantRow]
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                HStack {
                    Text(r.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(GUnit.format(r.value, unit: unit)).font(.caption.monospacedDigit().weight(.medium))
                }
                .padding(.vertical, 5)
                if idx < rows.count - 1 { Divider() }
            }
        }
    }
}

// MARK: - Unit formatting (Grafana unit ids)

enum GUnit {
    static func format(_ v: Double, unit: String) -> String {
        switch unit {
        case "percent": return pct(v)
        case "percentunit": return pct(v * 100)
        case "bytes", "decbytes", "bytes_iec":
            return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary)
        case "celsius": return String(format: "%.0f°C", v)
        case "bps": return rate(v, "bps")
        case "Bps", "binBps": return rate(v, "B/s")
        case "s", "seconds": return String(format: "%.1fs", v)
        case "dtdurations", "dtdurationms": return String(format: "%.0f ms", v)
        default: return short(v)
        }
    }
    private static func pct(_ v: Double) -> String { String(format: v >= 10 ? "%.0f%%" : "%.1f%%", v) }
    private static func short(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000_000 { return String(format: "%.1fB", v/1e9) }
        if a >= 1_000_000 { return String(format: "%.1fM", v/1e6) }
        if a >= 1_000 { return String(format: "%.1fK", v/1e3) }
        return a < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v)
    }
    private static func rate(_ v: Double, _ suffix: String) -> String {
        let a = abs(v)
        if a >= 1e9 { return String(format: "%.1f G%@", v/1e9, suffix) }
        if a >= 1e6 { return String(format: "%.1f M%@", v/1e6, suffix) }
        if a >= 1e3 { return String(format: "%.1f K%@", v/1e3, suffix) }
        return String(format: "%.0f %@", v, suffix)
    }
}
