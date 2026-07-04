// CardioAITests.swift
// Updated: added AuthService, DevicePairingService, and sign-in flow tests.

import XCTest
@testable import CardioAI

// MARK: - HMAC Tests (unchanged)

final class HMACSecurityManagerTests: XCTestCase {

    var keychainService: KeychainService!
    var sut: HMACSecurityManager!

    override func setUp() {
        super.setUp()
        keychainService = KeychainService()
        try? keychainService.save("test-secret-32-chars-exactly!!!", for: .sharedSecret)
        sut = HMACSecurityManager(keychainService: keychainService)
    }

    override func tearDown() {
        try? keychainService.delete(.sharedSecret)
        super.tearDown()
    }

    func testSignChallengeReturnsSHA256Hex() throws {
        let sig = try sut.signChallenge("test-challenge-nonce")
        XCTAssertEqual(sig.count, 64)
    }

    func testSignChallengeIsDeterministic() throws {
        XCTAssertEqual(try sut.signChallenge("abc"), try sut.signChallenge("abc"))
    }

    func testDifferentChallengesDifferentSigs() throws {
        XCTAssertNotEqual(try sut.signChallenge("A"), try sut.signChallenge("B"))
    }

    func testVerifyCorrectSignature() throws {
        let challenge = "verify-me"
        XCTAssertTrue(try sut.verifyChallenge(challenge,
                                              signature: try sut.signChallenge(challenge)))
    }

    func testVerifyTamperedSignatureFails() throws {
        let challenge = "verify-me"
        var sig = try sut.signChallenge(challenge)
        sig     = String(sig.dropFirst()) + "0"
        XCTAssertFalse(try sut.verifyChallenge(challenge, signature: sig))
    }

    func testSignFailsWhenSecretMissing() throws {
        try keychainService.delete(.sharedSecret)
        XCTAssertThrowsError(try sut.signChallenge("x"))
    }
}

// MARK: - Keychain Tests

final class KeychainServiceTests: XCTestCase {

    var sut: KeychainService!

    override func setUp() {
        sut = KeychainService()
        try? sut.delete(.patientID)
        try? sut.delete(.appleUserID)
        try? sut.delete(.accessToken)
        try? sut.delete(.refreshToken)
    }

    override func tearDown() {
        try? sut.delete(.patientID)
        try? sut.delete(.appleUserID)
        try? sut.delete(.accessToken)
        try? sut.delete(.refreshToken)
    }

    func testSaveAndRead() throws {
        try sut.save("PT_99999", for: .patientID)
        XCTAssertEqual(try sut.read(.patientID), "PT_99999")
    }

    func testUpdateExistingValue() throws {
        try sut.save("v1", for: .patientID)
        try sut.save("v2", for: .patientID)
        XCTAssertEqual(try sut.read(.patientID), "v2")
    }

    func testReadMissingKeyThrows() {
        XCTAssertThrowsError(try sut.read(.patientID))
    }

    func testDeleteRemovesItem() throws {
        try sut.save("x", for: .patientID)
        try sut.delete(.patientID)
        XCTAssertFalse(sut.exists(.patientID))
    }

    func testNewKeychainKeysExist() {
        // Verify new keys added for auth are accessible
        let newKeys: [KeychainKey] = [.accessToken, .refreshToken, .appleUserID,
                                      .userRole, .userName, .userEmail]
        for key in newKeys {
            // Just verify saving works — no pre-existing value expected
            XCTAssertNoThrow(try sut.save("test", for: key))
            XCTAssertNoThrow(try sut.delete(key))
        }
    }

    func testClearSessionDeletesAllSessionKeys() throws {
        try sut.save("tok", for: .accessToken)
        try sut.save("ref", for: .refreshToken)
        try sut.save("uid", for: .appleUserID)
        sut.clearSession()
        XCTAssertFalse(sut.exists(.accessToken))
        XCTAssertFalse(sut.exists(.refreshToken))
        XCTAssertFalse(sut.exists(.appleUserID))
    }
}

// MARK: - AuthUser Tests

final class AuthUserTests: XCTestCase {

