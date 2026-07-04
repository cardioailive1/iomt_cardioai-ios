# IoMT CardioAI — iOS App v1.1.0

Real-time cardiac monitoring iOS client.
Patients sign in with Apple ID, pair their BLE wearable device,
and stream live vitals into the 7-agent AI backend.

---

## What's New in v1.1.0

- **Sign in with Apple** — patients authenticate with their Apple ID
- **BLE Device Pairing** — Bluetooth scanning, connection, and live data streaming
- **Live Vitals Dashboard** — real-time HR, BP, SpO₂ from paired device
- **Role-based UI** — patients see their own data only
- **Auto token refresh** — silent JWT rotation, no re-login needed
- **Apple credential state check** — detects revoked Apple IDs on cold launch

---

## Requirements

| Requirement | Minimum |
|---|---|
| iOS | 17.0+ |
| Xcode | 15.0+ |
| Swift | 5.9+ |
| Backend | iomt_cardioai_production.py with auth endpoints |

---

## Project Structure

```
CardioAI/
├── CardioAIApp.swift                    Entry point, session restore on launch
├── Auth/
│   └── AuthService.swift               Sign in with Apple + token lifecycle
├── Core/
│   ├── DependencyContainer.swift       DI container (all singletons)
│   ├── AppConfiguration.swift          Info.plist config
│   └── Stores.swift                    SwiftUI observable stores
├── Network/
│   ├── Protocol/Protocol.swift         Wire protocol (16 MsgTypes)
│   ├── WebSocket/BridgeClient.swift    HMAC handshake + injectLocalFrame()
│   └── REST/APIClient.swift            Auth + device + dashboard endpoints
├── Security/
│   └── HMACSecurityManager.swift       CommonCrypto HMAC-SHA256
├── Models/
│   └── Models.swift                    Swift DTOs (AuthUser, DeviceReading, etc.)
├── Services/
│   ├── Keychain/KeychainService.swift  All secrets (accessToken, refreshToken, etc.)
│   ├── Health/
│   │   ├── DevicePairingService.swift  BLE scan → pair → stream → backend
│   │   └── HealthKitService.swift      Apple Health write-back
│   ├── Notifications/
│   │   └── NotificationService.swift  Critical alert push notifications
│   └── Background/                    BGTask scheduler
├── UI/
│   ├── Auth/SignInView.swift           Apple Sign In screen
│   ├── DevicePairing/
│   │   └── DevicePairingView.swift    BLE scan + pair + live readings
│   ├── Dashboard/DashboardView.swift   Live vitals + device sync status
│   ├── Alerts/AlertsView.swift        Alert list + detail
│   ├── Devices/DevicesView.swift       Device registry
│   ├── Settings/SettingsView.swift     Account, sign out, credentials
│   ├── RootView.swift                  Auth state machine
│   └── MainTabView.swift               5-tab bar (+ Connect tab)
└── Supporting Files/Info.plist         Bluetooth + HealthKit + background modes
```

---

## Patient Flow

```
App Launch
    │
    ▼
restoreSession()
    ├─ Apple credential revoked? → SignInView
    ├─ No Keychain tokens?       → SignInView
    └─ Tokens found              → Silent JWT refresh → Dashboard
    │
    ▼
SignInView  (Sign in with Apple)
    │
    ▼
POST /auth/apple  (backend verifies Apple token, issues JWT pair)
    │
    ▼
Onboarding  (IT provisions HMAC secret — one time only)
    │
    ▼
MainTabView  (5 tabs)
    ├── Dashboard   — live vitals, connection status
    ├── Connect     — BLE scan → pair → "LIVE" indicator
    ├── Alerts      — cardiac alerts with severity
    ├── Devices     — registered device list
    └── Settings    — account info, sign out, credentials

Connect Tab Flow:
    Tap "Scan for Devices"
        → BLE scan for CardioAI service UUIDs
        → Patient selects device from list
        → BLE connect → service/characteristic discovery
        → POST /devices/register (backend)
        → BLE notifications start
        → Each reading → BridgeClient.injectLocalFrame()
        → rpmDataSubject → Dashboard live update
        → Same frame → WebSocket → 7-agent AI pipeline
```

---

## Setup

### 1. Backend URLs (Xcode Scheme)

Edit Scheme → Run → Environment Variables:

| Variable | Debug | Release |
|---|---|---|
| `CARDIOAI_WS_URL` | `wss://localhost:8765` | `wss://cardioai.hospital.local/stream` |
| `CARDIOAI_API_URL` | `https://localhost:8080` | `https://cardioai.hospital.local/api` |
| `CARDIOAI_CLIENT_ID` | `ios-debug-001` | `ios-prod-001` |
| `CARDIOAI_ENVIRONMENT` | `development` | `production` |

### 2. Xcode Capabilities (Signing & Capabilities)

Enable all of:
- **Sign in with Apple**
- **HealthKit**
- **Background Modes** (Bluetooth Central, Processing, Remote Notifications)
- **Push Notifications** (+ Critical Alerts entitlement)
- **Keychain Sharing**

### 3. Backend: Add `/auth/apple` endpoint

The backend needs one additional endpoint not in the original production file.
Add to `iomt_cardioai_production.py` inside `build_http_app()`:

```python
async def apple_signin(request):
    body = await request.json()
    identity_token     = body.get("identity_token")
    authorization_code = body.get("authorization_code")
    first_name         = body.get("first_name", "")
    last_name          = body.get("last_name", "")

    # Verify the Apple identity token with Apple's servers
    # In production: use python-jose or authlib to verify the JWT
    # against Apple's public keys at https://appleid.apple.com/auth/keys
    # For development, decode without verification:
    import base64, json as _json
    parts   = identity_token.split(".")
    payload = _json.loads(base64.b64decode(parts[1] + "=="))
    apple_user_id = payload.get("sub")
    email         = payload.get("email", f"{apple_user_id[:8]}@privaterelay.appleid.com")
    name          = f"{first_name} {last_name}".strip() or "Patient"

    # Create or load user
    user = _load_user_by_email(email) or HospitalUser(
        id=apple_user_id, email=email, name=name,
        role=UserRole.PATIENT, patient_id=apple_user_id,
        password_hash="", is_active=True,
    )
    access_token  = _issue_access_token(user, cfg)
    refresh_token = _REFRESH_STORE.issue(user.id, cfg.refresh_token_ttl)
    return _web.json_response({
        "access_token":  access_token,
        "refresh_token": refresh_token,
        "token_type":    "Bearer",
        "expires_in":    cfg.token_ttl_seconds,
        "user": {"id": user.id, "name": user.name,
                 "email": user.email, "role": user.role.value,
                 "patient_id": user.patient_id},
    })

app.router.add_post("/auth/apple", apple_signin)
```

### 4. BLE Device UUIDs

Update `CardioAIBLEService` in `DevicePairingService.swift` with your hardware's
actual GATT service and characteristic UUIDs:

```swift
enum CardioAIBLEService {
    static let primaryService = CBUUID(string: "YOUR-SERVICE-UUID")
    // ...
}
```

---

## Security

| Layer | Implementation |
|---|---|
| Sign in | Apple ID via ASAuthorizationAppleIDCredential |
| WS auth | HMAC-SHA256 challenge/response (CommonCrypto) |
| Session | JWT access (1h) + refresh token (7d, rotated) |
| Storage | iOS Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Network | TLS (wss:// + https://) |
| BLE | System Bluetooth framework, no raw radio access |
| Credential revoke | Apple credential state checked on every cold launch |

---

## Version

**1.1.0** · iOS 17+ · Xcode 15+ · Swift 5.9
