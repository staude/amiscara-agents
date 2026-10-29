#if !os(tvOS)
import SwiftUI

/// "Vorlesen" in the header of a Claude pane (#297): read the last reply,
/// keep reading new ones, or the voice mode. Needs the host's file access,
/// the conversation comes from there; the voice mode also input.
struct AgentVoiceMenu: View {
    let voice: AgentVoice
    let connection: HostConnection
    let paneID: String
    let agentState: AgentState?
    private let panes = ReadAloudPanes.shared

    var body: some View {
        // Read here, so the toggle follows a change.
        let reads = panes.keys.contains(PromptHistory.key(host: connection.id, pane: paneID))
        return Menu {
            if voice.state == .speaking, !voice.voiceMode {
                Button("Vorlesen beenden", systemImage: "stop.fill") { voice.stop() }
            }
            Button("Letzte Antwort vorlesen", systemImage: "play.fill") {
                voice.readLast(connection: connection, paneID: paneID)
            }
            Toggle("Antworten vorlesen", systemImage: "text.badge.checkmark", isOn: Binding {
                reads
            } set: { on in
                AgentVoice.setReadsReplies(on, host: connection.id, pane: paneID)
            })
            Divider()
            if voice.voiceMode {
                Button("Sprachmodus beenden", systemImage: "stop.fill") { voice.stop() }
            } else {
                Button("Sprachmodus", systemImage: "waveform") {
                    voice.startVoiceMode(connection: connection, paneID: paneID, agentState: agentState)
                }
                .disabled(!connection.config.inputAllowed)
            }
        } label: {
            Label("Vorlesen", systemImage: voice.state == .idle ? "speaker.wave.2" : "speaker.wave.2.fill")
        }
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .disabled(!connection.config.uploadAllowed)
        .help(connection.config.uploadAllowed
            ? String(localized: "Claudes Antworten vorlesen")
            : String(localized: "Vorlesen braucht Dateizugriff wie „Bilder hochladen“ (Host bearbeiten)."))
    }
}

/// Under the header while the voice mode runs or reading failed: what the
/// voice does, what was heard, and "Stopp".
struct AgentVoiceBar: View {
    let voice: AgentVoice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(status)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .selectableText()
            Spacer()
            if voice.voiceMode {
                Button("Stopp", systemImage: "stop.fill") { voice.stop() }
            } else {
                Button("Schließen", systemImage: "xmark") { voice.error = nil }
                    .labelStyle(.iconOnly)
                    .help(String(localized: "Meldung schließen"))
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var icon: String {
        if voice.error != nil, !voice.voiceMode { return "exclamationmark.triangle" }
        return switch voice.state {
        case .listening: "mic.fill"
        case .waitingForDecision: "hand.raised"
        default: "waveform"
        }
    }

    private var status: String {
        if let error = voice.error, !voice.voiceMode { return error }
        return switch voice.state {
        case .speaking: String(localized: "Liest vor …")
        case .listening where voice.dictation.transcript.isEmpty: String(localized: "Hört zu …")
        case .listening: String(localized: "Hört zu: \(voice.dictation.transcript)")
        case .waitingForDecision: String(localized: "Claude wartet auf eine Entscheidung")
        case .waiting, .idle: String(localized: "Wartet auf Claude …")
        }
    }
}
#endif
