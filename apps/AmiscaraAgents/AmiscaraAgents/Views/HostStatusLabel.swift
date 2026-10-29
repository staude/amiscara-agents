import SwiftUI

/// Compact connection state for a host. A button, because iPad and iPhone
/// show no tooltips: tapping opens the state, the full error and a way to
/// reconnect right away.
struct HostStatusLabel: View {
    let connection: HostConnection
    @State private var showDetails = false

    var body: some View {
        if connection.isLive && connection.startError == nil {
            EmptyView()
        } else {
            Button {
                showDetails = true
            } label: {
                if connection.vpnDown {
                    vpnBadge
                } else {
                    icon
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            #if os(tvOS)
            .sheet(isPresented: $showDetails) {
                HostStatusDetails(connection: connection) { showDetails = false }
            }
            #else
            .popover(isPresented: $showDetails) {
                HostStatusDetails(connection: connection) { showDetails = false }
            }
            #endif
        }
    }

    /// NetBird is off on this device, so the host cannot answer (#305).
    private var vpnBadge: some View {
        Label("VPN aus", systemImage: "network.slash")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private var icon: some View {
        if connection.startError != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else {
            switch connection.status {
            case .live:
                EmptyView()
            case .connecting, nil:
                ProgressView().controlSize(.mini)
            case .retrying:
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            case .hostKeyUnknown, .hostKeyChanged:
                Image(systemName: "key.fill").foregroundStyle(.orange)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private var summary: String {
        connection.vpnDown ? String(localized: "VPN aus") : connection.statusSummary
    }
}

private struct HostStatusDetails: View {
    let connection: HostConnection
    let close: () -> Void
    @State private var notInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(connection.config.name).font(.headline)
            Text(connection.statusSummary)
            if connection.vpnDown {
                Text(connection.vpnHint).font(.callout)
            }
            if notInstalled {
                Text("NetBird ist auf diesem Gerät nicht installiert.").font(.callout).foregroundStyle(.red)
            }
            if let detail = connection.statusDetail {
                Text(detail)
                    .font(.system(.callout, design: .monospaced))
                    .selectableText()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = connection.statusHint {
                Text(hint).font(.callout)
            }
            HStack {
                Spacer()
                #if !os(tvOS)
                if connection.config.behindNetBird {
                    Button("NetBird öffnen", systemImage: "network") {
                        Task {
                            if await NetBirdMonitor.shared.open() { close() } else { notInstalled = true }
                        }
                    }
                }
                #endif
                Button("Jetzt verbinden", systemImage: "arrow.clockwise") {
                    connection.start()
                    close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 420)
        .presentationCompactAdaptation(.popover)
    }
}

private extension HostConnection {
    var vpnHint: String {
        #if os(macOS)
        String(localized: "NetBird ist auf diesem Gerät nicht verbunden. Im Symbol der Menüleiste „Connect“ wählen.")
        #else
        String(localized: "NetBird ist auf diesem Gerät nicht verbunden.")
        #endif
    }
}

extension HostConnection {
    /// The host sits behind NetBird, which is off here (#305).
    var vpnDown: Bool {
        #if os(tvOS)
        false
        #else
        config.behindNetBird && NetBirdMonitor.shared.isUp == false && !isLive
        #endif
    }

    var statusSummary: String {
        if startError != nil { return String(localized: "Verbindung kann nicht starten") }
        switch status {
        case .live: return String(localized: "Verbunden")
        case .connecting, nil: return String(localized: "Verbinde …")
        case .retrying(let attempt, _): return String(localized: "Verbindung fehlgeschlagen, Versuch \(attempt). Die App versucht es weiter.")
        case .hostKeyUnknown: return String(localized: "Host-Key muss bestätigt werden")
        case .hostKeyChanged: return String(localized: "Host-Key hat sich geändert")
        case .failed: return String(localized: "Anmeldung abgelehnt")
        }
    }

    /// The raw error, as reported by the core.
    var statusDetail: String? {
        if let startError { return startError }
        switch status {
        case .retrying(_, let error), .failed(let error): return error
        case .hostKeyUnknown(_, let fingerprint), .hostKeyChanged(_, let fingerprint): return fingerprint
        default: return nil
        }
    }

    /// A pointer for the usual causes.
    var statusHint: String? {
        if vpnDown { return nil }
        switch status {
        case .retrying(_, let error):
            let lower = error.lowercased()
            if lower.contains("timed out") || lower.contains("timeout") || lower.contains("unreachable")
                || lower.contains("no route") || lower.contains("lookup") || lower.contains("resolve") {
                return String(localized: "Der Rechner ist nicht erreichbar. Läuft das VPN (NetBird) auf diesem Gerät, und stimmt der Hostname?")
            }
            if lower.contains("refused") {
                return String(localized: "Der Rechner lehnt die Verbindung ab. Ist SSH (Entfernte Anmeldung) dort eingeschaltet?")
            }
            if lower.contains("channel") || lower.contains("no such file") {
                return String(localized: "SSH klappt, aber der herdr-Socket nicht. Läuft herdr dort, und stimmt der Socket-Pfad?")
            }
            return nil
        case .failed:
            return String(localized: "Steht die Schlüsselzeile dieses Geräts in ~/.ssh/authorized_keys auf dem Rechner?")
        default:
            return nil
        }
    }
}
