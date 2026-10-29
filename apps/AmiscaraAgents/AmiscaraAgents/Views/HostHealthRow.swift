import SwiftUI

#if !os(tvOS)
/// The host's health under the dashboard's counts (#306): load, memory,
/// disk, uptime and herdr version as small tiles, read every 60 seconds
/// from the host script `amiscara-health` while the dashboard is open.
/// Without the script, or with a key line from before it, a hint says
/// what to do instead.
struct HostHealthRow: View {
    let connection: HostConnection
    @State private var status: HealthStatus?

    /// How often the values are read again.
    private static let interval: Duration = .seconds(60)

    var body: some View {
        Group {
            switch status {
            case .ready(let health):
                tiles(health)
            case .scriptMissing:
                hint("Für die Werte des Hosts das Script amiscara-health nach ~/.amiscara-agents/bin/ kopieren und ausführbar machen.")
            case .keyLineOld:
                hint("Für die Werte des Hosts die neue Schlüsselzeile (Host bearbeiten) auf dem Host eintragen.")
            case nil:
                EmptyView()
            }
        }
        // Again once the connection is back, not only after the interval.
        .task(id: "\(connection.id) \(connection.isLive)") {
            await poll()
        }
    }

    /// Reads until the view goes away. A hint ends it, since the host
    /// needs a change by hand; a failed reading keeps the last values.
    private func poll() async {
        while !Task.isCancelled {
            if connection.isLive, let next = try? await connection.health() {
                status = next
                switch next {
                case .ready: break
                case .scriptMissing, .keyLineOld: return
                }
            }
            try? await Task.sleep(for: Self.interval)
        }
    }

    private func tiles(_ health: Health) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 6) {
            if let load = health.load1 {
                HealthTile(
                    title: String(localized: "Last"),
                    value: load.formatted(.number.precision(.fractionLength(2))),
                    detail: health.cpus.map { String(localized: "\(Int($0)) Kerne") },
                    warn: health.cpus.map { load >= Double($0) } ?? false
                )
            }
            if let used = health.memUsed, let total = health.memTotal, total > 0 {
                HealthTile(
                    title: String(localized: "Speicher"),
                    value: (Double(used) / Double(total)).formatted(.percent.precision(.fractionLength(0))),
                    detail: String(localized: "\(bytes(used, .memory)) von \(bytes(total, .memory))"),
                    warn: false
                )
            }
            if let free = health.diskFree {
                let share = health.diskTotal.flatMap { $0 > 0 ? Double(free) / Double($0) : nil }
                HealthTile(
                    title: String(localized: "Platte"),
                    value: bytes(free, .file),
                    detail: share.map { String(localized: "\($0.formatted(.percent.precision(.fractionLength(0)))) frei") },
                    warn: share.map { $0 < 0.1 } ?? false
                )
            }
            if let uptime = health.uptime {
                HealthTile(
                    title: String(localized: "Laufzeit"),
                    value: Duration.seconds(Int64(clamping: uptime))
                        .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)),
                    detail: health.os,
                    warn: false
                )
            }
            if let version = connection.update?.serverVersion {
                HealthTile(title: "herdr", value: version, detail: nil, warn: false)
            }
        }
        .padding(.bottom, 8)
    }

    private func bytes(_ count: UInt64, _ style: ByteCountFormatStyle.Style) -> String {
        Int64(clamping: count).formatted(.byteCount(style: style))
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
    }
}

/// One value of `HostHealthRow`: title, value and a line below.
private struct HealthTile: View {
    let title: String
    let value: String
    let detail: String?
    /// Orange: the value needs attention.
    let warn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(warn ? Color.orange : Color.primary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(warn ? Color.orange : Color.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.fill.quaternary, in: .rect(cornerRadius: 8))
    }
}
#endif
