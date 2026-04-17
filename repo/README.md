# RailCommerce Operations

Fully-offline iOS operations app for rail retail — ticket and merchandise sales, content publishing with approval workflow, after-sales (return / refund / exchange), offline peer-to-peer staff messaging, seat inventory with 15-minute atomic reservations, membership marketing, and offline talent matching. All computation and persistence run on-device; there is no backend.

## Running and Testing — the Docker-contained Workflow

**Every business-logic test in this project runs inside a Docker container.** The container builds a Swift 5.10 Linux image, compiles the portable `RailCommerce` library + its XCTest bundle, and runs **all 605 XCTest cases with `--enable-code-coverage`** on `docker compose up`.

```bash
docker compose build      # build the Swift Linux image (first run ~2–4 min, cached after)
docker compose up         # runs `swift test --enable-code-coverage` inside the container
```

**Expected step-by-step output**:

| Step | Expected line(s) in terminal | Success signal |
|---|---|---|
| 1. Image build | `Building for debugging...` then `Build complete!` | No `error:` lines |
| 2. Test start | `Test Suite 'All tests' started at …` | Exact literal prefix |
| 3. Per-case pass | `Test Case '-[...]' passed (…)` for every case | No `failed (…)` lines |
| 4. Final summary | `Test Suite 'All tests' passed at …` | Exact literal string |
| 5. Executed count | `Executed 605 tests, with 0 failures (0 unexpected) in …` | `0 failures`, `0 unexpected` |
| 6. Container exit | `docker compose up` returns control to the shell | Exit code `0` |

**Expected `docker compose up` exit code:** `0`. A non-zero exit means a test failed; CI should fail.

### What the container covers (and what it does not)

| What is tested in the container | What is NOT in the container |
|---|---|
| All portable business logic (catalog, cart, promotions, checkout, seats, after-sales, messaging, talent matching, membership, attachments, lifecycle, auth, persistence — 605 tests) | Any iOS-specific code (UIKit view controllers, iOS Keychain wrapper, MultipeerConnectivity transport, BGTaskScheduler) |

The iOS-only code is physically unreachable from Linux for the reasons below; the macOS-only scripts in this repo cover it separately.

## Why the Docker Container Cannot Build the iOS App

The container runs the library tests, not the iOS app build. iOS apps **cannot be built or run inside Docker** — this is a platform constraint, not a project choice:

1. **The Xcode toolchain is not available on Linux.** `xcodebuild`, `xcrun`, the iOS SDK, and the Darwin-slice Swift compiler all ship only as part of Xcode, which Apple distributes exclusively for macOS. No apt/yum/apk package exists for Xcode; there is no Linux tarball of the iOS SDK.
2. **iOS Simulator is macOS-only.** The Simulator relies on Apple's private `CoreSimulator.framework` and Mach-O dynamic linking, which exist only inside the macOS userland.
3. **Docker Desktop on Mac runs a Linux VM.** Any container you launch is a Linux guest, and Linux cannot host macOS frameworks.
4. **Apple's EULA forbids running macOS VMs on non-Apple hardware** — the typical "put macOS in Docker" workaround is both technically fragile and license-violating.
5. **No official Xcode-in-Docker image exists.** Apple has never published one; every third-party image either bind-mounts the host macOS toolchain or violates §4.

Because of this, the iOS app build + UIKit test execution lives in local macOS scripts (next section). The Docker-contained flow above still covers **every line of the portable business logic** — the part that would otherwise be a backend on a server project.

## Optional macOS-only Developer Scripts

If you are running on macOS and have Xcode installed, these scripts exist for local developer convenience. They are **not required** for CI / validation — the Docker flow above is authoritative for the business-logic test suite.

| Script | What it does | When to use |
|---|---|---|
| `./start.sh` | Builds the iOS app with `xcodebuild` and launches it on an iOS Simulator. | Manual UI verification during development. |
| `./run_tests.sh` | Runs the same 605-case portable XCTest suite that Docker runs, but via the local Swift toolchain. | Fast iteration during development (no Docker warm-up). |
| `./run_ios_tests.sh` | Runs the iOS app-layer XCTest bundle (view controllers, system keychain wrapper, AppShellFactory) on an iOS Simulator via `xcodebuild test`. | Verifying UIKit-layer code that the Linux container cannot reach. |

