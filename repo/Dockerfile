# RailCommerce — Linux-capable Docker image.
# The library and its tests are pure Swift + Foundation, so the same code compiles
# on macOS and Linux. This image is used by build.sh / run.sh / run_tests.sh and
# gives the CI environment everything it needs without relying on host tooling.
FROM swift:5.10-jammy AS base

# Minimal runtime deps (llvm-cov ships inside the Swift toolchain already).
RUN apt-get update \
 && apt-get install -y --no-install-recommends make ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy manifest first for best Docker layer caching.
COPY Package.swift ./

# Copy sources + tests.
COPY Sources ./Sources
COPY Tests ./Tests

# Pre-build the library, the demo executable and the test bundle so subsequent
# `swift test` / `swift run` invocations are cache-warm.
RUN swift build -c debug \
 && swift build -c debug --build-tests \
 && swift build -c release --product RailCommerceDemo

# Default: run the demo CLI (what "the app on the emulator" reduces to in a
# headless Linux container — iOS Simulator itself requires macOS + Xcode).
CMD ["swift", "run", "-c", "release", "RailCommerceDemo"]
