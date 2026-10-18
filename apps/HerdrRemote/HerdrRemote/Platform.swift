import SwiftUI
import UniformTypeIdentifiers

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

    #if os(macOS)
    /// Whether ⌘V in the composer should attach images rather than insert
    /// text: the clipboard holds image files, or image data without plain
    /// text. Text wins when both are there (e.g. copied from Pages), so text
    /// paste keeps working.
    @MainActor
    static var clipboardHasImages: Bool {
        let board = NSPasteboard.general
        if !imageFileURLs(on: board).isEmpty { return true }
        let types = board.types ?? []
        let hasImage = types.contains { UTType($0.rawValue)?.conforms(to: .image) == true }
        return hasImage && !types.contains(.string)
    }
    #endif

    /// The clipboard's contents as item providers, for the explicit
    /// "paste image" action. On iOS reading them may ask for permission.
    @MainActor
    static func clipboardItems() -> [NSItemProvider] {
        #if os(macOS)
        let board = NSPasteboard.general
        let files = imageFileURLs(on: board).compactMap { NSItemProvider(contentsOf: $0) }
        if !files.isEmpty { return files }
        return (board.pasteboardItems ?? []).compactMap { item in
            // First image type the item offers, PNG before TIFF as written.
            guard let type = item.types.lazy.compactMap({ UTType($0.rawValue) }).first(where: { $0.conforms(to: .image) }),
                  let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier))
            else { return nil }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(for: type, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        #else
        UIPasteboard.general.itemProviders
        #endif
    }

    #if os(macOS)
    /// Image files copied in the Finder.
    private static func imageFileURLs(on board: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
    #endif

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
