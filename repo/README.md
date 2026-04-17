# RailCommerce Operations

Native iOS application (Swift / UIKit) for fully-offline rail retail operations — ticket and merchandise sales, content publishing with approval workflow, after-sales (return / refund / exchange), secure offline peer-to-peer staff messaging, seat inventory with 15-minute atomic reservations, membership marketing, and offline talent matching. The app supports multi-role workflows for customers, sales agents, content editors, content reviewers, customer-service reps, and administrators with full on-device persistence, credential hashing, and tenant isolation.

## Architecture & Tech Stack

* **Application:** Native iOS (Swift / UIKit) — fully offline, no backend
* **Persistence:** Realm (encrypted on-device) with per-user scoping; Keychain for credential hashes and order-hash integrity
* **Security:** Keychain (PBKDF2-SHA256, 310k iterations, per-user salt + Keychain-held pepper), biometric re-auth (LocalAuthentication), order-snapshot HMAC tamper hash, identity-bound Multipeer inbound frames
* **Local networking:** `MultipeerConnectivity` (peer-to-peer over Wi-Fi / Bluetooth / AWDL — no internet)
* **Reactive:** RxSwift
* **Build:** Swift Package Manager (Package.swift) + Xcode project (RailCommerceApp.xcodeproj), Xcode 16+, iOS 16.0+ deployment target
* **Containerization:** Docker & Docker Compose (Required)
* **Testing:** XCTest (unit, integration, iOS app-layer)

## Project Structure

```text
.
├── Sources/
│   ├── RailCommerce/              # Portable library (models + services)
│   │   ├── Core/                  # Auth, persistence, logger, transport
│   │   ├── Models/                # Roles, taxonomy, catalog, address
│   │   └── Services/              # Checkout, after-sales, messaging, seats, content, talent, membership, attachments
│   ├── RailCommerceApp/           # iOS UIKit app (AppDelegate, views, Keychain, Multipeer)
│   └── RailCommerceDemo/          # Headless CLI that drives every service
├── Tests/
│   ├── RailCommerceTests/         # 51 files, 636 test methods (library)
│   └── RailCommerceAppTests/      # 9 files, 58 test methods (iOS app-layer)
├── docs/                          # design.md, questions.md, apispec.md
├── scripts/                       # Docker validation helpers
├── start.sh                       # Launch app locally on iOS Simulator - MANDATORY
├── Dockerfile                     # Container build definition - MANDATORY
├── docker-compose.yml             # Docker validation service - MANDATORY
├── project.pbxproj (in .xcodeproj)# Xcode project
├── Package.swift                  # Swift Package manifest
├── run_tests.sh                   # Standardized test execution script - MANDATORY
├── run_ios_tests.sh               # iOS UIKit-layer XCTest runner
└── README.md                      # Project documentation - MANDATORY
```

## Prerequisites

* [Docker](https://docs.docker.com/get-docker/)
* [Docker Compose](https://docs.docker.com/compose/install/)
* **macOS with Xcode 16+** and at least one iOS 16+ Simulator runtime installed

## Running the Application

1. **Start the App:**
   ```bash
   ./start.sh
   ```
   Builds the project, installs it on the iOS Simulator (iPhone 15 by default; override via `SIM_NAME="iPhone 17" ./start.sh`), and launches it.

2. **Access the App:**
   The RailCommerce login screen appears automatically after `./start.sh` completes.

3. **Verify the App Works:**
   1. The login screen shows **Username** and **Password** fields plus, on a fresh install, a **Create Administrator Account** button (bootstrap path when no credentials are enrolled).
   2. Tap **Create Administrator Account** → enter username `admin`, password `AdminTest123!` → submit. The first account enrolled becomes the administrator.
   3. The main tab bar appears: **Browse**, **Advisories**, **Cart**, **Seats**, **Returns**, **Content**, **Talent**, **Membership**, **Messages** (visible tabs depend on the signed-in role).
   4. On iPad, the shell automatically becomes a two-column **UISplitViewController** with the same role-aware feature set in the sidebar.

4. **Stop and Clean Up:**
   ```bash
   docker compose down -v
   ```

## Testing

The **single canonical test command** is `run_tests.sh`. All unit, integration, and audit-closure tests are executed through this script:

```bash
chmod +x run_tests.sh
./run_tests.sh
```

This runs the full XCTest library suite (636 tests) via `swift test --enable-code-coverage` on the local macOS host and prints a per-file coverage report (96.96% region / 98.96% line). Exit code 0 = all tests passed; non-zero = failure.

For the iOS UIKit layer (view controllers, SystemKeychain, AppShellFactory, Multipeer spoof-rejection) run:

```bash
chmod +x run_ios_tests.sh
./run_ios_tests.sh
```

This runs the `RailCommerceAppTests` bundle (58 tests) via `xcodebuild test` on an iOS Simulator.

> **Docker validation** (`docker compose run build`) is secondary tooling that performs static project structure and test coverage checks inside an Alpine container. It does not execute XCTest and is not the canonical test path. iOS apps cannot be compiled or run in any Linux container because Xcode, the iOS SDK, and the iOS Simulator ship only for macOS. The canonical test path is `./run_tests.sh` and `./run_ios_tests.sh` on macOS.

## Seeded Credentials

This is a fully offline native iOS app with no shipped seed data. Accounts are created locally through the in-app **Create Administrator Account** flow on first launch. The first user enrolled becomes the administrator.

For testing, DEBUG builds additionally seed six role fixtures so manual UI testing is immediate. Use these credentials to verify authentication and role-based access controls (passwords must be 12+ chars, with at least 1 digit and 1 symbol):

| Role | Username | Password | Notes |
| :--- | :--- | :--- | :--- |
| **Admin** | `dan` | `DanAdmin!2024$` | Full access to every module. |
| **Customer** | `alice` | `Alice!Pass1#2024` | Browse, cart, checkout, after-sales. |
| **Sales Agent** | `sam` | `SamAgent!2024$` | Process transactions, manage inventory (on-behalf-of sales). |
| **Content Editor** | `eve` | `EveEditor!2024$` | Draft content (cannot approve own draft). |
| **Content Reviewer** | `rita` | `RitaReview!2024$` | Review + publish content. |
| **Customer Service** | `chris` | `ChrisCSR!2024$` | Handle after-sales tickets, staff messaging. |

*Note: These fixtures are compiled in only under `#if DEBUG` (`AppDelegate.seedCredentialsIfNeeded`) — release builds never ship them.*
