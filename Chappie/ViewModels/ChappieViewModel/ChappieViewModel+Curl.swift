// ChappieViewModel+Curl.swift
// Chappie
//
// Curl-Chappie secret values: the project sheet hands over typed values on Save and they
// go straight to the Keychain. Metadata (names, kinds, hosts) travels the normal
// ProjectSettings path; values never do, so they cannot end up in the thread database,
// logs or a backup.

import Foundation
import ChappieCore

extension ChappieViewModel {

    func commitCurlSecrets(
        _ secrets: [CurlSecret],
        typed: [UUID: [CurlSecretField: String]],
        removed: [CurlSecret]
    ) {
        let ok = CurlSecretKeychain().apply(secrets: secrets, typed: typed, removed: removed)
        // Log only the outcome — never names of fields with values, never values.
        print("[ChappieViewModel] Curl secrets committed: \(secrets.count) kept, \(removed.count) removed, ok=\(ok)")
    }
}