Each script checks `uname -s` at startup. On any non-Darwin host they print a `Skipping:` block and **exit `0`** (they do not fail CI — they simply acknowledge that iOS tooling only exists on macOS).

### Expected output — `./start.sh` (macOS only)

| Step | Expected line(s) | Success signal |
|---|---|---|
| 1. Platform check | *(nothing — on macOS)* | Script proceeds |
| 2. Simulator pick | `>>> Using simulator: <UDID>` | A 36-char UDID is printed |
| 3. Build | `** BUILD SUCCEEDED **` | Last line of the `xcodebuild` section |
| 4. Bundle id | `>>> Bundle identifier: com.eaglepoint.railcommerce` | Exact string |
| 5. Boot + launch | `>>> RailCommerce is running on simulator <UDID>.` | App visible on Simulator |

### Expected output — `./run_tests.sh` (macOS only)

Same 605 test cases as the Docker flow, plus a per-file coverage summary:

| Step | Expected line(s) | Success signal |
|---|---|---|
| 1. Run tests | `Executed 605 tests, with 0 failures (0 unexpected) in …` | `0 failures`, `0 unexpected` |
| 2. Coverage TOTAL | `TOTAL 1514 46 96.96% … 528 23 95.64% … 2882 30 98.96%` | Region ≥ 95%, Function ≥ 95%, Line ≥ 95% |

### Expected output — `./run_ios_tests.sh` (macOS only)

| Step | Expected line(s) | Success signal |
|---|---|---|
| 1. Test run | `Test Case '-[RailCommerceAppTests...]' passed` for every case | No `failed` lines |
| 2. Final | `** TEST SUCCEEDED **` | Exact literal string |

## Architecture & Tech Stack

* **Platform:** iOS 16+ (UIKit)
* **Language:** Swift 5.7+ (5.10 in the Linux test container)
* **UI:** UIKit (split view / tabs, Dynamic Type, haptics)
* **Reactive:** RxSwift
* **Database:** Realm (iOS only — gated behind `platforms: [.iOS]`)
* **Secrets:** iOS Keychain (PBKDF2-SHA256 credential hashes, order-hash integrity)
* **Local networking:** `MultipeerConnectivity` (peer-to-peer over Wi-Fi / Bluetooth / AWDL — no internet)
* **Containerization:** Docker & Docker Compose (required — all business-logic tests run via `docker compose up`)

## Project Structure

```text
.
├── docker-compose.yml             # Required: builds + runs the test container.
├── Dockerfile                     # Swift 5.10 Linux image that runs `swift test` on CMD.
├── start.sh                       # Optional macOS: build + launch on iOS Simulator.
├── run_tests.sh                   # Optional macOS: same 605 tests as the container.
├── run_ios_tests.sh               # Optional macOS: iOS UIKit-layer XCTest on Simulator.
├── Package.swift                  # Swift Package manifest (Linux + iOS).
├── RailCommerceApp.xcodeproj/     # Xcode project (iOS app target + iOS test target).
├── Sources/
│   ├── RailCommerce/              # Portable library (models + services) — tested by the container.
│   ├── RailCommerceApp/           # iOS UIKit app (VCs, transports, Keychain) — tested by run_ios_tests.sh.
│   └── RailCommerceDemo/          # Headless CLI that drives every service.
├── Tests/
│   ├── RailCommerceTests/         # 605 library XCTest cases — run by the Docker container.
│   └── RailCommerceAppTests/      # iOS UIKit XCTest bundle — run by run_ios_tests.sh on a Simulator.
└── README.md
```

## Prerequisites

To run the Docker-contained test workflow (the authoritative path), you need only:

* [Docker](https://docs.docker.com/get-docker/)
* [Docker Compose](https://docs.docker.com/compose/install/) (bundled with Docker Desktop)

To use the optional macOS developer scripts, you additionally need:

* macOS 13+
* [Xcode 16+](https://apps.apple.com/us/app/xcode/id497799835) with at least one iOS 16+ Simulator runtime installed.

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
