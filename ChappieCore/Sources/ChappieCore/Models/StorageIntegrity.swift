// StorageIntegrity.swift
// ChappieCore
//
// Value types describing damaged or unsaved data, shown to the user instead of being swallowed.

import Foundation

// MARK: - StorageIntegrityIssue

/// Something unreadable was found in storage. A backup copy of the raw bytes already exists.
public struct StorageIntegrityIssue: Sendable, Identifiable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// The whole thread list could not be parsed; the app starts from an empty list.
        case threadListUnreadable
        /// Some threads were readable and kept; `lostCount` entries could not be read.
        case threadListPartial(lostCount: Int)
    }

    public let id: UUID
    public let kind: Kind
    /// Storage key of the backup copy of the damaged data.
    public let backupKey: String

    public init(id: UUID = UUID(), kind: Kind, backupKey: String) {
        self.id = id
        self.kind = kind
        self.backupKey = backupKey
    }
}

// MARK: - LossyElement

/// Decodes one array element without failing the whole array when this element is damaged.
struct LossyElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
