# RailCommerce — Linux-compatible build image.
#
# The **iOS app itself cannot run in Docker** (iOS Simulator is macOS-only;
# see README.md → "Why Docker Cannot Run This App"). What this image DOES
# provide:
#
#   * A compiled build of the portable `RailCommerce` Swift library.
#   * The `RailCommerceDemo` CLI that drives every service end-to-end so
#     Linux CI can verify the core business logic.
#
# The `RailCommerceApp` target (UIKit + Realm) is intentionally NOT built
# here. Realm's `RealmCoreResources` is an Objective-C resource-bundle
# target whose generated header imports `<Foundation/Foundation.h>` —
# that header doesn't exist on Linux, so pulling Realm in breaks the
# package graph. The Swift Package already gates the RealmSwift product
# behind `condition: .when(platforms: [.iOS])` for both `RailCommerce`
# and `RailCommerceApp`, and the Dockerfile only asks `swift build` for
# the two Linux-clean targets below.
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

# Explicitly target the two Linux-clean products. Do NOT run a bare
# `swift build` — that would try to resolve every target in the package,
# including `RailCommerceApp`, which transitively pulls the iOS-only
# Realm resource bundle.
RUN swift build -c debug --target RailCommerce \
 && swift build -c release --product RailCommerceDemo

# When the image is run (`docker compose up`, `docker run …`), execute
# the demo CLI. It walks every service in the portable library with a
# deterministic fake clock + in-memory persistence, prints structured
# output, and exits 0 on success. This gives a Linux submission runner
# a concrete "up" behavior instead of a container that idles.
CMD ["swift", "run", "-c", "release", "RailCommerceDemo"]
