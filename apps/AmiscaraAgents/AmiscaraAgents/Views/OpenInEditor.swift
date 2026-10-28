#if os(macOS)
import AppKit
import SwiftUI

/// Opens a folder of a host in VS Code (#288): over Remote-SSH with the
/// host's SSH target, directly for this Mac. Returns the error to show.
@MainActor
func openInVSCode(_ path: String?, on connection: HostConnection) -> String? {
    guard let path else { return String(localized: "Für diese Pane ist kein Ordner bekannt.") }
    guard let url = connection.editorURL(path: path) else {
        return String(localized: "Ungültige Adresse: \(path)")
    }
    return NSWorkspace.shared.open(url) ? nil : String(localized: "VS Code ist nicht installiert.")
}

/// "In VS Code öffnen" for a pane or a space, with the working directory
/// of the pane or of the space's focused pane.
struct OpenInVSCodeButton: View {
    enum Target {
        case pane(String)
        case space(String)
    }

    let connection: HostConnection
    let target: Target
    @Binding var error: String?

    var body: some View {
        Button("In VS Code öffnen", systemImage: "chevron.left.forwardslash.chevron.right") {
            Task {
                let folder = switch target {
                case .pane(let paneID): await connection.paneFolder(paneID)
                case .space(let workspaceID): await connection.spaceFolder(workspaceID)
                }
                error = openInVSCode(folder, on: connection)
            }
        }
    }
}

extension View {
    /// The alert for a failed "In VS Code öffnen".
    func editorErrorAlert(_ error: Binding<String?>) -> some View {
        alert("In VS Code öffnen fehlgeschlagen", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}
#endif
