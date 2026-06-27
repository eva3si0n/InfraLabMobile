import SwiftUI

struct MonitorsView: View {
    @EnvironmentObject var appState: AppState
    @State private var expanded: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if appState.kumaBaseURL.isEmpty || appState.kumaSlug.isEmpty {
                    ContentUnavailableView(
                        "Kuma Not Configured",
                        systemImage: "dot.radiowaves.up.forward",
                        description: Text("Add Uptime Kuma URL and slug in Settings")
                    )
                } else if appState.monitors.isEmpty && appState.monitorsLoading {
                    ProgressView("Loading monitors…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.monitorsError, appState.monitors.isEmpty {
                    ContentUnavailableView(
                        "Failed to Load",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Monitors")
            .toolbar {
                if appState.monitorsLoading {
                    ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                }
            }
        }
    }

    // Preserve the status-page group order (Dictionary grouping would lose it).
    private var orderedGroups: [(name: String, monitors: [MonitorStatus])] {
        var order: [String] = []
        var map: [String: [MonitorStatus]] = [:]
        for m in appState.monitors {
            if map[m.groupName] == nil { order.append(m.groupName) }
            map[m.groupName, default: []].append(m)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var list: some View {
        List {
            ForEach(orderedGroups, id: \.name) { group in
                Section {
                    if expanded.contains(group.name) {
                        ForEach(group.monitors) { MonitorRow(monitor: $0) }
                    }
                } header: {
                    GroupHeader(
                        name: group.name,
                        monitors: group.monitors,
                        isExpanded: expanded.contains(group.name)
                    ) { toggle(group.name) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await appState.refreshMonitors() }
    }

    private func toggle(_ name: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
        }
    }
}

struct GroupHeader: View {
    let name: String
    let monitors: [MonitorStatus]
    let isExpanded: Bool
    let onTap: () -> Void

    private var up: Int { monitors.filter(\.isUp).count }
    private var total: Int { monitors.count }
    private var allUp: Bool { up == total }
    private var dotColor: Color { allUp ? .green : (up == 0 ? .red : .orange) }

    // Aggregate heartbeat rollup: for each time slot, down if ANY child check was down.
    private var aggregateBeats: [KumaHeartbeat] {
        let lists = monitors.map(\.recentBeats).filter { !$0.isEmpty }
        guard !lists.isEmpty else { return [] }
        let n = lists.map(\.count).max() ?? 0
        var result: [KumaHeartbeat] = []
        for d in 0..<n {
            var present = false, anyDown = false
            for list in lists where list.count > d {
                present = true
                if list[list.count - 1 - d].status == 0 { anyDown = true }
            }
            if present {
                result.append(KumaHeartbeat(status: anyDown ? 0 : 1, ping: nil, time: ""))
            }
        }
        return result.reversed()   // oldest → newest
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Circle()
                        .fill(dotColor)
                        .frame(width: 9, height: 9)
                        .shadow(color: dotColor.opacity(0.6), radius: 3)

                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(up)/\(total)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(allUp ? .green : .orange)
                }

                if !aggregateBeats.isEmpty {
                    KumaHeartbeatBar(beats: aggregateBeats)
                        .frame(height: 14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

struct MonitorRow: View {
    let monitor: MonitorStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.isUp ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(monitor.name)
                    .font(.subheadline)

                Spacer()

                if let ms = monitor.latency {
                    Text("\(ms) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !monitor.recentBeats.isEmpty {
                KumaHeartbeatBar(beats: monitor.recentBeats)
                    .frame(height: 24)
            }

            // Kuma's status-page heartbeat endpoint only exposes 24h uptime ({id}_24).
            Label("\(uptimeText(monitor.uptime24h)) · 24h", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func uptimeText(_ ratio: Double) -> String {
        String(format: "%.2f%%", ratio * 100)
    }
}

/// Kuma-style heartbeat bar: discrete rounded bars (green=up, red=down,
/// orange=pending, blue=maintenance) spread across the full row width.
struct KumaHeartbeatBar: View {
    let beats: [KumaHeartbeat]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(beats.enumerated()), id: \.offset) { _, beat in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(color(for: beat.status))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func color(for status: Int) -> Color {
        switch status {
        case 1: return Color(red: 0.36, green: 0.84, blue: 0.55)   // up
        case 0: return Color(red: 0.86, green: 0.24, blue: 0.30)   // down
        case 2: return Color(red: 0.97, green: 0.65, blue: 0.20)   // pending
        case 3: return Color(red: 0.27, green: 0.55, blue: 0.95)   // maintenance
        default: return Color.gray.opacity(0.35)
        }
    }
}
