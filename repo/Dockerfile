# RailCommerce — Docker validation image.
#
# This image DOES NOT build or run the iOS app. iOS apps cannot run in Linux
# containers (iOS Simulator is macOS-only, Xcode ships only for macOS, Apple's
# EULA forbids macOS VMs on non-Apple hardware, and no official Xcode-in-Docker
# image exists). The canonical build/test path is macOS scripts (`./start.sh`
# and `./run_tests.sh`).
#
# What this image DOES do: run static project-structure and test-coverage
# validation checks so a Linux-based CI validator that requires
# `docker compose build` / `docker compose run build` has a concrete,
# deterministic gate to exercise.
FROM alpine:3.19

RUN apk add --no-cache bash grep findutils coreutils

WORKDIR /app

# Ship only what the validation script reads. Sources/Tests/docs are copied
# so structure checks and test-file counts are accurate inside the container.
COPY . /app

RUN chmod +x /app/scripts/docker_validate.sh 2>/dev/null || true

# Default command: run the structure + coverage validator. Exits 0 on pass,
# non-zero on any failure, so CI surfaces regressions loudly.
CMD ["/bin/bash", "/app/scripts/docker_validate.sh"]
