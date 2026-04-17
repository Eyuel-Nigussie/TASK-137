# Audit Report-2 — Fix Verification Check

**Scope:** verify every action item from `.tmp/audit_report-2.md` against the current repo state.
**Method:** static inspection only — no builds, no test runs, no containers.
**Audit date:** 2026-04-17
**Repo HEAD at audit:** `e52a9de` (working tree touches `.tmp/audit_report-1.md`, `.tmp/audit_report-2.md`, `Tests/RailCommerceTests/CoverageFinalPushTests.swift`).

---

## 0. Summary of audit-report-2 findings

The original report concluded **Partial Pass** with:

- §4.1 Hard gates — all **Pass**.
- §5 *"Runtime-critical acceptance constraints cannot be proven in static-only scope"* — **Medium**, open.
- §8.2 Coverage Mapping Table — each row proposed a *"Minimum Test Addition"*. Eight rows in total.

Every one of those items is verified below.

---

## 1. §5 Medium — Runtime acceptance constraints

You addressed this in **two complementary ways** — static contract pinning + a real-hardware checklist — so the portions that *can* be proven statically are pinned, and the portions that *cannot* are documented as a runnable checklist.

| Aspect | Original expectation | Current state | Result |
| :-- | :-- | :-- | :-- |
| Cold-start budget (<1.5s) | Prove the budget constant + comparison direction cannot silently drift. | 4 tests in [Tests/RailCommerceTests/RuntimeConstraintsContractTests.swift:19-52](repo/Tests/RailCommerceTests/RuntimeConstraintsContractTests.swift#L19-L52) — `testColdStartBudgetIs1500Milliseconds`, `testMarkColdStartAcceptsFastStart`, `testMarkColdStartRejectsSlowStart`, `testMarkColdStartRejectsExactBudgetBoundary` (strict `<`, not `≤`). | **Addressed** |
| Memory-warning responsiveness | Prove handler evicts caches + drops pending decodes and counters accumulate across repeated warnings. | [RuntimeConstraintsContractTests.swift:58-93](repo/Tests/RailCommerceTests/RuntimeConstraintsContractTests.swift#L58-L93) — `testMemoryWarningEvictsCacheAndDefersDecodes`, `testRepeatedMemoryWarningsAccumulate`. | **Addressed** |
| Split View iPad parity | Prove each role's split-view shell has the same feature surface as its tab-bar shell. | [Tests/RailCommerceAppTests/SplitViewRoleParityTests.swift](repo/Tests/RailCommerceAppTests/SplitViewRoleParityTests.swift) — 8 tests across every role, including CSR-specific Returns visibility (:80, :102). Plus [SplitViewLifecycleTests.swift](repo/Tests/RailCommerceAppTests/SplitViewLifecycleTests.swift) — 5 tests. | **Addressed** |
| Permission prompts (Local Network / camera / notifications) | Prove wiring is present + document real-device UX steps. | Static wiring covered (camera via `FakeCamera` + real `AttachmentService`/`AfterSalesService` suites). Real-device UX pinned by [repo/docs/peer-session-manual-verification.md](repo/docs/peer-session-manual-verification.md) — section 1 "First-run Local Network prompt" walks through deny/grant/resume flow. | **Addressed** |

**Commit evidence:** `efe6cec` — *"Pin runtime-constraint contracts as static tests (audit pass #7)"*.

**Verdict on §5 Medium:** **Closed.** The static-provable contract is pinned, and the residual runtime-only surfaces have an explicit manual-verification checklist.

---

## 2. §8.2 — per-row *"Minimum Test Addition"* verification

| # | Requirement | Report's minimum addition | Evidence in repo | Result |
| :-: | :-- | :-- | :-- | :-- |
| 1 | Promotion determinism / max 3 / no percent stacking | *"add edge case with duplicate code inputs"* | [PromotionEngineTests.testDuplicateCodeInputRejectsSecondDeterministically](repo/Tests/RailCommerceTests/PromotionEngineTests.swift#L160-L173) — two `Discount` entries with the same `code: "DUP"`, same kind / magnitude / priority. Asserts: exactly one accepted, the other rejected with reason `percent-off-stacking-blocked` — no silent merge. | **Addressed** |
| 2 | Checkout idempotency & tamper protection | *"add restart persistence tamper scenario"* | [AuditReport1CoverageExtensionTests.testCheckoutTamperHashAfterPersistenceReload](repo/Tests/RailCommerceTests/AuditReport1CoverageExtensionTests.swift#L25-L58) — submit on `svc1`, rebuild `svc2` from the same store + keychain ("restart"), then tampered snapshot rejected with `.tamperDetected`. Durability rollback covered by [AuditReport2ClosureTests.testCheckoutPersistFailureLeavesNoSideEffects:183](repo/Tests/RailCommerceTests/AuditReport2ClosureTests.swift#L183) and [:417](repo/Tests/RailCommerceTests/AuditReport2ClosureTests.swift#L417). | **Addressed** |
| 3 | After-sales SLA / 14-day auto-reject boundary | *"add explicit day 13/day 14/day 15 tests"* | Day 13: [AuditClosureTests.testAutoRejectNotAppliedAt13DaysPast:53](repo/Tests/RailCommerceTests/AuditClosureTests.swift#L53). Day 14: [testAutoRejectAppliedAtExactly14DaysPast:70](repo/Tests/RailCommerceTests/AuditClosureTests.swift#L70). Day 15: [testAutoRejectAppliedAt15DaysPast:88](repo/Tests/RailCommerceTests/AuditClosureTests.swift#L88). All three boundary days pinned. | **Addressed** |
| 4 | Messaging moderation & abuse controls | *"add manual verification checklist for peer sessions"* | [repo/docs/peer-session-manual-verification.md](repo/docs/peer-session-manual-verification.md) — 7 numbered scenarios: first-run Local Network prompt, bonded-device pairing, discovery latency, pair drop/reconnect, spoofed-peer rejection, harassment auto-block, attachment-size cap. Each step names its static-test analogue and the real-device expectation. | **Addressed** |
| 5 | Multipeer sender spoof rejection | *"keep seam test in app target"* | [Tests/RailCommerceAppTests/MultipeerSpoofRejectionTests.swift](repo/Tests/RailCommerceAppTests/MultipeerSpoofRejectionTests.swift) — 8 tests, still in the iOS app target (runs under `xcodebuild test`). | **Addressed** |
| 6 | Seat inventory auth + identity binding + rollback | *"add lock-expiry boundary tests"* | Tight 900-second boundary triple: [SeatInventoryServiceTests.testReservationHoldBoundaryAt899SecondsIsStillReserved:58](repo/Tests/RailCommerceTests/SeatInventoryServiceTests.swift#L58), [testReservationHoldBoundaryAt900SecondsExpires:67](repo/Tests/RailCommerceTests/SeatInventoryServiceTests.swift#L67), [testReservationHoldBoundaryAt901SecondsIsDefinitelyExpired:79](repo/Tests/RailCommerceTests/SeatInventoryServiceTests.swift#L79). Clamps the inclusive/exclusive edge of `Reservation.expiresAt`. | **Addressed** |
| 7 | Role shell parity (CSR Returns visibility) | *"keep parity assertions as regression guard"* | [Tests/RailCommerceAppTests/SplitViewRoleParityTests.swift](repo/Tests/RailCommerceAppTests/SplitViewRoleParityTests.swift) — 8 tests including the dedicated CSR-Returns assertions at `:80` and `:102` that the report explicitly cited. Still present. | **Addressed** |
| 8 | Content unpublished visibility boundary | *"add negative test for non-privileged by-id enumeration attempts"* | [AuditReport2ClosureTests.testGetActingUserHidesDraftsFromCustomer:383](repo/Tests/RailCommerceTests/AuditReport2ClosureTests.swift#L383) — `svc.get(draftId, actingUser: customer)` returns `nil` (indistinguishable from missing). Companions: [testCustomerItemsVisibleReturnsOnlyPublished:357](repo/Tests/RailCommerceTests/AuditReport2ClosureTests.swift#L357), [testPrivilegedRolesItemsVisibleReturnsEverything:368](repo/Tests/RailCommerceTests/AuditReport2ClosureTests.swift#L368), [testGetActingUserAllowsPrivilegedRolesToReadDrafts:392](repo/Tests/RailCommerceTests/AuditReport2ClosureTests.swift#L392), [testPublishedItemsReturnsOnlyPublishedIrrespectiveOfCaller:401](repo/Tests/RailCommerceTests/AuditReport2ClosureTests.swift#L401). | **Addressed** |

**All 8 minimum-addition items: Addressed.**

---

## 3. §6 Security findings — regression check

Every item was **Pass** in the original report. Spot-verified all are still present:

| Security control | Source | Test |
| :-- | :-- | :-- |
| Credential enrollment + PBKDF2 policy | [CredentialStore.swift:106,122](repo/Sources/RailCommerce/Core/CredentialStore.swift#L106) | `CredentialStoreTests.swift`, `BiometricBoundAccountTests.swift` |
| Seat inventory admin guards | [SeatInventoryService.swift:99](repo/Sources/RailCommerce/Services/SeatInventoryService.swift#L99) | `AuditReport2ClosureTests.testCustomerCannotRegisterSeat` et al. |
| After-sales ownership + visibility | [AfterSalesService.swift:353,384](repo/Sources/RailCommerce/Services/AfterSalesService.swift#L353) | `AfterSalesIsolationTests.swift`, `AuditReport2ClosureTests.testAfterSalesGetRequiresOwnershipOrPrivilege` |
| Messaging visibility guard | [MessagingService.swift:192](repo/Sources/RailCommerce/Services/MessagingService.swift#L192) | `MessagingServiceTests.swift`, `ReportControlTests.swift` |
| Content role-aware visibility | [ContentPublishingService.swift:158,397](repo/Sources/RailCommerce/Services/ContentPublishingService.swift#L158) | `AuditReport2ClosureTests` §357-§407 block |
| Logger redaction | [Logger.swift:91](repo/Sources/RailCommerce/Core/Logger.swift#L91) | `LoggerTests.swift` |

**No regressions.**

---

## 4. Infrastructure / runner note

The original report cited `repo/run_ios_tests.sh:67` at [audit_report-2.md:49](.tmp/audit_report-2.md#L49). That file no longer exists — it was **intentionally consolidated into `run_tests.sh`** per commit `e52a9de` ("Consolidate test runner + push coverage to 98.60% regions / 99.50% lines"). The canonical runner now runs both stages in one invocation:

1. `swift test --enable-code-coverage` — portable library.
2. `xcodebuild test` on an iOS Simulator — app-layer tests (UIKit, Multipeer).

Non-macOS CI hosts skip cleanly with exit 0 (documented platform constraint — iOS Simulator is macOS-only). Not a regression — a strict-mode tightening to a single canonical entry point.

---

## 5. Quantitative change since audit-report-2 was written

| Metric | At report time | Now | Δ |
| :-- | :-: | :-: | :-: |
| Test files (library + iOS) | ~60 | 60 | 0 |
| `func test…` declarations | — | **730** | — |
| `XCTAssert*` calls | — | **1,376** | — |
| Dedicated runtime-contract suite | absent | `RuntimeConstraintsContractTests.swift` (6 tests) | **+1 file** |
| Peer-session manual-verification doc | absent | [docs/peer-session-manual-verification.md](repo/docs/peer-session-manual-verification.md) (7 scenarios) | **+1 file** |
| Promotion duplicate-code test | absent | `testDuplicateCodeInputRejectsSecondDeterministically` | **+1 test** |
| After-sales day 15 test | absent | `testAutoRejectAppliedAt15DaysPast` | **+1 test** |
| Seat hold boundary triple (899/900/901) | absent | 3 dedicated tests in `SeatInventoryServiceTests.swift` | **+3 tests** |
| Library coverage (README claim) | 96.96% region / 98.96% line | Commit `111efb1` reports **99.17% region / 99.50% line** | ↑ |
| Dual test runners (`run_ios_tests.sh` + `run_tests.sh`) | 2 | 1 (consolidated) | −1 (intentional) |

---

## 6. Final Verdict

| Item | Original verdict | Current status | Fix verdict |
| :-- | :-: | :-: | :-: |
| §4.1 Hard gates | Pass | Unchanged | **Still Pass** |
| §4.2.1 Coverage of explicit core requirements | Partial Pass | Runtime contracts pinned + manual checklist added | **Upgraded → Pass** |
| §4.5.1 Business / semantic fit | Partial Pass | Runtime portion now covered by manual checklist | **Upgraded → Pass** |
| §4.6.1 Visual / interaction quality | Cannot Confirm Statically | Unchanged (by definition not static-provable); covered by manual checklist | **Unchanged** |
| §5 Medium — runtime acceptance constraints | Open | Cold-start + memory-warning pinned; permission/pairing UX covered by manual checklist | **Closed** |
| §8.2 row 1 — duplicate promotion codes | Suggested | `testDuplicateCodeInputRejectsSecondDeterministically` added | **Closed** |
| §8.2 row 2 — restart persistence tamper | Suggested | `testCheckoutTamperHashAfterPersistenceReload` + keychain-seal rollback | **Closed** |
| §8.2 row 3 — day 13 / 14 / 15 boundary | Suggested | Three dedicated tests for day 13, exact day 14, day 15 | **Closed** |
| §8.2 row 4 — peer-session manual checklist | Suggested | `docs/peer-session-manual-verification.md` (7 real-device scenarios) | **Closed** |
| §8.2 row 5 — Multipeer seam test | Suggested | Still present in app target (8 tests) | **Closed** |
| §8.2 row 6 — seat lock-expiry boundary | Suggested | 899s / 900s / 901s triple pinned | **Closed** |
| §8.2 row 7 — role shell parity regression guard | Suggested | Still present (8 tests) | **Closed** |
| §8.2 row 8 — content by-id enumeration negative | Suggested | `testGetActingUserHidesDraftsFromCustomer` + 4 companion tests | **Closed** |

### Overall fix verdict: **PASS — all items addressed**

- The one open **Medium** severity finding (§5) is now closed: the static-provable side is pinned by `RuntimeConstraintsContractTests`, and the irreducibly-runtime side has an explicit manual-verification checklist that names each static-test analogue so the runtime steps stay synchronized with the code paths.
- All 8 §8.2 *"Minimum Test Addition"* suggestions are implemented in their literal form — not just in spirit.
- Two Partial Pass entries in §4.2.1 and §4.5.1 can be upgraded to **Pass**, because their outstanding portions were runtime constraints that the manual-verification checklist now explicitly covers.
- No regression surfaced in the §6 security findings.
- The only incidental drift worth noting is that `run_ios_tests.sh` was consolidated into `run_tests.sh`; the two `repo/run_ios_tests.sh:67/68` evidence links in the original report are stale paths but do not correspond to any missing functionality.

There are **no residual items** that block closure of audit-report-2.

---

## 7. Confidence & Assumptions

- **High** confidence on the presence of each cited test and doc — every reference was verified by opening the file at the stated line range.
- **Medium** confidence on the "coverage now 99.17% region / 99.50% line" number — taken from commit message `111efb1`, not re-executed under this static audit.
- Assumption: the manual-verification checklist (`docs/peer-session-manual-verification.md`) counts as addressing the "add manual verification checklist for peer sessions" minimum-addition, because its form matches exactly what the auditor asked for — a numbered, real-device walk-through that names its static-test analogue.
- Static-only audit: no builds, no simulator, no Docker ran.
