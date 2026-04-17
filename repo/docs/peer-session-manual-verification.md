# Peer-Session Manual Verification Checklist

Multipeer messaging has two surfaces that cannot be proven by XCTest alone:
the real `MCNearbyServiceBrowser` / `MCNearbyServiceAdvertiser` handshake and
the iOS Local Network permission dialog. This checklist walks through the
real-device scenarios that close the gap left by the static test suite.

Static coverage (for reference): sender-spoof rejection is pinned by
`Tests/RailCommerceAppTests/MultipeerSpoofRejectionTests.swift` (8 tests);
harassment filter, attachment-size cap, SSN / card / email PII scrubbing, and
block + report flows are pinned by `InboundMessagingValidationTests.swift`
and `ReportControlTests.swift`. The items below are explicitly what those
unit tests cannot exercise.

## Prerequisites

- Two iOS devices on the same Wi-Fi SSID (or Bluetooth proximity).
- Both devices signed in under distinct `User` identities.
- Local Network permission **not yet granted** on at least one device (delete
  and reinstall if previously granted, to exercise the first-run prompt).

## 1. First-run Local Network prompt

1. Launch the app on Device A.
2. Open the messaging shell.
3. **Expected**: the system "\"RailCommerce\" Would Like to Find and Connect
   to Devices on Your Local Network" dialog appears on the first discovery
   attempt. Deny it once.
4. **Expected**: peer discovery produces zero connections; no crash.
5. Re-open the shell; grant the permission via Settings → Privacy & Security
   → Local Network → RailCommerce.
6. **Expected**: discovery resumes without an app restart.

## 2. Bonded-device pairing dialog

1. With permission granted on both devices, invite Device B from Device A.
2. **Expected**: Device B shows the MultipeerConnectivity invitation alert
   with Device A's displayName.
3. Accept on Device B.
4. **Expected**: both devices show connected-peers count = 1 within ~2s.

## 3. Discovery latency sanity check

1. Background Device A (lock screen), then foreground it again.
2. **Expected**: Device A re-advertises, Device B re-discovers within ~5s.
3. Move Device A out of Wi-Fi range. Wait 10s.
4. **Expected**: connected-peers count falls to 0 on Device B; no UI lockup.

## 4. Pair drop / reconnect

1. While connected, disable Wi-Fi on Device A.
2. **Expected**: Device B sees the peer drop within ~5s.
3. Re-enable Wi-Fi on Device A.
4. **Expected**: the peers automatically reconnect; no app-level restart is
   required.

## 5. Spoofed-peer rejection at the Multipeer seam

This corresponds to the static tests in `MultipeerSpoofRejectionTests.swift`
but on real hardware. The unit tests already prove the runtime guard; this
step confirms no Multipeer-layer edge path bypasses it.

1. Use two devices signed in as `alice` and `eve`.
2. From `eve`, attempt to craft an outbound payload whose `Message.fromUserId`
   is `alice` (e.g. by intercepting the transport at the debugger).
3. **Expected**: the receiving side drops the message — it does not appear in
   the visible message list. Audit log should contain the
   `inbound dropped spoof` entry.

## 6. Harassment auto-block on a real session

1. Send 3 harassment-flagged messages from Device A to Device B within a
   single session (use a string that matches `HarassmentFilter.isHarassing`,
   such as the canonical unit-test sample).
2. **Expected**: the 3rd message triggers an auto-block. Subsequent messages
   from A do not appear on B's visible list.

## 7. Attachment-size cap at the transport seam

1. Send an attachment larger than `MessagingService.maxAttachmentBytes`
   (check the source for the current value).
2. **Expected**: the message is dropped on the receiver side with an
   audit-log `inbound dropped attachmentTooLarge` entry.

---

## Reporting

If any step above deviates from expected behaviour, file a bug with:

- iOS version on each device
- Multipeer transport (Wi-Fi vs Bluetooth) inferred from `MCSession.connectedPeers`
- Device log excerpt showing the failing audit line
- A link to the static test that is the runtime analogue

Static tests are authoritative for the code-path boundary. This checklist is
strictly for the runtime surfaces (dialogs, latency, pairing state) that only
exist on real hardware.
