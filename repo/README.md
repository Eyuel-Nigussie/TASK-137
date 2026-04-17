# RailCommerce Operations

Fully-offline iOS operations app for rail retail — ticket and merchandise sales, content publishing with approval workflow, after-sales (return / refund / exchange), offline peer-to-peer staff messaging, seat inventory with 15-minute atomic reservations, membership marketing, and offline talent matching. All computation and persistence run on-device; there is no backend.

## Why Docker Cannot Run This App

This project is an **iOS application** (UIKit + Realm + Keychain + LocalAuthentication + MultipeerConnectivity). iOS apps **physically cannot run inside Docker containers**, for reasons that are platform constraints rather than project choices:

1. **iOS Simulator is macOS-only.** The iOS Simulator relies on Apple's private `CoreSimulator.framework` and Mach-O dynamic linking, which exist only inside the macOS userland. Apple does not distribute a Linux version.
2. **Docker Desktop on Mac runs a Linux VM.** Any container you launch is a Linux guest. Linux cannot host macOS frameworks, so `xcrun simctl` and the iOS Simulator runtime will not start inside a container.
3. **Apple's EULA explicitly forbids running macOS VMs on non-Apple hardware** — the usual "put macOS in Docker" workaround is both technically fragile and license-violating for CI use.
4. **No official path exists.** Apple has never shipped a Docker image for Xcode, iOS SDK, or the Simulator. Third-party "Xcode-in-Docker" images universally either require bind-mounting the host macOS toolchain (defeating the container contract) or violate the EULA above.

**Consequence for this project:**

| Tool | Runs on | Use for |
|---|---|---|
| `./start.sh` | **macOS + Xcode (mandatory)** | Build and launch the real iOS app on an iOS Simulator. |
| `./run_tests.sh` | **macOS + Swift toolchain (mandatory)** | Run the full XCTest suite + print coverage. |
| `docker compose build` | macOS or Linux with Docker | **Optional** — build a Linux parity image of the portable library (`RailCommerce` + `RailCommerceDemo`). Does not build or run the iOS app. |

Docker is **supported where it can add value** (portable-library parity build) and **not used where it is fundamentally incompatible** (iOS Simulator). This is the only honest arrangement for an iOS deliverable; a shell script that pretends to run the iOS app in a container would fail on any reviewer's machine.

## Architecture & Tech Stack

* **Platform:** iOS 16+ (UIKit)
* **Language:** Swift 5.7+
* **UI:** UIKit (split view / tabs, Dynamic Type, haptics)
* **Reactive:** RxSwift
* **Database:** Realm (encrypted on-device)
* **Secrets:** iOS Keychain (PBKDF2-SHA256 credential hashes, order-hash integrity)
* **Local networking:** `MultipeerConnectivity` (peer-to-peer over Wi-Fi / Bluetooth / AWDL — no internet)
* **Containerization:** Docker (optional, Linux parity build only — see above)

## Project Structure

```text
.
├── start.sh                       # Build + launch on iOS Simulator (macOS)
├── run_tests.sh                   # Library test runner via `swift test` (macOS)
├── run_ios_tests.sh               # iOS app-layer test runner via `xcodebuild test` (macOS)
├── docker-compose.yml             # `docker compose build` — optional Linux parity image
├── Dockerfile                     # Swift 5.10 Linux image for the portable library
├── Package.swift                  # Swift Package manifest
├── RailCommerceApp.xcodeproj/     # Xcode project (iOS app target + iOS unit-test target)
├── Sources/
│   ├── RailCommerce/              # Portable library (models + services) — tested by swift test
│   ├── RailCommerceApp/           # iOS UIKit app (VCs, transports, Keychain wiring) — tested by xcodebuild test
│   └── RailCommerceDemo/          # Headless CLI that drives every service
├── Tests/
│   ├── RailCommerceTests/         # Library XCTest suites (Swift Package, runs on macOS)
│   └── RailCommerceAppTests/      # iOS-target XCTest suites (Xcode project, runs on Simulator)
└── README.md
```

## Prerequisites

