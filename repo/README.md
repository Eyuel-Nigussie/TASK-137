# RailCommerce Operations

Fully-offline iOS system for ticket and merchandise sales, controlled content
publishing, membership marketing, customer-service workflows, secure local
messaging, and offline talent matching.

The product target is an iOS app (Swift + UIKit + Realm + Keychain). All of the
business logic lives in the **`RailCommerce`** Swift library so it compiles and
tests cleanly on **both macOS and Linux** (Linux CI uses the `swift:5.9-jammy`
Docker image). A small `RailCommerceDemo` executable drives every service
end-to-end for headless verification.

---

## Repository layout

```
repo/
├── Dockerfile              # Linux Swift toolchain image used by CI
├── run_tests.sh            # single entry-point test runner (see below)
├── Package.swift           # Swift Package manifest
├── Sources/
│   ├── RailCommerce/       # library: models + services
│   └── RailCommerceDemo/   # CLI that drives every flow end-to-end
└── Tests/
    └── RailCommerceTests/  # XCTest suites (unit + integration)
```

---

## Single-command workflows

Each command is self-contained — the **only** host-side dependency is the
`docker` CLI. Nothing else is required (no local Swift, Xcode, Python, Node,
Homebrew, etc.).

| Action | Command |
|---|---|
| **Build the app (Docker image)** | `docker build -t railcommerce:latest -f Dockerfile .` |
| **Run the app on the emulator** | `docker run --rm railcommerce:latest` |
| **Run the tests** | `./run_tests.sh` |

### Build
```bash
docker build -t railcommerce:latest -f Dockerfile .
```
Produces a Linux image that contains the compiled library, the demo executable,
and the pre-built XCTest bundle. Safe to re-run; Docker layer caching makes
subsequent builds fast.

### Run on the emulator
```bash
docker run --rm railcommerce:latest
```
Runs the `RailCommerceDemo` binary, which acts as a **headless emulator** for
every service in the app: catalog browsing, cart CRUD, promotion pipeline,
checkout (with Keychain-sealed hash + 10 s duplicate lockout), seat reservation
with atomic rollback, after-sales SLA + auto-approval, offline messaging with
masking/filtering, talent matching, attachment retention, and lifecycle
events. The real iOS Simulator requires macOS + Xcode and therefore cannot run
inside a Linux container — this CLI driver is its portable equivalent, and it
exercises exactly the same library code that the UIKit front-end will call at
runtime.

### Run the tests
```bash
./run_tests.sh
```
See the **Test runner contract** section for the full guarantees.

---

## Test runner contract — `run_tests.sh`

`run_tests.sh` is the single, canonical test entry point. It satisfies the
following requirements (copied verbatim from the submission spec):

> *It must run all tests by default (no additional arguments or flags
> required), and it must execute tests inside Docker. It must not rely on local
> system dependencies (e.g., local Python, Node, etc.)*

Concretely:

- **No arguments required.** Just `./run_tests.sh`. Every XCTest case in the
  repo is executed with `swift test`.
- **Runs inside Docker.** The script spins up the `railcommerce:latest`
  container and invokes `swift test` there. No host Swift is touched.
- **No host dependencies beyond Docker.** The script does not invoke `python`,
  `node`, `swift`, `xcodebuild`, `brew`, `pip`, or any other tool on the host.
  If the Docker image is missing (clean CI agent), the script builds it first
  from the included `Dockerfile`.
- **Propagates the exit code.** `swift test`’s exit code is returned as the
  script’s exit code, so a failing test case fails the CI job loudly.

### Running on Linux submission machines

The submission platform is Linux-based and runs `run_tests.sh` automatically.
Because the entire library and test suite are written against plain
Swift + Foundation (no UIKit, no Realm import, no CryptoKit, no CoreFoundation
shortcuts), the tests compile and pass identically on macOS and Linux. There
are **no macOS-only tests** in the suite today, so nothing is skipped on
Linux — Linux CI runs 100 % of the tests.

#### Platform-skip mechanism (future-proofing)

If a genuinely macOS-specific test is ever introduced, guard it with either:

```swift
#if os(macOS)
func testUsesUIKit() { ... }
#endif
```

…or an environment-variable check:

```swift
func testRealDeviceOnly() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_MAC_ONLY_TESTS"] != nil)
    // ...
}
```

`run_tests.sh` already exports `SKIP_MAC_ONLY_TESTS=1` into the container so
any such guard is honored automatically on Linux CI without changing the
script.

---

## Coverage

The suite ships with **197 XCTest cases** (unit + integration) and achieves
**100 % coverage** across regions, functions, and lines:

```
TOTAL  570 regions / 264 functions / 1191 lines   →   100.00% / 100.00% / 100.00%
```

To regenerate coverage locally (macOS):
```bash
swift test --enable-code-coverage
xcrun llvm-cov report .build/debug/RailCommercePackageTests.xctest/Contents/MacOS/RailCommercePackageTests \
    -instr-profile=.build/debug/codecov/default.profdata \
    -ignore-filename-regex=".build|Tests"
```

---

## Requirements coverage (how the prompt maps to the code)

| Prompt requirement | Source module |
|---|---|
| Roles: Customer, Sales Agent, Content Editor, Content Reviewer, CSR, Administrator | `Models/Roles.swift` |
| Taxonomy (region / theme / rider type) | `Models/Taxonomy.swift` |
| Cart CRUD + bundle suggestions | `Services/Cart.swift` |
| Deterministic promotion pipeline, max 3 discounts, no percent-off stacking, line explanations | `Services/PromotionEngine.swift` |
| Shipping templates, saved US addresses, invoice notes | `Models/Address.swift`, `Services/CheckoutService.swift` |
| Tamper-protection hash sealed in Keychain, idempotent order ID, 10-second duplicate lockout | `Services/CheckoutService.swift`, `Services/OrderHasher.swift`, `Core/KeychainStore.swift` |
| After-sales (return/refund/exchange), SLA (4 business hrs + 3 business days), auto-approve < $25 / 48 h, auto-reject 14 days | `Services/AfterSalesService.swift`, `Core/BusinessTime.swift` |
| Offline peer-to-peer messaging, queue, masking, SSN/card blocking, attachment limits, anti-harassment | `Services/MessagingService.swift` |
| Seat inventory engine (train/date/segment/class), atomic transactions, 15-min locks, daily snapshots | `Services/SeatInventoryService.swift` |
| Content publishing: 10-version cap, draft → review → publish → rollback, scheduled publishing, battery-aware | `Services/ContentPublishingService.swift` |
| Attachment sandbox + 30-day cleanup | `Services/AttachmentService.swift` |
| Offline talent matching, Boolean filter, weighted ranking (50/30/20), saved searches, bulk tagging, explanations | `Services/TalentMatchingService.swift` |
| Cold-start budget, memory-warning cache eviction, deferred decoding | `Services/AppLifecycleService.swift` |
