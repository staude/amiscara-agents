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
