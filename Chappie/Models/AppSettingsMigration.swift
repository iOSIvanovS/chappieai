// AppSettingsMigration.swift
// Chappie
//
// SwiftData schema definition.
// StoredRecord is the only @Model. Schema is frozen — no migrations ever needed.

import Foundation
import SwiftData
import ChappieCore

enum AppSettingsSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [StoredRecord.self]
    }
}
