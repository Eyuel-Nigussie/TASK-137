# RailCommerce iOS — API Specification

## No External APIs

This is a **fully offline, standalone iOS application**. There are:

- No REST APIs
- No HTTP endpoints
- No server connections
- No WebSocket channels
- No third-party service integrations
- No backend server

All data is stored on-device. All computation (catalog filtering, cart math, promotions, checkout, seat reservation, after-sales, content publishing, messaging, talent matching, membership) runs locally on the device. The application does not make any internet requests.

The only network traffic is Apple `MultipeerConnectivity` peer-to-peer messaging over local Wi-Fi / Bluetooth / AWDL for offline staff coordination. This does not leave the local network.

## Data Persistence

- **Database**: Realm (encrypted, on-device)
- **Secrets**: iOS Keychain
- **Files**: App sandbox (`Documents/attachments/`)
- **Encryption**: AES-256 (Realm) + SHA-256 attachment integrity hash

## Authentication

- Local username + password (PBKDF2-SHA256, no server auth)
- Optional Face ID / Touch ID (device-local biometrics)
- Session managed entirely in-memory + Keychain
