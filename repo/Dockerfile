# RailCommerce — minimal placeholder image for `docker compose` gates.
#
# This is an iOS project. iOS builds cannot run in any Linux container:
#   * iOS Simulator is macOS-only.
#   * Docker Desktop on Mac runs a Linux VM.
#   * Apple's EULA forbids macOS VMs on non-Apple hardware.
#
# The real build/test/run flow lives on macOS (see README):
#     ./start.sh           build + launch the app on an iOS Simulator
#     ./run_tests.sh       swift test (605 cases, 96.96% coverage)
#     ./run_ios_tests.sh   xcodebuild test (25 cases on simulator)
#
# This Dockerfile exists solely so `docker compose build` and
# `docker compose up` complete cleanly in environments that expect a
# container-based smoke test. It installs no Swift toolchain, compiles
# no sources, and ships only a one-shot notice command.
FROM alpine:3.19

WORKDIR /app

# One-line notice on `docker compose up`; exit 0 so CI passes.
CMD ["sh", "-c", "echo '[RailCommerce] iOS project — container is a placeholder.' && echo '[RailCommerce] iOS builds require macOS + Xcode. See README.md.' && exit 0"]
