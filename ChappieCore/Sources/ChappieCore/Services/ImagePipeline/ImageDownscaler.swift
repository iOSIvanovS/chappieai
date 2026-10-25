// ImageDownscaler.swift
// ChappieCore
//
// THE one place where an image becomes something that is sent to a model.
// Providers bill an image by its pixels, not its bytes, and a model cannot use more detail than
// ~2000 px of the long side anyway. So every image is capped at that size and re-encoded as JPEG:
// a 10 MB screenshot becomes a few hundred KB and the request stays light, while the original file
// is never touched.
//
// Any new code path that puts an image into a request must go through `dataURI(...)`.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ImageDownscaler {

    // MARK: - Tuning

    /// Longest side of an image sent to a model, in pixels.
    public static let maxLongSide = 2000

    /// Images already within `maxLongSide` and not bigger than this are sent untouched.
    public static let passThroughBytes = 1_500_000

    public static let jpegQuality = 0.85
    public static let jpegMimeType = "image/jpeg"

    // MARK: - Result

    public struct Output: Sendable {
        public let data: Data
        public let mimeType: String
        /// True when the bytes were re-encoded (resized, flattened, or rotated), false when passed through.
        public let reencoded: Bool
    }

    // MARK: - Core

    /// Prepares image bytes for a request. Returns nil when the data cannot be decoded and is too
    /// big to send raw.
    public static func prepare(_ data: Data, mimeType: String) -> Output? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = imageInfo(of: source) else {
            // Undecodable: a small file may still be valid for the provider, a large one is not worth the risk.
            return data.count <= passThroughBytes
                ? Output(data: data, mimeType: mimeType, reencoded: false)
                : nil
        }

        let alreadySmall = max(info.width, info.height) <= maxLongSide
        if alreadySmall, data.count <= passThroughBytes, info.orientation <= 1 {
            return Output(data: data, mimeType: mimeType, reencoded: false)
        }

        guard let jpeg = encodeJpeg(from: source, longSide: max(info.width, info.height)) else {
            return data.count <= passThroughBytes
                ? Output(data: data, mimeType: mimeType, reencoded: false)
                : nil
        }
        return Output(data: jpeg, mimeType: jpegMimeType, reencoded: true)
    }

    /// `data:<mime>;base64,<...>` for image bytes, or nil when they cannot be prepared.
    public static func dataURI(for data: Data, mimeType: String) -> String? {
        prepare(data, mimeType: mimeType).map(uri)
    }

    /// Same for a file. When `cacheURL` is given, a re-encoded copy is stored there and reused while
    /// the original is not newer, so rebuilding the history does not re-encode the same image
    /// on every request. The original file is never modified.
    public static func dataURI(forFileAt url: URL, mimeType: String, cacheURL: URL? = nil) -> String? {
        if let cacheURL,
           let cacheDate = modificationDate(cacheURL),
           let originalDate = modificationDate(url),
           cacheDate >= originalDate,
           let cached = try? Data(contentsOf: cacheURL) {
            return uri(Output(data: cached, mimeType: jpegMimeType, reencoded: true))
        }

        guard let data = try? Data(contentsOf: url),
              let output = prepare(data, mimeType: mimeType) else { return nil }

        if output.reencoded, let cacheURL {
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? output.data.write(to: cacheURL, options: .atomic)
        }
        return uri(output)
    }

    // MARK: - Internals

    private static func uri(_ output: Output) -> String {
        "data:\(output.mimeType);base64,\(output.data.base64EncodedString())"
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private struct ImageInfo {
        let width: Int
        let height: Int
        /// EXIF orientation, 1 = upright. 0 when absent.
        let orientation: Int
    }

    private static func imageInfo(of source: CGImageSource) -> ImageInfo? {
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
        return ImageInfo(width: width, height: height, orientation: orientation)
    }

    /// Thumbnail at `min(longSide, maxLongSide)` (never upscaled, EXIF rotation applied), flattened on
    /// white because JPEG has no alpha, then encoded. For an animated GIF only the first frame is used.
    private static func encodeJpeg(from source: CGImageSource, longSide: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longSide, maxLongSide)
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: thumb.width, height: thumb.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(thumb, in: rect)
        guard let flat = context.makeImage() else { return nil }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, flat,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