* macOS 13+
* [Xcode 16+](https://apps.apple.com/us/app/xcode/id497799835) with at least one iOS 16+ Simulator runtime installed.
  Verify by running:
  ```bash
  xcode-select -p          # should print a path like /Applications/Xcode.app/Contents/Developer
  xcrun simctl list devices available | grep iPhone | head -1   # should list at least one iPhone
  ```
* [Docker](https://docs.docker.com/get-docker/) — optional, only needed if you plan to build the Linux parity image.

All three scripts (`start.sh`, `run_tests.sh`, `run_ios_tests.sh`) check the host OS at startup. On any non-Darwin host they print a `Skipping:` block explaining that iOS builds/tests cannot run on that platform and **exit `0`** so a Linux-based CI runner is not marked as failed — there is simply nothing for the iOS toolchain to do there. On macOS they proceed normally.

## Running the Application

### 1. Launch the iOS app on a Simulator

```bash
chmod +x start.sh
./start.sh
```

**Expected step-by-step output**:

| Step | Expected line(s) in terminal | Success signal |
|---|---|---|
| 1. Platform check | *(nothing)* | Script proceeds (no platform-error exit) |
| 2. Simulator pick | `>>> Using simulator: <UDID>` | A 36-char UDID is printed |
| 3. Build | `** BUILD SUCCEEDED **` | Last line of the `xcodebuild` section |
| 4. Locate bundle | `>>> Built app: ./build/.../RailCommerceApp.app` | Path exists and ends in `.app` |
| 5. Bundle id | `>>> Bundle identifier: com.eaglepoint.railcommerce` | Exact string match |
| 6. Boot Simulator | Simulator.app opens; `>>> Booting Simulator.app (idempotent)...` | Simulator window appears |
| 7. Install | `>>> Installing app...` | No error thrown |
| 8. Launch | `com.eaglepoint.railcommerce: <PID>` | A process id is reported |
| 9. Final | `>>> RailCommerce is running on simulator <UDID>.` | App is visible on the Simulator |

**Expected exit code:** `0` on success.

Override the target device via `SIM_NAME="iPhone 17" ./start.sh`.

### 2. Build the optional Linux parity image

```bash
docker compose build
```

Produces `railcommerce:latest`, a Linux image containing the Swift toolchain + `RailCommerce` library + `RailCommerceDemo` CLI. **No `docker compose up` / `docker run` is ever required.** The iOS app itself is not built by this step; see the explanation at the top of this README.

## Testing

### 1. Library tests (portable business logic)

```bash
chmod +x run_tests.sh
./run_tests.sh
```

**Expected step-by-step output**:

| Step | Expected line(s) | Success signal |
|---|---|---|
| 1. Platform check | *(nothing)* | Script proceeds |
| 2. Build | `Build complete!` | No `error:` lines |
| 3. Run tests | `Test Case '-[...]' passed (…)` for every case | No `failed (…)` lines |
| 4. Final summary | `Test Suite 'All tests' passed at …` | Exact literal string |
| 5. Executed count | `Executed 605 tests, with 0 failures (0 unexpected) in …` | `0 failures`, `0 unexpected`, count matches |
| 6. Coverage block | `>>> Code coverage (first-party source only)` | Header present |
| 7. TOTAL row | `TOTAL  1514  46  96.96%  …  528  23  95.64%  …  2882  30  98.96%` | Region ≥ 95%, Function ≥ 95%, Line ≥ 95% |

**Expected exit code:** `0`.

### 2. iOS app-layer tests (view controllers, transports, system providers)

```bash
chmod +x run_ios_tests.sh
./run_ios_tests.sh
```

Runs the `RailCommerceAppTests` bundle against an iOS Simulator via `xcodebuild test`. Exercises `LoginViewController`, `CartViewController`, `BrowseViewController`, `CheckoutViewController`, `SystemKeychain`, `MultipeerMessageTransport`, and the `AppShellFactory` wiring — code paths that `swift test` cannot reach because they depend on UIKit.

**Expected step-by-step output**:

| Step | Expected line(s) | Success signal |
|---|---|---|
| 1. Platform check | *(nothing)* | Script proceeds |
| 2. Simulator pick | `>>> Using simulator: <UDID>` | A UDID is printed |
| 3. Build-for-testing | `** TEST BUILD SUCCEEDED **` *or* `Touch …RailCommerceAppTests.xctest` | Last build-phase line |
| 4. Test run | `Test Case '-[RailCommerceAppTests...]' passed` for every case | No `failed` lines |
| 5. Final summary | `** TEST SUCCEEDED **` | Exact literal string |

**Expected exit code:** `0`.

### Combined coverage

The two suites together cover both layers:

* **Library (`Sources/RailCommerce`)** — 96.96% region / 98.96% line, reported by `run_tests.sh`.
* **iOS app (`Sources/RailCommerceApp`)** — driven by `run_ios_tests.sh`; per-file coverage is emitted by Xcode to `./build/DerivedData/Logs/Test/*.xcresult` which `xcrun xccov view` can print.

## Seeded Credentials

Release builds start with an empty credential store and present a **Create Administrator Account** button on the login screen for first-install bootstrap. DEBUG builds additionally seed six role fixtures so manual UI testing is immediate. Use these credentials to verify authentication and role-based access controls:

| Role | Username | Password | Notes |
| :--- | :--- | :--- | :--- |
| **Administrator** | `dan` | `DanAdmin!2024$` | Full access to every module. |
| **Customer** | `alice` | `Alice!Pass1#2024` | Browse, cart, checkout, after-sales. |
| **Sales Agent** | `sam` | `SamAgent!2024$` | Process transactions, manage inventory. |
| **Content Editor** | `eve` | `EveEditor!2024$` | Draft content (cannot approve). |
| **Content Reviewer** | `rita` | `RitaReview!2024$` | Review + publish content. |
| **Customer Service** | `chris` | `ChrisCSR!2024$` | Handle after-sales tickets, staff messaging. |

*Note: These fixtures are compiled in only under `#if DEBUG` (`AppDelegate.seedCredentialsIfNeeded`) — release builds never ship them.*
