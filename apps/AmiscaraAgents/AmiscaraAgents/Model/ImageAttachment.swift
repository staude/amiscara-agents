import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image waiting to be uploaded with the next prompt.
struct ImageAttachment: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    /// File extension for the upload, e.g. `jpg`.
    let fileExtension: String
    let preview: CGImage?

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
