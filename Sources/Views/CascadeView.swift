import SwiftUI

/// VPN Cascade — per-segment egress state + Kuma cascade health + egress-leg traffic + migration history.
/// Data: Prometheus via Grafana proxy (active leg, duration, RTT, throughput, home-ping, monthly traffic,
/// switch history) + Kuma status page (node health, cascade push-monitor heartbeat/uptime).
struct CascadeView: View {
    @EnvironmentObject var appState: AppState

    struct Seg: Identifiable {
        let id = UUID()
        let host, title, activeLeg: String
        let activeSeconds: Double
        let rtt: [String: Double]
        let txBps, rxBps: Double?
        let healthy: Bool
        let cascade: MonitorStatus?
    }
    struct Leg: Identifiable { let id = UUID(); let leg: String; let homeRTT, txBytes, limitBytes: Double? }
    struct Migration: Identifiable { let id = UUID(); let host, from, to: String; let time: Date }

    @State private var segs: [Seg] = []
    @State private var legs: [Leg] = []
    @State private var history: [Migration] = []
    @State private var loading = false
    @State private var errText: String?

    private let segCfg: [(host: String, title: String, group: String, match: String)] = [
        ("node-a", "Wired · node-a (UDM Pro — VLAN 30, 40)", "Node A", "node-a"),
        ("node-b", "Mobile · node-b (UniFi APs + LTE — VLAN 70, 80)", "Node B", "node-b")
    ]
    private let cascadeHint = "up — активное плечо STO/AMS (чистый Vultr-egress); down — деградация на FI (оба Vultr-плеча недоступны) или несвежий handshake."
    private let egressHint = "Лимит Vultr 2 ТБ на инстанс (STO и AMS отдельно), считается outbound (tx), сброс 1-го числа. FI — cold standby, квота не отслеживается."

