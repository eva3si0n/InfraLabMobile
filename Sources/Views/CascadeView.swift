import SwiftUI

/// VPN Cascade — богатая панель состояния egress-каскада.
/// Данные из Prometheus через Grafana datasource-прокси (appState.promInstant):
/// активное плечо + сколько держится, RTT до плеч (с узла и из дома), throughput WG,
/// месячный трафик Vultr STO/AMS против лимита 2 ТБ.
struct CascadeView: View {
    @EnvironmentObject var appState: AppState

    struct Seg: Identifiable {
        let id = UUID(); let host, label, activeLeg: String
        let activeSeconds: Double; let rtt: [String: Double]; let txbps, rxbps: Double?
    }
    struct Leg: Identifiable {
        let id = UUID(); let leg: String
        let homeRTT, txBytes, limitBytes: Double?
    }

    @State private var segments: [Seg] = []
    @State private var legs: [Leg] = []
    @State private var loading = false
    @State private var errText: String?

    var body: some View {
        NavigationStack {
            Group {
                if appState.grafanaBaseURL.isEmpty {
                    ContentUnavailableView("Grafana Not Configured", systemImage: "arrow.triangle.branch",
                        description: Text("Set Grafana URL in Settings"))
                } else if segments.isEmpty && loading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = errText, segments.isEmpty {
                    ContentUnavailableView("Failed to Load", systemImage: "exclamationmark.triangle", description: Text(e))
                } else {
                    list
                }
            }
            .navigationTitle("VPN Cascade")
            .toolbar { if loading { ToolbarItem(placement: .topBarTrailing) { ProgressView() } } }
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            ForEach(segments) { s in
                Section("\(s.label) · \(s.host)") {
                    HStack {
                        Text("Активное плечо").font(.subheadline)
                        Spacer()
                        legBadge(s.activeLeg)
                        Text(fmtDur(s.activeSeconds)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let tx = s.txbps, let rx = s.rxbps {
                        HStack {
                            Text("Throughput WG").font(.subheadline)
                            Spacer()
                            Text("↑\(fmtBps(tx))  ↓\(fmtBps(rx))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(["sto", "ams", "fi"], id: \.self) { l in
                        HStack {
                            Text("RTT " + l.uppercased()).font(.subheadline)
                            Spacer()
                            if let r = s.rtt[l] { Text("\(Int(r.rounded())) ms").font(.subheadline.monospacedDigit()) }
                            else { Text("—").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("Egress-плечи · из дома / трафик за месяц") {
                ForEach(legs) { lg in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            legBadge(lg.leg)
                            Spacer()
                            if let h = lg.homeRTT { Text("дом → \(Int(h.rounded())) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
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
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    @ViewBuilder private func legBadge(_ l: String) -> some View {
        let c: Color = l == "sto" ? .green : (l == "ams" ? .orange : (l == "fi" ? .red : .secondary))
        Text(l.uppercased())
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(c.opacity(0.2)).foregroundStyle(c).clipShape(Capsule())
    }

    private func fmtDur(_ s: Double) -> String {
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h)ч \(m)м" : "\(m)м"
    }
    private func fmtBps(_ bytesPerSec: Double) -> String {
        let bits = bytesPerSec * 8; var v = bits; let u = ["bps", "Kbps", "Mbps", "Gbps"]; var i = 0
        while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
        return String(format: "%.1f %@", v, u[i])
    }
    private func fmtBytes(_ b: Double) -> String {
        var v = b; let u = ["B", "KB", "MB", "GB", "TB"]; var i = 0
        while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
        return String(format: "%.1f %@", v, u[i])
    }

    private func load() async {
        guard !appState.grafanaBaseURL.isEmpty else { return }
        loading = true; defer { loading = false }
        do {
            let active = try await appState.promInstant("vpn_egress_active_leg == 1", legend: "")
            let durQ  = try await appState.promInstant("vpn_egress_active_seconds", legend: "")
            let rtt   = try await appState.promInstant("vpn_leg_rtt_ms", legend: "")
            let txbps = try await appState.promInstant("sum by (host) (rate(wireguard_sent_bytes[5m]))", legend: "")
            let rxbps = try await appState.promInstant("sum by (host) (rate(wireguard_received_bytes[5m]))", legend: "")
            let home  = try await appState.promInstant("home_node_rtt_ms", legend: "")
            let tx    = try await appState.promInstant("vds_month_tx_bytes", legend: "")
            let lim   = try await appState.promInstant("vds_month_limit_bytes", legend: "")

            var segs: [Seg] = []
            for (h, label) in [("node-a", "Проводной"), ("node-b", "Мобильный")] {
                let al = active.first { $0.labels["host"] == h }?.labels["leg"] ?? "—"
                let ds = durQ.first { $0.labels["host"] == h }?.value ?? 0
                var rm: [String: Double] = [:]
                for r in rtt where r.labels["host"] == h { if let l = r.labels["leg"] { rm[l] = r.value } }
                let t = txbps.first { $0.labels["host"] == h }?.value
                let rr = rxbps.first { $0.labels["host"] == h }?.value
                segs.append(Seg(host: h, label: label, activeLeg: al, activeSeconds: ds, rtt: rm, txbps: t, rxbps: rr))
            }
            var lgs: [Leg] = []
            for l in ["sto", "ams", "fi"] {
                let hr = home.first { $0.labels["node"] == l }?.value
                let host = l == "sto" ? "egress-a" : (l == "ams" ? "egress-b" : "")
                let mtx = host.isEmpty ? nil : tx.first { $0.labels["host"] == host }?.value
                let ml = host.isEmpty ? nil : lim.first { $0.labels["host"] == host }?.value
                lgs.append(Leg(leg: l, homeRTT: hr, txBytes: mtx, limitBytes: ml))
            }
            segments = segs; legs = lgs; errText = nil
        } catch let e {
            errText = e.localizedDescription
        }
    }
}
