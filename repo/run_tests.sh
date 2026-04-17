#!/usr/bin/env bash
# Runs the FULL RailCommerce test suite locally via the Swift/Xcode toolchain.
#
# Executes both layers in one invocation:
#   1. `swift test --enable-code-coverage` — the portable library XCTest suite
#      with line + region + function coverage reporting.
#   2. `xcodebuild test` against an iOS Simulator — the iOS UIKit app-layer
#      XCTest bundle (view controllers, SystemKeychain, transport, shells)
#      that cannot be exercised by `swift test` because it needs UIKit.
#
# Requirements:
#   * macOS host (iOS apps build/test only on macOS).
#   * Xcode 16+ with at least one iOS 16+ Simulator runtime installed.
#
# Non-macOS hosts: the platform guard prints a `Skipping:` block and exits 0
# so CI on non-Darwin hosts is not marked as failed — iOS tooling does not
# exist on those hosts.
set -euo pipefail

PLATFORM="$(uname -s)"
if [[ "$PLATFORM" != "Darwin" ]]; then
    echo "Platform: $PLATFORM"
    echo "Skipping: this is an iOS project. The full XCTest suite requires"
    echo "          macOS + Xcode, which is unavailable on $PLATFORM."
    echo "          Exiting cleanly (exit 0) — there is nothing to run here."
    echo "          Run on macOS to execute all tests."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: 'swift' not found on PATH. Install Xcode or the Command"
    echo "Line Tools via:  xcode-select --install"
    exit 1
fi
for tool in xcodebuild xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: '$tool' not found on PATH. Install Xcode from the Mac"
        echo "App Store and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        exit 1
    fi
done

############################
# 1. Library XCTest via swift test
############################
echo ">>> [1/2] Running library tests via 'swift test --enable-code-coverage'..."
swift test --enable-code-coverage

XCTEST_BIN=$(ls .build/debug/*.xctest/Contents/MacOS/* 2>/dev/null | head -1)
PROFDATA=".build/debug/codecov/default.profdata"
if [[ -x "${XCTEST_BIN:-}" && -f "$PROFDATA" ]]; then
    echo
    echo ">>> Library coverage (first-party source only)"
    xcrun llvm-cov report "$XCTEST_BIN" \
        -instr-profile="$PROFDATA" \
        -ignore-filename-regex=".build|Tests|RailCommerceDemo" \
        | tail -40
fi

############################
# 2. iOS app-layer XCTest via xcodebuild test
############################
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
           | grep -E "^\s+${preferred} \(" | extract_udid)
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
    echo "Error: no iOS Simulator devices found. Open Xcode → Settings →"
    echo "Platforms and install an iOS runtime."
    exit 1
fi
echo
echo ">>> [2/2] Running iOS app-layer tests via 'xcodebuild test' on simulator $SIM_UDID..."
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=${SIM_UDID}" \
    -derivedDataPath "./build" \
    -enableCodeCoverage YES

XCRESULT=$(ls -td ./build/Logs/Test/*.xcresult 2>/dev/null | head -1)
if [[ -n "${XCRESULT:-}" ]]; then
    echo
    echo ">>> iOS code coverage (target summary)"
    xcrun xccov view --only-targets --report "$XCRESULT" 2>/dev/null | head -20 || true
fi

echo
echo ">>> All tests passed (library + iOS app-layer)."
