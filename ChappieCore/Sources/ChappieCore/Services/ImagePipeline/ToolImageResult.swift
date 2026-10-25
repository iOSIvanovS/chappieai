// ToolImageResult.swift
// ChappieCore
//
// A tool result that is text PLUS pictures (an Office document with images inside).
// A tool result is a String, and providers only accept images inside a user-role message, so the
// pair travels behind a marker: `execute` returns `encoded()`, and whoever consumes the result
// (AIOrchestrator for tool calls, the ViewModel for attached documents) calls `decode`.
//
// Only tools in ToolExecutionService.documentImageTools may return it, and the text is judged by
// OutputGuard as usual: the pictures are bounded by the image pipeline, not by the text limit.

import Foundation

public struct ToolImageResult: Codable, Sendable, Equatable {

    public struct Image: Codable, Sendable, Equatable {
        /// What the model is told about this picture, e.g. "image 2: word/media/image2.png".
        public let label: String
        /// Downscaled `data:` URI.
        public let dataURI: String

        public init(label: String, dataURI: String) {
            self.label = label
            self.dataURI = dataURI
        }
    }

    public static let marker = "__CHAPPIE_DOC_IMAGES__:"
    /// More than the extractor ever produces; a bound for anything that merely imitates the marker.
    public static let maxImages = 20

    public let text: String
    public let images: [Image]

    public init(text: String, images: [Image]) {
        self.text = text
        self.images = images
    }

    /// The marker form, or just the text when there is no picture to carry.
    public func encoded() -> String {
        guard !images.isEmpty, let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return text }
        return Self.marker + json
    }

    /// Nil for anything that is not a well-formed marker result (then it is plain text).
    public static func decode(_ result: String) -> ToolImageResult? {
        guard result.hasPrefix(marker),
              let data = String(result.dropFirst(marker.count)).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolImageResult.self, from: data),
              !decoded.images.isEmpty else { return nil }
        return ToolImageResult(text: decoded.text, images: Array(decoded.images.prefix(maxImages)))
    }

    /// Text of a result that may or may not carry pictures.
    public static func plainText(of result: String) -> String {
        decode(result)?.text ?? result
    }

    /// Parts for a user-role message that shows the pictures to the model, each introduced by its label.
    public var multimodalParts: [AIMultimodalPart] {
        images.flatMap { [AIMultimodalPart.text($0.label), AIMultimodalPart.imageURL($0.dataURI)] }
    }
}
