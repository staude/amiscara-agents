import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few places where macOS and iOS differ.
enum Platform {
    /// Whether this device can reach a herdr socket on itself.
    static var hasLocalSocket: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Default path of the local herdr socket; empty on iOS.
    static var localSocketPath: String {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/herdr/herdr.sock").path
        #else
        ""
        #endif
    }

    /// Shown in the comment of generated keys, e.g. "herdr-remote Franks iPad".
    @MainActor
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    @MainActor
    static var defaultTerminalFontSize: Double {
        #if os(macOS)
        12
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? 9 : 11
        #endif
    }
}

extension View {
    /// Host names, users and paths: no capitals, no autocorrect.
    func technicalInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
