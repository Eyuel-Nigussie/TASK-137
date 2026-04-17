#!/usr/bin/env bash
# Builds and launches the RailCommerce iOS app on an iOS Simulator.
#
# Requirements:
#   * macOS host (iOS apps only build/run on macOS).
#   * Xcode installed with at least one iOS Simulator runtime.
#
# Usage: ./start.sh
#   Environment overrides:
#     SIM_NAME    Preferred simulator device name (default: iPhone 15).
#                 If the preferred device is not installed, falls back to
#                 the first already-booted iOS simulator, then to the first
#                 available iPhone device reported by `xcrun simctl list`.
set -euo pipefail

PLATFORM="$(uname -s)"
if [[ "$PLATFORM" != "Darwin" ]]; then
    echo "Platform: $PLATFORM"
    echo "Skipping: this is an iOS app. Building and launching requires macOS"
    echo "          + Xcode + iOS Simulator, none of which are available on"
    echo "          $PLATFORM. Exiting cleanly (exit 0) so CI on non-Mac"
    echo "          hosts is not marked as failed — there is no iOS toolchain"
    echo "          to invoke here. Run on macOS to build and launch the app."
    exit 0
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
CONFIGURATION="Debug"
PREFERRED_SIM="${SIM_NAME:-iPhone 15}"

# Extract the first UUID from a line like:
#     iPhone 17 (D465F861-1089-4627-959D-F171163E503F) (Booted)
extract_udid() {
    sed -nE 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/p' | head -1
}

pick_simulator() {
    local preferred="$1"
    local udid

    # 1. Exact preferred device name, from available iOS runtimes.
    udid=$(xcrun simctl list devices available \
           | grep -E "^\s+${preferred} \(" \
           | extract_udid)
    if [[ -n "${udid:-}" ]]; then echo "$udid"; return 0; fi

    # 2. First currently-booted simulator (runtime filter not required — if it
    #    is booted and simctl reports it, it is usable).
    udid=$(xcrun simctl list devices \
           | grep "(Booted)" \
           | extract_udid)
    if [[ -n "${udid:-}" ]]; then echo "$udid"; return 0; fi

    # 3. Any available iPhone device.
    udid=$(xcrun simctl list devices available \
           | grep -E "^\s+iPhone " \
           | extract_udid)
    if [[ -n "${udid:-}" ]]; then echo "$udid"; return 0; fi

    return 1
}

SIM_UDID="$(pick_simulator "$PREFERRED_SIM" || true)"
if [[ -z "${SIM_UDID:-}" ]]; then
    echo "Error: no iOS Simulator devices found."
    echo "Open Xcode → Settings → Platforms and install an iOS runtime, or run:"
    echo "    xcodebuild -downloadPlatform iOS"
    exit 1
fi

echo ">>> Using simulator: $SIM_UDID"
DESTINATION="platform=iOS Simulator,id=${SIM_UDID}"

echo ">>> Building $SCHEME ($CONFIGURATION)..."
# Simulator builds use ad-hoc signing ("-", "Sign to Run Locally") so they
# work on fresh clones with no configured developer team. Fully disabling
# signing would strip entitlements and break Keychain-backed runtime code
# on the simulator, so we use "-" instead of "" and leave signing allowed.
# CODE_SIGN_STYLE=Manual prevents Xcode from trying to contact Apple to
# provision a team profile.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "./build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build

APP_BUNDLE=$(find "./build/Build/Products" -maxdepth 3 -name "$SCHEME.app" -type d | head -1)
if [[ -z "${APP_BUNDLE:-}" || ! -d "$APP_BUNDLE" ]]; then
    echo "Error: could not locate built app bundle under ./build/Build/Products."
    exit 1
fi
echo ">>> Built app: $APP_BUNDLE"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Info.plist")
echo ">>> Bundle identifier: $BUNDLE_ID"

echo ">>> Booting Simulator.app (idempotent)..."
open -a Simulator
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null

echo ">>> Installing app..."
xcrun simctl install "$SIM_UDID" "$APP_BUNDLE"

echo ">>> Launching $BUNDLE_ID..."
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"

echo ">>> RailCommerce is running on simulator $SIM_UDID."
