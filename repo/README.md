# RailCommerce Operations

Fully-offline iOS operations app for rail retail — ticket and merchandise sales, content publishing with approval workflow, after-sales (return / refund / exchange), offline peer-to-peer staff messaging, seat inventory with 15-minute atomic reservations, membership marketing, and offline talent matching. All computation and persistence run on-device; there is no backend.

## Architecture & Tech Stack

* **Platform:** iOS 16+ (UIKit)
* **Language:** Swift 5.7+
* **UI:** UIKit (split view / tabs, Dynamic Type, haptics)
* **Reactive:** RxSwift
* **Database:** Realm (encrypted on-device)
* **Secrets:** iOS Keychain (PBKDF2-SHA256 credential hashes, order-hash integrity)
* **Local networking:** `MultipeerConnectivity` (peer-to-peer over Wi-Fi / Bluetooth / AWDL — no internet)
* **Containerization:** Docker (optional, Linux parity build only)

## Project Structure

```text
.
├── start.sh                       # Local build + launch on iOS Simulator (macOS)
├── run_tests.sh                   # Local test runner via `swift test` (macOS)
├── docker-compose.yml             # `docker compose build` — optional Linux parity image
├── Dockerfile                     # Swift 5.10 Linux image for the portable library
├── Package.swift                  # Swift Package manifest
├── RailCommerceApp.xcodeproj/     # Xcode project for the iOS app target
├── Sources/
│   ├── RailCommerce/              # Portable library (models + services)
│   ├── RailCommerceApp/           # iOS UIKit app (AppDelegate, views, Keychain wiring)
│   └── RailCommerceDemo/          # Headless CLI that drives every service
├── Tests/
│   └── RailCommerceTests/         # XCTest suites (unit + integration + audit-closure)
└── README.md
```

## Prerequisites

This project builds and runs **locally on macOS**. You must have the following installed:

* macOS 13+ with [Xcode 16+](https://apps.apple.com/us/app/xcode/id497799835) (includes Swift toolchain + iOS Simulator)
* [Docker](https://docs.docker.com/get-docker/) — optional, only needed if you want to build the Linux parity image

Both `start.sh` and `run_tests.sh` check the host OS at startup and abort with a platform-not-supported message on any non-Darwin host.

## Running the Application

1. **Launch on an iOS Simulator:**
   Build and install on a picked Simulator device, then start the app.
   ```bash
   chmod +x start.sh
   ./start.sh
   ```
   By default the script prefers `iPhone 15`. Override with `SIM_NAME`:
   ```bash
   SIM_NAME="iPhone 17" ./start.sh
   ```

2. **Run the iOS app from Xcode (alternative):**
   ```bash
   open RailCommerceApp.xcodeproj
   ```
   Select any iPhone or iPad simulator and press ⌘R.

3. **Build the optional Linux parity image:**
   ```bash
   docker compose build
   ```
   Produces `railcommerce:latest` with the portable library + `RailCommerceDemo` CLI. No `docker compose up` / `docker run` is required — the iOS app itself runs only on macOS.

## Testing

All unit, integration, and audit-closure tests are executed via a single shell script that runs `swift test` locally on macOS (no Docker, no simulator required).

```bash
chmod +x run_tests.sh
./run_tests.sh
```

The suite contains **600 XCTest cases** with **96.9% region / 98.9% line coverage**. The script exits `0` on success and non-zero on any test failure so it integrates cleanly with CI.

To regenerate coverage locally:
```bash
swift test --enable-code-coverage
xcrun llvm-cov report \
    .build/debug/RailCommercePackageTests.xctest/Contents/MacOS/RailCommercePackageTests \
    -instr-profile=.build/debug/codecov/default.profdata \
    -ignore-filename-regex=".build|Tests"
```

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
