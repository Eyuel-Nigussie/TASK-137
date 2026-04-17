#!/usr/bin/env bash
# Runs the full RailCommerce XCTest suite locally via the Swift toolchain.
#
# Requirements:
#   * macOS host (the app targets iOS, and the Swift/Xcode toolchain is only
#     supported on macOS).
#   * Swift toolchain (`swift`) available on PATH — typically supplied by
#     Xcode Command Line Tools.
#
# This script is intentionally simple: one `swift test` invocation. If you
# need a deterministic Linux CI image, see `Dockerfile` and build it with
# `docker compose build`.
set -euo pipefail

PLATFORM="$(uname -s)"
if [[ "$PLATFORM" != "Darwin" ]]; then
    echo "Platform: $PLATFORM"
    echo "Error: platform not supported — this app requires macOS (or iOS) to run tests."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: 'swift' not found on PATH."
    echo "Install Xcode (from the App Store) or Xcode Command Line Tools via:"
    echo "    xcode-select --install"
    exit 1
fi

echo ">>> Running RailCommerce tests via 'swift test'..."
swift test
