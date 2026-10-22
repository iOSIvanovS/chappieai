// BackupCryptoTests.swift
// ChappieCoreTests
//
// Verifies the password-based encryption scheme used for settings export/import.

import Testing
import Foundation
@testable import ChappieCore

@Suite("BackupCrypto")
struct BackupCryptoTests {

    @Test("Round-trip: encrypt then decrypt with correct password returns original data")
    func roundTrip() throws {
        let plaintext = Data("{\"hello\":\"world\"}".utf8)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "correct horse battery staple")
        let decrypted = try BackupCrypto.decrypt(encrypted, password: "correct horse battery staple")
        #expect(decrypted == plaintext)
    }

    @Test("Decrypting with wrong password throws wrongPasswordOrCorrupted")
    func wrongPassword() throws {
        let plaintext = Data("secret payload".utf8)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "right-password")

        #expect(throws: BackupCryptoError.wrongPasswordOrCorrupted) {
            _ = try BackupCrypto.decrypt(encrypted, password: "wrong-password")
        }
    }

    @Test("Decrypting a non-backup file throws invalidFormat")
    func invalidFormat() throws {
        let garbage = Data("this is not a chappie backup".utf8)

        #expect(throws: BackupCryptoError.invalidFormat) {
            _ = try BackupCrypto.decrypt(garbage, password: "anything")
        }
    }

    @Test("Decrypting truncated data throws invalidFormat")
    func truncatedData() throws {
        let tooShort = Data([0x43, 0x48, 0x42, 0x4B, 0x31]) // just the magic bytes

        #expect(throws: BackupCryptoError.invalidFormat) {
            _ = try BackupCrypto.decrypt(tooShort, password: "anything")
        }
    }

    @Test("Two encryptions of the same plaintext produce different ciphertexts (random salt+nonce)")
    func nonDeterministic() throws {
        let plaintext = Data("same input".utf8)
        let first = try BackupCrypto.encrypt(plaintext, password: "pw")
        let second = try BackupCrypto.encrypt(plaintext, password: "pw")
        #expect(first != second)
    }

    @Test("Large payload (simulating a real export bundle) round-trips correctly")
    func largePayload() throws {
        let plaintext = Data(repeating: 0x5A, count: 500_000)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "migration-password")
        let decrypted = try BackupCrypto.decrypt(encrypted, password: "migration-password")
        #expect(decrypted == plaintext)
    }
}
