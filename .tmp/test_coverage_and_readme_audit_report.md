# Test Coverage Audit

## Project Type Detection
- Inferred project type: **ios**.
- Evidence: `repo/README.md:3`, `repo/README.md:26`.

## Backend Endpoint Inventory
- Total HTTP endpoints discovered: **0**.
- Evidence:
  - `docs/apispec.md:7` (`No REST APIs`)
  - `docs/apispec.md:8` (`No HTTP endpoints`)
  - `docs/apispec.md:12` (`No backend server`)

## API Test Mapping Table
| Endpoint (METHOD + PATH) | Covered | Test type | Test files | Evidence |
|---|---|---|---|---|
| N/A (no HTTP endpoint surface) | N/A | N/A | N/A | `docs/apispec.md:7-12` |

## Coverage Summary
- Total endpoints: **0**
- Endpoints with HTTP tests: **0**
- Endpoints with TRUE no-mock HTTP tests: **0**
- HTTP coverage %: **N/A (0/0)**
- True API coverage %: **N/A (0/0)**

## Unit Test Summary

### Backend Unit Tests
- Present: **YES** (49 files in `repo/Tests/RailCommerceTests`).
- Modules covered (evidence examples):
  - Services: `CheckoutServiceTests`, `AfterSalesServiceTests`, `MessagingServiceTests`, `SeatInventoryServiceTests`, `ContentPublishingServiceTests`, `MembershipServiceTests`
  - Auth/security/core: `AuthorizationTests`, `FunctionLevelAuthTests`, `CredentialStoreTests`, `KeychainStoreTests`, `PersistenceStoreTests`
  - Cross-module integration: `IntegrationTests`
- Important backend modules not tested: no explicit HTTP server/controller/router layer exists to test.

### Frontend Unit Tests
- iOS app-layer tests: **PRESENT**.
- Framework: XCTest (Xcode test target).
- Evidence:
  - `repo/Tests/RailCommerceAppTests/LoginViewControllerTests.swift:3` (`@testable import RailCommerceApp`)
  - `repo/Tests/RailCommerceAppTests/CartBrowseCheckoutFlowTests.swift:3`
  - `repo/Tests/RailCommerceAppTests/SystemKeychainTests.swift:2`
  - `repo/Tests/RailCommerceAppTests/SystemProvidersTests.swift:3`
  - `repo/Tests/RailCommerceAppTests/AppShellFactoryTests.swift:3`
- Components/modules covered:
  - `LoginViewController`, `BrowseViewController`, `CartViewController`, `CheckoutViewController`, `SystemKeychain`, `SystemProviders`, `AppShellFactory`
- Important frontend components/modules not tested (visible gap):
  - No explicit tests found for `MainTabBarController`, `MainSplitViewController`, `MessagingViewController`, `MembershipViewController`, `AfterSalesViewController`, `SeatInventoryViewController`, `ContentPublishingViewController`, `TalentMatchingViewController`.

Mandatory verdict: **Frontend unit tests: PRESENT**

## API Test Classification
1. True No-Mock HTTP: **0**
2. HTTP with Mocking: **0**
3. Non-HTTP (unit/integration without HTTP): **54 files total**
- `RailCommerceTests`: 49 files
- `RailCommerceAppTests`: 5 files

## Mock Detection
- No Jest/Vitest/Sinon stack (Swift/XCTest).
- Test doubles / DI overrides are present in non-HTTP tests.
- Evidence:
  - `repo/Tests/RailCommerceTests/IntegrationTests.swift:10-14` (`FakeClock`, `InMemoryKeychain`, `FakeCamera`, `FakeBattery`)
  - `repo/Tests/RailCommerceTests/CoverageBoostTests.swift:15-50` (custom failing stores)

## API Observability Check
- Not applicable: no HTTP endpoints exist, therefore no HTTP method/path/request/response assertions exist.

## Test Quality & Sufficiency
- Strengths:
  - Broad service and cross-module assertions.
  - Explicit iOS app-target tests are present.
  - README-reported library coverage is >90% (static evidence only).
- Gaps:
  - No HTTP-layer test surface by architecture.
  - `run_tests.sh` is local toolchain dependent (not Docker-based).

## `run_tests.sh` Check
- `run_tests.sh` executes `swift test --enable-code-coverage` on macOS.
- Per strict rule: local dependency => **FLAG**.
- Evidence: `repo/run_tests.sh:38-50`.

## End-to-End Expectations
- For iOS/no-backend architecture, FE↔BE HTTP E2E is not applicable.
- Portable Docker E2E claim is currently inconsistent with actual container behavior (see README audit).

## Test Coverage Score (0–100)
- **86/100**

## Score Rationale
- Strong breadth in core + app-layer tests (+)
- Frontend/app-layer unit tests now present (+)
- No HTTP endpoint/test surface (neutral by architecture)
- Local-only `run_tests.sh` dependency flagged (-)

## Key Gaps
1. No HTTP endpoint testing possible because no HTTP endpoint surface exists.
2. Coverage numbers are accepted from README as static evidence; not independently executed in this audit.

## Confidence & Assumptions
- Confidence: **High** for file-level evidence; **medium** for numeric coverage claims (static-only).
- Assumption: README-reported coverage metrics reflect latest executed results.

## Test Coverage Verdict
- **PASS**

---

# README Audit

## README Location
- Present: `repo/README.md`.

## Hard Gate Results

### Formatting
- PASS: readable markdown, clear sections/tables.

### Startup Instructions
- iOS startup instructions with simulator/Xcode flow are present.
- Evidence: `repo/README.md:69-94`.

### Access Method
- PASS: explicit simulator access and success signals.
- Evidence: `repo/README.md:78-93`.

### Verification Method
- **FAIL** (evidence mismatch).
- README claims `docker compose up` runs `RailCommerceDemo` end-to-end:
  - `repo/README.md:100`, `repo/README.md:105`, `repo/README.md:113-114`
- Current Dockerfile is placeholder-only echo/exit-0 container; it does not run demo logic:
  - `repo/Dockerfile:13-22`
- Therefore verification claim is not supported by current implementation.

### Environment Rules (STRICT)
- **FAIL** under strict literal interpretation (`Everything must be Docker-contained`).
- README still requires macOS + Xcode scripts for real app build/test:
  - `repo/README.md:58-67`, `repo/README.md:71-76`, `repo/README.md:122-125`, `repo/README.md:143-146`

### Demo Credentials (Conditional)
- PASS: credentials include username + password + all roles.
- Evidence: `repo/README.md:173-180`.

## Engineering Quality
- Strong architecture and workflow explanation.
- Clear credentials and role mapping.
- Main weakness: container verification section currently overstates what `docker compose up` does in current codebase.

## High Priority Issues
1. README verification claim for Docker end-to-end demo conflicts with actual Dockerfile behavior (`README` says demo run; Dockerfile is placeholder echo/exit).
2. Strict Docker-contained hard gate remains unmet for iOS build/test paths.

## Medium Priority Issues
1. None beyond above hard-gate/verification mismatches.

## Low Priority Issues
1. None significant.

## Hard Gate Failures
1. Verification Method: **FAIL** (claim/implementation mismatch)
2. Environment Rules (STRICT): **FAIL**

## README Verdict
- **FAIL**

---

# Final Verdicts
1. **Test Coverage Audit:** PASS
2. **README Audit:** FAIL
