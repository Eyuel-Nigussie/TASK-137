#!/bin/bash
# Build + launch the RailCommerceApp on an iOS Simulator.
#
# Invoked by the top-level start.sh. Kept separate so start.sh stays a
# trivial platform guard + dispatcher, mirroring the working pattern used
# by other native-iOS projects.
#
# Key design decisions:
#   * NO -derivedDataPath override — Xcode uses its default
#     ~/Library/Developer/Xcode/DerivedData/ location, which is outside
#     ~/Documents. Documents-folder clones otherwise hit codesign failures
#     because macOS (Spotlight / iCloud / Gatekeeper) continuously stamps
#     files under Documents with xattrs that codesign rejects:
#         "resource fork, Finder information, or similar detritus not allowed"
#     Letting Xcode build in its standard DerivedData location sidesteps
#     the issue entirely.
#   * Ad-hoc signing (CODE_SIGN_IDENTITY="-") + manual style so fresh
#     clones with no configured Apple developer team still build and run.
set -euo pipefail

# Resolve the repo root one level up from this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

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

    # 2. First currently-booted simulator.
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

# Strip xattrs defensively on the source tree. Harmless if there are none.
xattr -cr . 2>/dev/null || true

echo ">>> Building $SCHEME ($CONFIGURATION)..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build

# Read the built app path from Xcode's build settings so we don't depend
# on guessing the DerivedData hash directory.
BUILT_PRODUCTS_DIR=$(xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {print $2; exit}')

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || ! -d "$BUILT_PRODUCTS_DIR" ]]; then
    echo "Error: could not determine BUILT_PRODUCTS_DIR from xcodebuild."
    exit 1
fi

APP_BUNDLE="$BUILT_PRODUCTS_DIR/$SCHEME.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Error: built app bundle not found at $APP_BUNDLE"
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
