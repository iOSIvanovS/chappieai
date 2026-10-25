// ImageValve.swift
// ChappieCore
//
// Emergency valve, not a policy. By decision the whole conversation keeps its images so the model can
// compare them across the history. Providers, however, reject a request that carries too many images
// or is too large overall, and that would break a long session in the middle. This turns the oldest
// images into a text note only when the count goes past a generous cap; normally it does nothing.

import Foundation

public enum ImageValve {

    /// Images allowed in one request. A downscaled image is a few hundred KB, so this stays far
    /// below the usual provider limits on total size.
    public static let maxImages = 40

    public static let placeholder = "[image omitted from context: too many images in this conversation]"

    /// Returns `messages` with the oldest images replaced by a text note when there are more than `maxImages`.
    public static func apply(_ messages: [AIMessage], maxImages: Int = ImageValve.maxImages) -> [AIMessage] {
        var total = 0
        for message in messages {
            if case .multimodal(let parts) = message.content {
                total += parts.filter(isImage).count
            }
        }
        var toDrop = total - maxImages
        guard toDrop > 0 else { return messages }

        return messages.map { message in
            guard toDrop > 0, case .multimodal(let parts) = message.content else { return message }
            var changed = false
            let newParts = parts.map { part -> AIMultimodalPart in
                guard toDrop > 0, isImage(part) else { return part }
                toDrop -= 1
                changed = true
                return .text(placeholder)
            }
            guard changed else { return message }
            var copy = message
            copy.content = .multimodal(newParts)
            return copy
        }
    }

    private static func isImage(_ part: AIMultimodalPart) -> Bool {
        if case .imageURL = part { return true }
        return false
    }
}
