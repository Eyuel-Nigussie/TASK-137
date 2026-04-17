#!/usr/bin/env bash
# Docker validator — static project-structure and test-coverage checks.
#
# Runs inside the Alpine container produced by `docker compose build` and is
# invoked by `docker compose run build`. DOES NOT execute XCTest — iOS tests
# cannot be built or run on Linux. The canonical test path is
# `./run_tests.sh` on macOS.
#
# Every check prints a `[PASS]` / `[FAIL]` line and the script exits non-zero
# on any failure so CI validators can gate on the return code.
set -u

FAIL=0
pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; FAIL=$((FAIL + 1)); }

echo "==================== RailCommerce Docker Validation ===================="

# 1. Mandatory top-level files.
for f in README.md Package.swift run_tests.sh start.sh \
         Dockerfile docker-compose.yml RailCommerceApp.xcodeproj/project.pbxproj; do
    if [ -e "/app/$f" ]; then
        pass "mandatory file present: $f"
    else
        fail "missing mandatory file: $f"
    fi
done

# 2. Mandatory source directories.
for d in Sources/RailCommerce Sources/RailCommerceApp Tests/RailCommerceTests \
         Tests/RailCommerceAppTests; do
    if [ -d "/app/$d" ]; then
        pass "source tree present: $d"
    else
        fail "missing source tree: $d"
    fi
done

# 3. Test script canonicity — run_tests.sh must be the entry point.
if grep -q '^#!/usr/bin/env bash' "/app/run_tests.sh" && \
   grep -q 'swift test' "/app/run_tests.sh"; then
    pass "run_tests.sh is executable bash and invokes swift test"
else
    fail "run_tests.sh is not the expected canonical test runner"
fi

# 4. Platform guard — scripts must skip gracefully on non-macOS hosts.
for script in run_tests.sh start.sh; do
    if grep -q 'Darwin' "/app/$script" && grep -q 'exit 0' "/app/$script"; then
        pass "$script has platform guard with graceful exit 0"
    else
        fail "$script missing macOS platform guard"
    fi
done

# 5. Test surface size — count test files and test methods.
lib_test_files=$(find /app/Tests/RailCommerceTests -type f -name '*Tests.swift' | wc -l | tr -d ' ')
app_test_files=$(find /app/Tests/RailCommerceAppTests -type f -name '*Tests.swift' | wc -l | tr -d ' ')
lib_test_methods=$(grep -rh '^\s*func test' /app/Tests/RailCommerceTests 2>/dev/null | wc -l | tr -d ' ')
app_test_methods=$(grep -rh '^\s*func test' /app/Tests/RailCommerceAppTests 2>/dev/null | wc -l | tr -d ' ')

if [ "$lib_test_files" -ge 1 ]; then
    pass "library test files: $lib_test_files"
else
    fail "no library test files found"
fi
if [ "$app_test_files" -ge 1 ]; then
    pass "iOS app-layer test files: $app_test_files"
else
    fail "no iOS app-layer test files found"
fi
if [ "$lib_test_methods" -ge 100 ]; then
    pass "library test methods: $lib_test_methods (>= 100 threshold)"
else
    fail "library test methods: $lib_test_methods (expected >= 100)"
fi
if [ "$app_test_methods" -ge 20 ]; then
    pass "iOS app-layer test methods: $app_test_methods (>= 20 threshold)"
else
    fail "iOS app-layer test methods: $app_test_methods (expected >= 20)"
fi

# 6. README must declare iOS project type in the top two sections.
if head -n 20 /app/README.md | grep -qiE '(native ios|ios (app|application|operations|project)|fully-offline ios)'; then
    pass "README declares iOS project type in header"
else
    fail "README does not declare iOS project type in the first 20 lines"
fi

# 7. README must document why Docker cannot run the iOS app.
if grep -qE 'iOS Simulator|Xcode (toolchain|is macOS-only|is not available on Linux)' /app/README.md; then
    pass "README explains the iOS / Xcode / Simulator constraint"
else
    fail "README does not explain iOS Simulator / Xcode availability constraint"
fi

# 8. docker-compose.yml must declare the `build` service used by validators.
if grep -qE '^\s*build:' /app/docker-compose.yml && \
   grep -qE 'railcommerce' /app/docker-compose.yml; then
    pass "docker-compose.yml declares the validation service"
else
    fail "docker-compose.yml missing required build service"
fi

echo "========================================================================"
if [ "$FAIL" -eq 0 ]; then
    echo "[SUCCESS] All validation checks passed."
    exit 0
else
    echo "[FAILURE] $FAIL validation check(s) failed."
    exit 1
fi
