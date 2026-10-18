import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image or file waiting to be uploaded with the next prompt. Images are
/// prepared for agents (format, size); other files go up unchanged.
struct ImageAttachment: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    /// File extension for the upload, e.g. `jpg`.
    let fileExtension: String
    let preview: CGImage?
    /// Shown for a file that is no image.
    var fileName: String?

    /// Formats agents read directly; everything else becomes JPEG.
    private static let passThrough: [UTType] = [.png, .jpeg, .gif, .webP]
    /// Above this, images are scaled down (Claude reads up to about 5 MB).
    private static let maxBytes = 4_000_000
    private static let maxPixels = 2560

    /// Prepares picked image data. Returns `nil` for data that is no image.
    static func make(data: Data, type: UTType?) -> ImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let preview = thumbnail(source, maxPixels: 240)

        if let type, let kept = passThrough.first(where: { type.conforms(to: $0) }),
           data.count <= maxBytes {
            return ImageAttachment(
                data: data,
                fileExtension: kept.preferredFilenameExtension ?? "png",
                preview: preview
            )
        }
        // HEIC from the camera roll, TIFF, oversized images: JPEG, scaled down.
        guard let image = thumbnail(source, maxPixels: maxPixels),
              let jpeg = encodeJPEG(image)
        else { return nil }
        return ImageAttachment(data: jpeg, fileExtension: "jpg", preview: preview)
    }

    /// Largest file other than an image that goes up as it is.
    private static let maxFileBytes = 20_000_000
    /// Text from a clipping up to this length goes into the prompt itself,
    /// longer text is attached as a .txt file.
    private static let maxInlineText = 2000

    /// What a picked or dropped file becomes.
    enum Content: Sendable {
        case attachment(ImageAttachment)
        /// Text for the prompt, e.g. from a text clipping.
        case text(String)
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                String(localized: "\(name) lässt sich nicht lesen.")
            case .tooLarge(let name):
                String(localized: "\(name) ist größer als 20 MB.")
            }
        }
    }

    /// Any file as it is, uploaded under its own name (`file-…-<name>`), so
    /// any extension or none works.
    static func file(data: Data, name: String) throws -> ImageAttachment {
        guard data.count <= maxFileBytes else { throw Failure.tooLarge(name) }
        var attachment = ImageAttachment(data: data, fileExtension: (name as NSString).pathExtension, preview: nil)
        attachment.fileName = name
        return attachment
    }

    /// A file's content: an image prepared like a picked photo, the text of
    /// a text clipping, anything else as it is.
    static func content(data: Data, name: String) throws -> Content {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .image) == true, let image = make(data: data, type: type) {
            return .attachment(image)
        }
        if (name as NSString).pathExtension.lowercased() == "textclipping" {
            guard let text = clippingText(data) else { throw Failure.unreadable(name) }
            if text.count <= maxInlineText { return .text(text) }
            let base = (name as NSString).deletingPathExtension
            return .attachment(try file(data: Data(text.utf8), name: "\(base).txt"))
        }
        return .attachment(try file(data: data, name: name))
    }

    static func content(fileAt url: URL) throws -> Content {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url.lastPathComponent) }
        return try content(data: data, name: url.lastPathComponent)
    }

    #if !os(tvOS)
    /// Something dropped on the composer: a file (Finder, the screenshot
    /// thumbnail, Files on the iPad) or image data from another app.
    @MainActor
    static func content(dropped provider: NSItemProvider) async throws -> Content {
        let fallbackName = provider.suggestedName ?? String(localized: "Die Datei")
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL { return try content(fileAt: url) }
        }
        if provider.registeredContentTypes.contains(where: { $0.conforms(to: .image) }) {
            guard let image = await make(from: provider) else { throw Failure.unreadable(fallbackName) }
            return .attachment(image)
        }
        // A file without a URL (e.g. from Files on the iPad): a temporary
        // copy, readable only inside the callback.
        guard let type = provider.registeredContentTypes.first else { throw Failure.unreadable(fallbackName) }
        let suggested = provider.suggestedName
        let result: Result<Content, Error> = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type) { url, _, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: .failure(Failure.unreadable(fallbackName)))
                    return
                }
                let name = suggested.map { url.pathExtension.isEmpty ? $0 : "\($0).\(url.pathExtension)" } ?? url.lastPathComponent
                continuation.resume(returning: Result { try content(data: data, name: name) })
            }
        }
        return try result.get()
    }
    #endif

    /// The text in a Finder text clipping: a property list whose `UTI-Data`
    /// holds the dragged text under its type.
    private static func clippingText(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["UTI-Data"] as? [String: Any]
        else { return nil }
        for key in ["public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text"] {
            if let text = items[key] as? String { return text }
            if let data = items[key] as? Data {
                let encoding: String.Encoding = key.contains("utf16") ? .utf16 : .utf8
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return nil
    }

    /// Prepares an image from a paste or drop. Prefers a format agents read
    /// directly (PNG before the TIFF macOS screenshots also carry).
    @MainActor
    static func make(from provider: NSItemProvider) async -> ImageAttachment? {
        let images = provider.registeredContentTypes.filter { $0.conforms(to: .image) }
        let preferred = images.first { type in passThrough.contains { type.conforms(to: $0) } }
        guard let type = preferred ?? images.first else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        return make(data: data, type: type)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Image data from a paste, with the format it came in. Representations
/// are listed in order of preference, so a macOS screenshot that carries
/// PNG and TIFF arrives as PNG and is uploaded unchanged.
struct PastedImage: Transferable, Sendable {
    let data: Data
    let type: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .png) { PastedImage(data: $0, type: .png) }
        DataRepresentation(importedContentType: .jpeg) { PastedImage(data: $0, type: .jpeg) }
        DataRepresentation(importedContentType: .gif) { PastedImage(data: $0, type: .gif) }
        DataRepresentation(importedContentType: .webP) { PastedImage(data: $0, type: .webP) }
        DataRepresentation(importedContentType: .heic) { PastedImage(data: $0, type: .heic) }
        DataRepresentation(importedContentType: .image) { PastedImage(data: $0, type: .image) }
    }
}
