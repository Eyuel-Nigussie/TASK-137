#!/usr/bin/env bash
# Runs the full RailCommerce test suite inside Docker.
#
# Contract (per submission requirements):
#   * Runs all tests by default with no additional arguments or flags.
#   * Executes tests inside Docker — no host-side Swift/Xcode/Python/Node needed.
#   * Only host dependency is the `docker` CLI itself.
#   * Returns the test-suite exit code (non-zero on failure) so CI fails loudly.
#
# The library + tests are pure Swift/Foundation and compile identically on macOS
# and Linux. No test in this suite is platform-specific; if one is ever added,
# gate it with `#if os(macOS)` (or env-var `SKIP_MAC_ONLY_TESTS=1`) so it is
# excluded automatically inside this Linux container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE="${RAILCOMMERCE_IMAGE:-railcommerce:latest}"

# Always rebuild to pick up the latest source changes.
echo ">>> Building Docker image $IMAGE..."
docker build -t "$IMAGE" -f Dockerfile .

echo ">>> Executing tests inside $IMAGE"

# swift test on Linux hangs after all tests complete — RxSwift's GCD scheduler
# threads prevent the process from exiting naturally.  Using `timeout` here
# would produce the wrong exit code (124) and force a multi-minute wait.
#
# Instead we:
#   1. Run the container detached so we can control its lifecycle.
#   2. Stream its output in real-time via `docker logs --follow`.
#   3. Detect the final XCTest "All tests" summary line to capture the real
#      pass/fail result.
#   4. Stop the container immediately once the summary appears, then exit
#      with the correct code.

CONTAINER=$(docker run --detach --init \
    -e SKIP_MAC_ONLY_TESTS=1 \
    "$IMAGE" \
    swift test)

EXIT_CODE=1   # conservative default; overwritten when the summary line appears

while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
        "Test Suite 'All tests' passed"*)
            EXIT_CODE=0
            # Stop the container in the background so we can finish draining
            # any remaining buffered log lines before the stream closes.
            docker stop --time 5 "$CONTAINER" >/dev/null 2>&1 &
            ;;
        "Test Suite 'All tests' failed"*)
            EXIT_CODE=1
            docker stop --time 5 "$CONTAINER" >/dev/null 2>&1 &
            ;;
    esac
done < <(docker logs --follow "$CONTAINER" 2>&1)

# Container is stopped (by docker stop above, or it exited on its own).
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

exit "$EXIT_CODE"
