// New+AppSettings.swift
// ChappieCore / V2
//
// SwiftData model for global app settings (V2).
// Replaces UserDefaults keys: workspaceBookmark, lastActiveThreadId, balance_<uuid>
//
// SINGLETON PATTERN: Only one AppSettings record per container.
// Fetch with: modelContext.fetch(FetchDescriptor<New.AppSettings>()).first
// If nil — insert a new one with AppSettings().
//
// ⚠️ JSON-IN-SWIFTDATA: balancesJSON stores [String: Double] as JSON.
// NEVER rename Codable properties — stored JSON keys will break deserialization.
// Add new fields with defaults; mark old fields @available(*, deprecated) before removal.

import Foundation
import SwiftData

extension New {

    @Model
    public final class AppSettings {

        // MARK: - Stored properties

        /// Security-scoped bookmark for the workspace folder.
        /// Replaces UserDefaults key "workspaceBookmark".
        public var workspaceBookmark: Data?

        /// UUID of the thread that was active when the app was last closed.
        /// Replaces UserDefaults key "lastActiveThreadId".
        public var lastActiveThreadIdString: String?

        /// Provider balances stored as JSON: { "<providerUUID>": <balance> }.
        /// Replaces UserDefaults keys "balance_<uuid>".
        /// ⚠️ Key "providerUUID" in JSON — do NOT rename.
        public var balancesJSON: Data

        // MARK: - Init

        public init(
            workspaceBookmark: Data? = nil,
            lastActiveThreadIdString: String? = nil,
            balancesJSON: Data = Data()
        ) {
            self.workspaceBookmark = workspaceBookmark
            self.lastActiveThreadIdString = lastActiveThreadIdString
            self.balancesJSON = balancesJSON
        }

        // MARK: - Computed helpers

        /// Typed accessor for lastActiveThreadId.
        public var lastActiveThreadId: UUID? {
            get {
                guard let s = lastActiveThreadIdString else { return nil }
                return UUID(uuidString: s)
            }
            set { lastActiveThreadIdString = newValue?.uuidString }
        }

        /// Decoded balances dictionary. Returns empty dict on parse failure.
        public var balances: [String: Double] {
            get {
                guard !balancesJSON.isEmpty,
                      let dict = try? JSONDecoder().decode([String: Double].self, from: balancesJSON)
                else { return [:] }
                return dict
            }
            set {
                balancesJSON = (try? JSONEncoder().encode(newValue)) ?? Data()
            }
        }
    }
}