    var body: some View {
        NavigationStack {
            Group {
                if appState.grafanaBaseURL.isEmpty {
                    ContentUnavailableView("Grafana Not Configured", systemImage: "arrow.triangle.branch",
                        description: Text("Set Grafana URL in Settings"))
                } else if segs.isEmpty && loading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = errText, segs.isEmpty {
                    ContentUnavailableView("Failed to Load", systemImage: "exclamationmark.triangle", description: Text(e))
                } else { list }
            }
            .navigationTitle("VPN Cascade")
            .toolbar { if loading { ToolbarItem(placement: .topBarTrailing) { ProgressView() } } }
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            ForEach(segs) { segmentSection($0) }
            egressSection
            historySection
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    @ViewBuilder private func segmentSection(_ s: Seg) -> some View {
        Section(s.title) {
            HStack(spacing: 6) {
                Text("Active leg").font(.subheadline)
                Spacer(minLength: 4)
                pill(s.activeLeg.uppercased(), legColor(s.activeLeg))
                pill(s.healthy ? "Healthy" : "Unhealthy", s.healthy ? .green : .red)
                pill(s.activeLeg == "sto" ? "Primary" : "Secondary", s.activeLeg == "sto" ? .green : .orange)
                Text(fmtDur(s.activeSeconds)).font(.caption).foregroundStyle(.secondary)
            }
            if let tx = s.txBps, let rx = s.rxBps {
                row("Throughput WG", "↑ \(fmtBps(tx))  ↓ \(fmtBps(rx))")
            }
            row("RTT STO", s.rtt["sto"].map { "\(Int($0.rounded())) ms" } ?? "—")
            row("RTT AMS", s.rtt["ams"].map { "\(Int($0.rounded())) ms" } ?? "—")
            row("RTT FI",  s.rtt["fi"].map  { "\(Int($0.rounded())) ms" } ?? "—")
            cascadeCard(s)
        }
    }

    @ViewBuilder private func cascadeCard(_ s: Seg) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill((s.cascade?.isUp ?? false) ? Color.green : Color.red).frame(width: 8, height: 8)
                Text("Cascade — \(s.host == "node-a" ? "Wired" : "Mobile") (\(s.host))")
                    .font(.subheadline)
                Spacer()
            }
            if let beats = s.cascade?.recentBeats, !beats.isEmpty {
                KumaHeartbeatBar(beats: beats).frame(height: 20)
            }
            Text(s.cascade.map { String(format: "%.2f%% · 24h", $0.uptime24h * 100) } ?? "no data")
                .font(.caption).foregroundStyle(.secondary)
            Text(cascadeHint).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    private var egressSection: some View {
        Section("Egress legs · from home / monthly traffic") {
            ForEach(legs) { lg in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        pill(lg.leg.uppercased(), legColor(lg.leg))
                        Spacer()
                        if let h = lg.homeRTT {
                            Text("home → \(Int(h.rounded())) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if let tx = lg.txBytes, let lim = lg.limitBytes, lim > 0 {
                        ProgressView(value: min(tx / lim, 1)) {
                            HStack {
                                Text("\(fmtBytes(tx)) / \(fmtBytes(lim))").font(.caption2)
                                Spacer()
                                Text(String(format: "%.1f%%", tx / lim * 100)).font(.caption2.monospacedDigit())
                            }
                        }
                        .tint(tx / lim > 0.85 ? .red : (tx / lim > 0.6 ? .orange : .green))
                    }
                }
                .padding(.vertical, 2)
            }
            Text(egressHint).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var historySection: some View {
        Section("History · primary-leg migrations") {
            if history.isEmpty {
                Text("No migrations recorded").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(history) { m in
                    HStack(spacing: 8) {
                        Text(m.host == "node-a" ? "Wired" : "Mobile")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        pill(m.from.uppercased(), legColor(m.from))
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        pill(m.to.uppercased(), legColor(m.to))
                        Spacer()
                        Text(fmtTime(m.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.subheadline); Spacer(); Text(v).font(.subheadline.monospacedDigit()) }
    }

    @ViewBuilder private func pill(_ text: String, _ c: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }
    private func legColor(_ l: String) -> Color { l == "sto" ? .green : (l == "ams" ? .orange : (l == "fi" ? .red : .secondary)) }

    private func fmtDur(_ s: Double) -> String {
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    private func fmtBps(_ bytesPerSec: Double) -> String {
        var v = bytesPerSec * 8; let u = ["bps", "Kbps", "Mbps", "Gbps"]; var i = 0
        while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
        return String(format: "%.1f %@", v, u[i])
    }
    private func fmtBytes(_ b: Double) -> String {
        var v = b; let u = ["B", "KB", "MB", "GB", "TB"]; var i = 0
        while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
        return String(format: "%.1f %@", v, u[i])
    }
    private func fmtTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f.string(from: d)
    }

    private func load() async {
        guard !appState.grafanaBaseURL.isEmpty else { return }
        loading = true; defer { loading = false }
        if appState.monitors.isEmpty { await appState.refreshMonitors() }
        do {
            let active = try await appState.promInstant("vpn_egress_active_leg == 1", legend: "")
            let durQ  = try await appState.promInstant("vpn_egress_active_seconds", legend: "")
            let rtt   = try await appState.promInstant("vpn_leg_rtt_ms", legend: "")
            let txbps = try await appState.promInstant("sum by (host) (rate(wireguard_sent_bytes[5m]))", legend: "")
            let rxbps = try await appState.promInstant("sum by (host) (rate(wireguard_received_bytes[5m]))", legend: "")
            let home  = try await appState.promInstant("home_node_rtt_ms", legend: "")
            let tx    = try await appState.promInstant("vds_month_tx_bytes", legend: "")
            let lim   = try await appState.promInstant("vds_month_limit_bytes", legend: "")
            let sw    = try await appState.promInstant("vpn_egress_switch_time", legend: "")

            segs = segCfg.map { cfg in
                let al = active.first { $0.labels["host"] == cfg.host }?.labels["leg"] ?? "—"
                let ds = durQ.first { $0.labels["host"] == cfg.host }?.value ?? 0
                var rm: [String: Double] = [:]
                for r in rtt where r.labels["host"] == cfg.host { if let l = r.labels["leg"] { rm[l] = r.value } }
                let grp = appState.monitors.filter { $0.groupName == cfg.group }
                let healthy = !grp.isEmpty && grp.allSatisfy { $0.isUp }
                let casc = appState.monitors.first { $0.groupName == "VPN Cascade" && $0.name.contains(cfg.match) }
                return Seg(host: cfg.host, title: cfg.title, activeLeg: al, activeSeconds: ds, rtt: rm,
                           txBps: txbps.first { $0.labels["host"] == cfg.host }?.value,
                           rxBps: rxbps.first { $0.labels["host"] == cfg.host }?.value,
                           healthy: healthy, cascade: casc)
            }
            legs = ["sto", "ams", "fi"].map { l in
                let host = l == "sto" ? "egress-a" : (l == "ams" ? "egress-b" : "")
                return Leg(leg: l, homeRTT: home.first { $0.labels["node"] == l }?.value,
                           txBytes: host.isEmpty ? nil : tx.first { $0.labels["host"] == host }?.value,
                           limitBytes: host.isEmpty ? nil : lim.first { $0.labels["host"] == host }?.value)
            }
            history = sw.compactMap { r -> Migration? in
                guard let f = r.labels["from"], let t = r.labels["to"], let h = r.labels["host"] else { return nil }
                return Migration(host: h, from: f, to: t, time: Date(timeIntervalSince1970: r.value))
            }.sorted { $0.time > $1.time }
            errText = nil
        } catch let e {
            errText = e.localizedDescription
        }
    }
}