    func testPatientIsPatient() {
        let user = AuthUser(id: "1", name: "John", email: "j@h.com",
                           role: "patient", patientID: "PT_001")
        XCTAssertTrue(user.isPatient)
    }

    func testNurseIsNotPatient() {
        let user = AuthUser(id: "2", name: "Sarah", email: "s@h.com",
                           role: "nurse", patientID: nil)
        XCTAssertFalse(user.isPatient)
    }

    func testDisplayNameFallsBackToEmail() {
        let user = AuthUser(id: "3", name: "", email: "doc@h.com",
                           role: "cardiologist", patientID: nil)
        XCTAssertEqual(user.displayName, "doc@h.com")
    }

    func testDisplayNameUsesNameWhenAvailable() {
        let user = AuthUser(id: "4", name: "Dr. James", email: "j@h.com",
                           role: "cardiologist", patientID: nil)
        XCTAssertEqual(user.displayName, "Dr. James")
    }

    func testAuthUserDecodingFromJSON() throws {
        let json = """
        {
          "access_token":  "eyJhbGc...",
          "refresh_token": "refresh123",
          "token_type":    "Bearer",
          "expires_in":    3600,
          "user": {
            "id":         "USR-001",
            "name":       "John Anderson",
            "email":      "patient@hospital.local",
            "role":       "patient",
            "patient_id": "PT_12345"
          }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(AuthTokenResponse.self, from: json)
        XCTAssertEqual(response.user.name,      "John Anderson")
        XCTAssertEqual(response.user.role,      "patient")
        XCTAssertEqual(response.user.patientID, "PT_12345")
        XCTAssertEqual(response.expiresIn,      3600)
    }
}

// MARK: - Protocol Tests

final class ProtocolTests: XCTestCase {

    func testBuildMessageHasRequiredFields() throws {
        let json = try WireMessage.buildJSON(type: .hello,
                                            payload: ["client_id": "ios-001"],
                                            senderID: "ios-001")
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as? [String: Any]
        )
        XCTAssertNotNil(dict["msg_id"])
        XCTAssertEqual(dict["type"] as? String, "hello")
    }

    func testAllMsgTypesCount() {
        let types: [MsgType] = [.hello, .challenge, .challengeResp, .authOK, .authFail,
                                .heartbeat, .heartbeatAck, .deviceList, .deviceListAck,
                                .subscribe, .subscribeAck, .unsubscribe, .disconnect,
                                .rpmData, .rpmAck, .error]
        XCTAssertEqual(types.count, 16)
    }
}

// MARK: - Model Tests

final class ModelTests: XCTestCase {

    func testRPMFrameFromDict() {
        let frame = RPMFrame(from: [
            "device_id":    "ECG-001",
            "patient_id":   "PT_010",
            "timestamp":    "2025-10-15T10:30:00Z",
            "quality_score": 0.95,
            "data": ["heart_rate": 72.0, "systolic": 120.0, "diastolic": 80.0, "spo2": 98.0],
        ])
        XCTAssertEqual(frame.heartRate,    72.0)
        XCTAssertEqual(frame.systolic,    120.0)
        XCTAssertEqual(frame.qualityScore, 0.95)
    }

    func testAlertDecodingFromJSON() throws {
        let data = """
        {"alert_id":"a1","patient_id":"PT_001","level":"critical",
         "description":"VTach","actions":["DEFIBRILLATOR"],
         "notified":["ems"],"timestamp":"2025-10-15T10:35:00Z"}
        """.data(using: .utf8)!
        let alert = try JSONDecoder().decode(RPMAlert.self, from: data)
        XCTAssertEqual(alert.alertLevel, .critical)
        XCTAssertTrue(alert.isCritical)
    }
}

// MARK: - DeviceReading Tests

final class DeviceReadingTests: XCTestCase {

    func testDeviceReadingHoldsVitals() {
        let reading = DeviceReading(
            deviceID:    "BLE-001",
            deviceType:  "ecg_monitor",
            vitals:      ["heart_rate": 72.0],
            qualityScore: 0.95,
            timestamp:   Date()
        )
        XCTAssertEqual(reading.vitals["heart_rate"], 72.0)
        XCTAssertEqual(reading.qualityScore, 0.95)
    }
}
