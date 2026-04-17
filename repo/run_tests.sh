#!/usr/bin/env bash
# Runs the full RailCommerce XCTest suite locally via the Swift toolchain and
# prints the coverage summary at the end.
#
# Requirements:
#   * macOS host (the app targets iOS, and the Swift/Xcode toolchain is only
#     supported on macOS).
#   * Swift toolchain (`swift`) available on PATH — typically supplied by
#     Xcode Command Line Tools.
#
# This script is intentionally simple: one `swift test --enable-code-coverage`
# invocation followed by an `llvm-cov report` restricted to first-party source.
# If you need a deterministic Linux CI image, see `Dockerfile` and build it
# with `docker compose build`.
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

echo ">>> Running RailCommerce tests via 'swift test --enable-code-coverage'..."
swift test --enable-code-coverage

XCTEST_BIN=$(ls .build/debug/*.xctest/Contents/MacOS/* 2>/dev/null | head -1)
PROFDATA=".build/debug/codecov/default.profdata"

if [[ -x "${XCTEST_BIN:-}" && -f "$PROFDATA" ]]; then
    echo
    echo ">>> Code coverage (first-party source only)"
    xcrun llvm-cov report "$XCTEST_BIN" \
        -instr-profile="$PROFDATA" \
        -ignore-filename-regex=".build|Tests|RailCommerceDemo" \
        | tail -40
fi
