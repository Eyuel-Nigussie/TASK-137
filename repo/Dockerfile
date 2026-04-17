# RailCommerce — Linux-capable build image.
#
# Used only for `docker compose build` to produce a deterministic image of
# the portable `RailCommerce` Swift library and the `RailCommerceDemo` CLI.
# The local iOS app and tests are built/run on macOS directly (see
# `start.sh` and `run_tests.sh`) — this image exists solely as a
# portable-library parity check.
FROM swift:5.10-jammy AS base

RUN apt-get update \
 && apt-get install -y --no-install-recommends make ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy manifest first for best Docker layer caching.
COPY Package.swift ./

# Copy sources + tests.
COPY Sources ./Sources
COPY Tests ./Tests

# Pre-build the library + demo so subsequent invocations are cache-warm.
RUN swift build -c debug \
 && swift build -c release --product RailCommerceDemo
