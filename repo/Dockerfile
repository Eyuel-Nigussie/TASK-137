# RailCommerce — Linux Swift image that runs the portable-library test suite.
#
# Why Docker cannot build the *iOS app* (UIKit + Realm + Keychain +
# MultipeerConnectivity):
#
#   1. The Xcode toolchain is not available on Linux. Apple ships xcodebuild,
#      xcrun, the iOS SDK, and the Darwin-slice Swift compiler only inside
#      Xcode, which is macOS-only. No apt/yum/apk package exists.
#   2. iOS Simulator depends on Apple's private CoreSimulator.framework —
#      also macOS-only.
#   3. Docker Desktop on Mac still runs a Linux VM; a Linux guest cannot
#      host macOS frameworks.
#   4. Apple's EULA forbids running macOS VMs on non-Apple hardware.
#
# What this container CAN do:
#
#   The portable `RailCommerce` Swift library has zero UIKit, zero Realm
#   on Linux (gated behind `.when(platforms: [.iOS])`), and zero Darwin-
#   only APIs after the `#if canImport(Darwin)` gate on file-protection
#   options. So on Linux we can compile `RailCommerce` + its XCTest
#   bundle and run **every** one of the 605 XCTest cases inside the
#   container.
#
#   `docker compose up` invokes `swift test --enable-code-coverage` and
#   exits non-zero on any test failure — this is the Docker-contained
#   test workflow documented in README.md.
FROM swift:5.10-jammy AS base

RUN apt-get update \
 && apt-get install -y --no-install-recommends make ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy manifest first for best Docker layer caching.
COPY Package.swift ./

# Copy sources + tests. The iOS-only `RailCommerceApp` target compiles to
# an empty module on Linux because every file is gated by
# `#if canImport(UIKit)`; the Swift Package also gates its RealmSwift
# product dependency behind `platforms: [.iOS]`, so Realm's Objective-C
# resource bundle is never pulled in.
COPY Sources ./Sources
COPY Tests ./Tests

# Pre-build library + test bundle so the runtime `swift test` step is
# cache-warm. Bare `swift build` resolves the whole package graph; the
# iOS-only targets compile to empty modules on Linux and the Linux-
# incompatible dependencies (Realm) are never linked.
RUN swift build -c debug --build-tests

# Default command: run the full XCTest suite with coverage enabled.
# Exits non-zero on any failure so `docker compose up` fails loudly when
# a regression lands. This is the Docker-contained test workflow.
CMD ["swift", "test", "--enable-code-coverage"]
