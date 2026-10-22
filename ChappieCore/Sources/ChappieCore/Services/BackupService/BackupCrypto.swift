// BackupCrypto.swift
// ChappieCore
//
// Password-based encryption for the full export bundle.
//
// WHY ENCRYPT THE WHOLE FILE (not just API key secrets):
// Simpler UX — one password unlocks everything. Also avoids leaking structural
// metadata (provider names, thread titles, memory contents) in a "mostly plaintext"
// backup file sitting on disk or in cloud sync.
//
// SCHEME:
// PBKDF2-HMAC-SHA256 (310_000 iterations, OWASP 2023 baseline) derives a 256-bit key
// from the user's password + random salt. AES-256-GCM then encrypts the JSON payload
// with authentication (tamper-evident — wrong password or corrupted file fails to open).
//
// WHY MANUAL PBKDF2 INSTEAD OF CommonCrypto:
// CommonCrypto requires a bridging header / system library target in SwiftPM — adds
// build complexity for one function. PBKDF2 is trivially built from CryptoKit's
// HMAC<SHA256>, which is already available as a pure Swift system framework import.
//
// FILE FORMAT (all binary, no JSON wrapper — payload is already encrypted bytes):
//   magic (5 bytes: "CHBK1") | salt (16 bytes) | AES-GCM combined (nonce+ciphertext+tag)

import Foundation
import CryptoKit

// MARK: - BackupCryptoError

public enum BackupCryptoError: LocalizedError {
    case invalidFormat
    case wrongPasswordOrCorrupted

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "This file is not a valid Chappie backup."
        case .wrongPasswordOrCorrupted:
            return "Wrong password, or the backup file is corrupted."
        }
    }
}

// MARK: - BackupCrypto

public enum BackupCrypto {

    private static let magic: [UInt8] = Array("CHBK1".utf8)
    private static let saltLength = 16
    private static let pbkdf2Iterations = 310_000
    private static let derivedKeyLength = 32 // 256-bit AES key

    // MARK: - Public API

    /// Encrypts arbitrary plaintext data with a user-supplied password.
    public static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let salt = randomBytes(count: saltLength)
        let key = try deriveKey(password: password, salt: salt)
        let sealedBox = try AES.GCM.seal(plaintext, using: key)

        var output = Data(magic)
        output.append(salt)
        output.append(sealedBox.combined!)
        return output
    }

    /// Decrypts data produced by `encrypt(_:password:)`. Throws on wrong password or corruption.
    public static func decrypt(_ data: Data, password: String) throws -> Data {
        guard data.count > magic.count + saltLength else { throw BackupCryptoError.invalidFormat }
        guard data.prefix(magic.count).elementsEqual(magic) else { throw BackupCryptoError.invalidFormat }

        let saltRange = magic.count..<(magic.count + saltLength)
        let salt = data.subdata(in: saltRange)
        let combined = data.subdata(in: (magic.count + saltLength)..<data.count)

        let key = try deriveKey(password: password, salt: salt)

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw BackupCryptoError.wrongPasswordOrCorrupted
        }
    }

    // MARK: - Key Derivation (PBKDF2-HMAC-SHA256, built on CryptoKit primitives)

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let derived = pbkdf2SHA256(
            password: passwordData,
            salt: salt,
            iterations: pbkdf2Iterations,
            keyLength: derivedKeyLength
        )
        return SymmetricKey(data: derived)
    }

    /// Standard PBKDF2 (RFC 8018) using HMAC-SHA256 as the pseudorandom function.
    private static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let hashLength = SHA256.Digest.byteCount
        let blockCount = Int(ceil(Double(keyLength) / Double(hashLength)))
        let key = SymmetricKey(data: password)

        var derived = Data()
        derived.reserveCapacity(blockCount * hashLength)

        for blockIndex in 1...blockCount {
            var blockIndexBE = UInt32(blockIndex).bigEndian
            var salted = salt
            withUnsafeBytes(of: &blockIndexBE) { salted.append(contentsOf: $0) }

            var u = Data(HMAC<SHA256>.authenticationCode(for: salted, using: key))
            var block = u

            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in 0..<block.count { block[i] ^= u[i] }
                }
            }

            derived.append(block)
        }

        return derived.prefix(keyLength)
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
