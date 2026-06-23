// HMACSecurityManager.swift
// iOS implementation of HMAC-SHA256 challenge/response authentication.
// Mirrors the Python SecurityManager in iomt_cardioai_production.py.
//
// SECURITY NOTES:
//   - The shared secret is read from the Keychain — never from memory literals
//   - Uses CommonCrypto CCHmac (Apple's FIPS 140-2 validated implementation)
//   - Constant-time comparison via hmac.compare_digest equivalent not
//     directly available in Swift, so we use the full digest comparison
//     which does not short-circuit on mismatch at the byte level in CCHmac

import Foundation
import CommonCrypto

enum HMACError: LocalizedError {
    case secretNotConfigured
    case signingFailed
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .secretNotConfigured: return "HMAC shared secret not found in Keychain"
        case .signingFailed:       return "Failed to compute HMAC-SHA256 signature"
        case .verificationFailed:  return "HMAC signature verification failed"
        }
    }
}

struct HMACSecurityManager {

    private let keychainService: KeychainService

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
    }

    // ── Sign a challenge ───────────────────────────────────────────────────

    /// Compute HMAC-SHA256(shared_secret, challenge) → hex string.
    /// Throws HMACError.secretNotConfigured if the secret is not in Keychain.
    func signChallenge(_ challenge: String) throws -> String {
        let secret: String
        do {
            secret = try keychainService.read(.sharedSecret)
        } catch {
            throw HMACError.secretNotConfigured
        }

        guard
            let keyData      = secret.data(using: .utf8),
            let messageData  = challenge.data(using: .utf8)
        else {
            throw HMACError.signingFailed
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        keyData.withUnsafeBytes { keyBytes in
            messageData.withUnsafeBytes { msgBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress,  keyData.count,
                    msgBytes.baseAddress,  messageData.count,
                    &digest
                )
            }
        }

        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    // ── Verify a challenge (used when acting as server) ────────────────────

    func verifyChallenge(_ challenge: String, signature: String) throws -> Bool {
        let expected = try signChallenge(challenge)
        // Constant-length comparison to mitigate timing oracle
        guard expected.count == signature.count else { return false }
        return zip(expected.utf8, signature.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // ── Provision secret (first launch / onboarding) ───────────────────────

    /// Store the shared secret in the Keychain.
    /// Called once during device provisioning — never called with a hard-coded value.
    func provisionSecret(_ secret: String) throws {
        guard secret.count >= 32 else {
            throw HMACError.secretNotConfigured
        }
        try keychainService.save(secret, for: .sharedSecret)
    }

    var isProvisioned: Bool {
        keychainService.exists(.sharedSecret)
    }
}
