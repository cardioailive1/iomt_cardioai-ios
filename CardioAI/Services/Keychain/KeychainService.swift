// KeychainService.swift
// Wraps Security framework for reading/writing secrets.
// HMAC shared_secret, JWT tokens, and Apple credential data stored here —
// never in UserDefaults, never in the bundle, never logged.

import Foundation
import Security

enum KeychainKey: String {
    case sharedSecret    = "com.cardioai.iomt.shared_secret"
    case accessToken     = "com.cardioai.iomt.access_token"
    case refreshToken    = "com.cardioai.iomt.refresh_token"
    case jwtToken        = "com.cardioai.iomt.jwt_token"
    case patientID       = "com.cardioai.iomt.patient_id"
    case deviceID        = "com.cardioai.iomt.device_id"
    case appleUserID     = "com.cardioai.iomt.apple_user_id"
    case userRole        = "com.cardioai.iomt.user_role"
    case userName        = "com.cardioai.iomt.user_name"
    case userEmail       = "com.cardioai.iomt.user_email"
    case appleWatchDeviceID  = "com.cardioai.iomt.apple_watch_device_id"
    case fitbitDeviceID      = "com.cardioai.iomt.fitbit_device_id"
    case fitbitAccessToken   = "com.cardioai.iomt.fitbit_access_token"
    case fitbitRefreshToken  = "com.cardioai.iomt.fitbit_refresh_token"
    // CoreBluetooth peripheral identifier of the last-connected BLE wearable,
    // used to auto-reconnect on launch. Distinct from `deviceID`, which is the
    // backend device id and gets overwritten by whichever source registered
    // last (BLE/Watch/Fitbit). Presence also marks "should be connected" — its
    // absence tells didDisconnect a drop was user-initiated, not accidental.
    case blePeripheralID     = "com.cardioai.iomt.ble_peripheral_id"
}

enum KeychainError: LocalizedError {
    case itemNotFound
    case duplicateItem
    case unexpectedData
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:            return "Keychain item not found"
        case .duplicateItem:           return "Keychain item already exists"
        case .unexpectedData:          return "Unexpected data format in Keychain"
        case .unhandledError(let s):   return "Keychain error: OSStatus \(s)"
        }
    }
}

final class KeychainService {

    // MARK: - Write

    func save(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     "com.cardioai.iomt",
            kSecAttrAccount:     key.rawValue,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateQuery: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: "com.cardioai.iomt",
                kSecAttrAccount: key.rawValue,
            ]
            let attributes: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary,
                                             attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.unhandledError(status: addStatus)
        }
    }

    // MARK: - Read

    func read(_ key: KeychainKey) throws -> String {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  "com.cardioai.iomt",
            kSecAttrAccount:  key.rawValue,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? KeychainError.itemNotFound
                : KeychainError.unhandledError(status: status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }

    // MARK: - Delete

    func delete(_ key: KeychainKey) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "com.cardioai.iomt",
            kSecAttrAccount: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    func exists(_ key: KeychainKey) -> Bool {
        (try? read(key)) != nil
    }

    // MARK: - Clear all (sign out)

    func clearSession() {
        let sessionKeys: [KeychainKey] = [
            .accessToken, .refreshToken, .jwtToken,
            .patientID, .appleUserID, .userRole, .userName, .userEmail
        ]
        sessionKeys.forEach { try? delete($0) }
    }
}
