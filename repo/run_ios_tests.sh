#!/usr/bin/env bash
# Runs the iOS app-layer XCTest bundle (`RailCommerceAppTests`) against an
# iOS Simulator via `xcodebuild test`. Exercises UIKit view controllers,
# SystemKeychain, SystemBattery, and AppShellFactory — code paths that
# `swift test` cannot reach on macOS because they depend on UIKit / the
# iOS Keychain entitlement.
#
# Requirements:
#   * macOS host with Xcode 16+ and at least one iOS Simulator runtime.
set -euo pipefail

PLATFORM="$(uname -s)"
if [[ "$PLATFORM" != "Darwin" ]]; then
    echo "Platform: $PLATFORM"
    echo "Error: platform not supported — iOS tests require macOS + Xcode."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

for tool in xcodebuild xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: '$tool' not found on PATH."
        echo "Install Xcode from the Mac App Store and run:"
        echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        exit 1
    fi
done

PROJECT="RailCommerceApp.xcodeproj"
SCHEME="RailCommerceApp"
PREFERRED_SIM="${SIM_NAME:-iPhone 15}"

extract_udid() {
    sed -nE 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/p' | head -1
}

pick_simulator() {
    local preferred="$1"
    local udid
    udid=$(xcrun simctl list devices available \
           | grep -E "^\s+${preferred} \(" \
           | extract_udid)
    [[ -n "${udid:-}" ]] && { echo "$udid"; return 0; }
    udid=$(xcrun simctl list devices | grep "(Booted)" | extract_udid)
    [[ -n "${udid:-}" ]] && { echo "$udid"; return 0; }
    udid=$(xcrun simctl list devices available \
           | grep -E "^\s+iPhone " | extract_udid)
    [[ -n "${udid:-}" ]] && { echo "$udid"; return 0; }
    return 1
}

SIM_UDID="$(pick_simulator "$PREFERRED_SIM" || true)"
if [[ -z "${SIM_UDID:-}" ]]; then
    echo "Error: no iOS Simulator devices found."
    echo "Open Xcode → Settings → Platforms and install an iOS runtime."
    exit 1
fi

echo ">>> Using simulator: $SIM_UDID"
DESTINATION="platform=iOS Simulator,id=${SIM_UDID}"

echo ">>> Running iOS test bundle via 'xcodebuild test'..."
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "./build" \
    -enableCodeCoverage YES

XCRESULT=$(ls -td ./build/Logs/Test/*.xcresult 2>/dev/null | head -1)
if [[ -n "${XCRESULT:-}" ]]; then
    echo
    echo ">>> iOS code coverage (targets only)"
    xcrun xccov view --only-targets --report "$XCRESULT" 2>/dev/null | head -20 || true
fi
