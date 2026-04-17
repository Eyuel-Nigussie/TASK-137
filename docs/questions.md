'# RailCommerce — Open Questions, Risks, and Assumptions

**Document version:** 1.0
**Date:** 2026-04-15
**Relates to:** `docs/design.md` v1.0

This document enumerates ambiguities, risks, and implicit decisions in
the design that need explicit confirmation before implementation is
considered complete. Each item includes a question, the assumption we
are proceeding under if no answer is given, and the concrete solution
we will implement under that assumption.

---

## Q1. The compiled-in credential registry in `LoginViewController`

**Question.** The login view controller carries a literal dictionary of
six username/password/role tuples, which is convenient for acceptance
testing but is readable by anyone with the build artifact. Is this a
staging-only seed or the intended shipping model?

**My understanding.** Staging-only seed. A real credential store is required
before the app ships to real users.

**solution.** Introduce a `CredentialStore` protocol with a
`KeychainCredentialStore` conformer that holds PBKDF2-SHA256 hashes
(≥ 310k iterations) plus per-user salt, scoped to a per-install pepper
in the Keychain. Seeding is done once at first launch from a bundled
plist present only in dev builds. The current in-memory dictionary is
kept behind `#if DEBUG` for simulator testing.

---

## Q2. `InMemoryKeychain.seal` has no equivalent on `Security.framework`

**Question.** `CheckoutService` seals order hashes by calling
`seal(_:)` on the in-memory keychain, which makes the key read-only.
The iOS Keychain has no "sealed item" concept, so the same call on
`SystemKeychain` would be a no-op. How do we preserve tamper-proofness
on real devices?

**My understanding.** Immutability in the in-memory store is a stand-in for
an application-level tamper-detection mechanism, not a Keychain ACL.

**solution.** Promote `seal(_:)` to the `SecureStore` protocol
with a default no-op. On `SystemKeychain`, implement sealing by storing
the hash alongside an HMAC-SHA256 signature keyed by a per-install
signer held at a well-known Keychain key. `verify(_:)` recomputes the
signature and fails on mismatch. This gives tamper detection without
requiring the Keychain to enforce immutability itself.

---

## Q3. No service uses `PersistenceStore` — the whole domain is in-memory

**Question.** A generic `PersistenceStore` protocol (with an
in-memory default and a Realm-backed stub) is defined in the core
layer, but no service references it. Every cart, order, seat state,
after-sales request, content item, and resume lives in a dictionary
that disappears on app termination. Is durability in scope for this
release?

**My understanding.** Durability matters for transactional state (orders,
seat reservations, after-sales requests, content items, delivered
messages, saved searches) but can be deferred for this release. The
`PersistenceStore` abstraction exists specifically so it can be wired
in later without touching service API.

**solution.** Keep services in-memory in this iteration and
document durability as a follow-up milestone. When wired, each service
gains a `PersistenceStore` dependency, hydrates lazily on first access,
mirrors writes synchronously, and exposes a `rebuildState()` for the
cold-boot test path. Realm conformance stays behind
`#if canImport(RealmSwift)` so the macOS CI build continues to use the
in-memory fallback.

---

## Q4. Duplicate-submission window is a literal 10 seconds

**Question.** `CheckoutService.submit` rejects a re-submission of the
same `orderId` within 10 seconds. The window is hard-coded. Is it a
double-tap guard, a uniqueness constraint, or both?

**My understanding.** It is a double-tap guard. Long-term uniqueness is
implicit in the fact that once a submission succeeds, the snapshot is
stored and the UI navigates away.

**solution.** Keep the 10-second window but also reject
*any* re-submission of an `orderId` that already has a stored
snapshot, regardless of elapsed time. Expose the window as a tunable
property on the service so walk-up kiosk deployments can lengthen it
without editing source.

---

## Q5. RxSwift streams are produced but never consumed outside tests

**Question.** Four services expose `events: Observable<E>` streams.
Tests subscribe to them; no view controller does. Either the UI layer
lags the domain layer, or RxSwift is dead weight.

**My understanding.** The streams are a real design intent — they are how
the UI reflects service state changes without polling — and the
current absence of subscriptions is UI-layer lag.

**solution.** Wire a minimal set of subscriptions in the
active tabs: cart refresh on checkout submit, after-sales list
refresh on open/resolve, seat cell recoloring on reserve/confirm,
message list append on queue drain. Each subscription is held in a
per-VC `DisposeBag` released in `deinit`. Do not bridge these events
into the local notification bus — that bus has a different contract
(Q7).

---

## Q6. `AttachmentService` stores synthetic paths, not actual files

**Question.** `AttachmentService.save` returns metadata with a synthetic
`"app://sandbox/…"` path and never writes bytes to disk. Is this the
final design, or a placeholder?

**My understanding.** Metadata-only storage is insufficient for any real
attachment use (displaying a photo, exporting a PDF). The current
implementation is a placeholder sufficient for retention-sweep unit
tests.

**solution.** Add real file I/O under
`…/Documents/attachments/{yyyy}/{mm}/{id}.{ext}` with
`FileProtectionType.complete`. Compute and store SHA-256 at save;
re-validate on read and throw a tamper error on mismatch. The
retention sweep deletes the on-disk file alongside the in-memory
entry. Keep the `app://` path for UI display and add a real `fileURL`
field for filesystem access.

---

## Q7. `LocalNotificationBus` is only used by `AfterSalesService`

**Question.** The bus is defined inside `AfterSalesService` and only
that service posts to it. Other services emit reactive events but not
user-visible notifications. Is the narrow scope intentional?

**My understanding.** Yes. OS-level notifications are interruptions; only
after-sales transitions (approvals, rejections, auto-approvals,
dispute resolutions) warrant them. Checkout success is already a
synchronous UI event; seat confirmation happens with the user present;
content publishing is back-office; messaging has its own badge.

**solution.** Keep the bus scoped to after-sales, but move
`LocalNotificationBus` to its own file (out of
`AfterSalesService.swift`) and document the promise: "Post only events
that a logged-out user should learn about on their lock screen." When
sales-agent workflows introduce customer-facing alerts (e.g.,
expiring reservations) they may also post, under a different
identifier prefix.

---

## Q8. Talent Matching is administrator-only today

**Question.** The acceptance audit flagged that CSR users could open
the Talent tab but not use it (the service enforces `.matchTalent`,
which CSR does not have). The tab-construction condition was narrowed
to `.matchTalent`, which leaves only administrators with access. Is
that the intended permission model?

**My understanding.** Yes. Talent matching is a specialty admin workflow
today; CSR must not see it; a dedicated staffing-coordinator role is
plausible future work but out of scope now.

**solution.** Keep the `.matchTalent`-only tab condition.
If a staffing-coordinator role is later introduced, grant it
`.matchTalent` along with whatever else it needs; the tab condition
already keys on the permission, not the role, so no app-layer change
is required.

---

## Q9. `AppLifecycleService` exists but is not wired from `AppDelegate`

**Question.** The lifecycle service handles memory warnings and
cold-start timing, but `AppDelegate` neither captures a launch
timestamp nor forwards memory-warning events into it. The service is
unit-tested in isolation but unused in the app.

**My understanding.** This is pending wiring, not a deliberate omission.

**solution.** Capture `launchBegin` at the top of
`didFinishLaunchingWithOptions`, and after the window becomes key &
visible, mark the cold start. Implement
`applicationDidReceiveMemoryWarning` as a one-liner that forwards to
the service. Surface the counters (cold-start millis, cache evictions,
memory warnings) on an administrator-only Diagnostics screen — no
automatic export.

---

## Q10. No persistent audit trail for any service

**Question.** Every mutating method accepts `actingUser` and enforces
a permission, but no service records "who did what when" in an
immutable form. The acceptance audit flagged this as a medium-severity
finding. Is compliance-grade, hash-chained audit required?

**My understanding.** Not for this release. A lightweight, append-only
activity log — in-memory for the session, persisted alongside domain
state once Q3 is resolved — is sufficient for operator visibility.
Hash chaining can layer on later if a compliance requirement appears.

**solution.** Introduce an `ActivityLog` protocol with a
single `InMemoryActivityLog` conformer, wired through the composition
root. Each service records an entry at the bottom of every successful
mutation (checkout submit, seat reserve/confirm/release, after-sales
transitions, content approve/reject, message enqueue). Reads are not
logged. The persistence path is the same `PersistenceStore` that Q3
introduces.

---

## Q11. UX polish backlog from the acceptance audit

**Question.** The audit called out Dynamic Type applied only to the
login screen, missing VoiceOver labels in the tab contents, sparse
empty states, and inconsistent haptics. These are enumerable but
priorities are not specified.

**My understanding.** Accessibility basics (Dynamic Type, VoiceOver on
every interactive control, 44×44 pt hit targets) are must-have
because they affect App Store review and real users with
accessibility needs. Haptics and empty-state polish are nice-to-have.

**solution.** Apply `adjustsFontForContentSizeCategory` to
every label and text field across every view controller; audit colors
so only semantic `UIColor` values appear; set `accessibilityLabel` and
`accessibilityHint` on every bar-button, action button, and switch;
fire success haptics on every successful write path and error haptics
on every thrown `AuthorizationError`. Defer iPad split-view tuning to
a later iteration — the current information density works acceptably
in both size classes.

---

## Q12. RxSwift is a full package dependency for a narrow use

**Question.** RxSwift 6.6.x is pulled just so four services can expose
`PublishSubject`-backed observables. The dependency adds ~60 MB of
git mirror on first fetch and non-trivial compile time. Combine is
available on every supported platform (iOS 16+/macOS 12+). Is the
RxSwift dependency justified?

**My understanding.** The dependency is historical, not load-bearing. Once
the UI consumes event streams (Q5), migrating to Combine is a
mechanical refactor.

**solution.** Plan the Combine migration as a follow-up:
`PublishSubject` → `PassthroughSubject`, `Observable<E>` →
`AnyPublisher<E, Never>`, `DisposeBag` → `Set<AnyCancellable>`. Drop
the RxSwift package and product references from the manifest. Confirm
in advance that no test relies on an RxSwift-specific combinator
before making the swap.

---

## Q13. `SeatInventoryService.atomic` does not surface what was rolled back

**Question.** On any throw inside an atomic block, the service rolls
back all state and reservation changes and rethrows the original
error. Callers learn only the error — they do not learn which seats
were reverted or which reservations were cleared. For a sales agent
running a multi-seat block, that loss of detail is a UX hole.

**My understanding.** The current throw-and-rollback is correct. Better UX
is possible but not required by the current caller (tests).

**solution.** Accept an optional `onRollback` closure on
`atomic`, invoked with a summary of touched seat keys, their restored
states, and cleared reservation ids. The view controller uses the
summary to render a toast describing the rollback. Tests continue to
call `atomic` with no closure.

---

## Q14. Business-time SLA is calendared in fixed UTC

**Question.** `BusinessTime` uses a fixed-UTC calendar with 9 am–5 pm
business hours. The 4-business-hour first-response and
3-business-day resolution deadlines are therefore measured in UTC,
not in the CSR's operating time zone. For a Pacific-time team, "due
in 4 business hours from 01:00 UTC" starts counting before anyone is
at a desk.

**My understanding.** UTC was chosen for test determinism, not as a
business decision. Real operations need a configurable time zone.

**solution.** Make `BusinessTime` instance-based with a
caller-supplied time zone, start/end hours, and business-days set,
defaulting to `.current`. `AfterSalesService` accepts the instance at
construction time. Tests continue to pass a fixed-UTC instance for
determinism. This also leaves room for per-deployment SLA tuning
later.

---

## Q15. Multi-tenancy is explicitly excluded — do we reserve fields now?

**Question.** The design is single-tenant. Should every entity
reserve a `tenantId` field now to avoid a disruptive migration if
multi-tenancy is introduced later?

**My understanding.** No. Reserving `tenantId` on every record now is
premature: it adds complexity to every service, test, and serialized
form for a feature that may never be needed. Single-tenant operation
cannot produce ID collisions.

**solution.** Leave the schema alone. If multi-tenant
support is ever introduced, every entity gains a `tenantId` alongside
its primary id and every service takes a tenant context that scopes
queries. The migration is mechanical but contained, and doing it
speculatively now is pure waste.

---

## Q16. Content approval has no reviewer-identity enforcement

**Question.** Approving or rejecting a content item requires
`.publishContent`, but the service does not record which reviewer
decided, nor prevent a reviewer from approving their own draft. An
administrator (holding both `.draftContent` and `.publishContent`)
could create and approve the same item in one session.

**My understanding.** Administrators are trusted with both roles by design;
separation of duties applies only within non-admin roles (editor ≠
reviewer). Tracking reviewer identity is nonetheless useful for the
activity log (Q10).

**solution.** Record `approvedBy`, `approvedAt`,
`rejectedBy`, and `rejectedAt` on the content item at the decision
call site. For non-admin reviewers, enforce that the approver is not
the editor of the initial draft and throw a dedicated error
otherwise. Administrators are exempted from that check.

---

## Q17. Sensitive-data scanner is narrow by design

**Question.** The scanner detects only US SSNs and payment card
numbers. It does not catch passports, driver's licenses, tax IDs,
medical record numbers, or non-US national IDs. Is the narrowness
intentional?

**My understanding.** Yes. The two highest-risk categories for a US rail
commerce app (identity theft vector and PCI) are in scope; every
additional pattern increases false positives and message-enqueue
latency. More categories should be added only in response to a
concrete incident or compliance requirement.

**solution.** Keep the scanner as-is. If more categories
are added later, expose the pattern list as a mapping on the scanner
so future additions do not require rewriting the scanner itself.
Document in the method comment that the scanner is best-effort and
does not replace end-user training or dedicated data-classification
tooling.

---

## Q18. `Cart.bundleSuggestions` recomputes from scratch on every call

**Question.** The algorithm scans every bundle SKU in the catalog on
every call. For small catalogs that is fine; for catalogs with
hundreds of bundles it could become a per-render cost in the cart
view. Is lazy recomputation enough, or do we need a cached index?

**My understanding.** Current catalog sizes are small — the seeded catalog
has six SKUs, one of which is a bundle. Lazy recomputation is
adequate.

**solution.** No change today. If the catalog grows past
~500 bundles, introduce a reverse index mapping SKU ids → bundle ids
that include them; suggestions iterate only bundles reachable from
the current cart. Until that scale, the simpler loop wins on
maintainability.

---

## Q19. No mechanism to end an authenticated session

**Question.** Once a user logs in, the `User` is retained by the tab
bar controller for the process lifetime. There is no sign-out
affordance, no idle timer, and no admin-driven invalidation. Is that
the intended model for an offline app?

**My understanding.** Yes for an offline single-user app. A session ends
when the process is reclaimed by iOS or when the user explicitly
signs out. Idle timeouts belong on shared-device kiosks, which this
is not.

**solution.** Add a Sign Out bar-button item to every tab's
navigation bar. Tapping it presents the login screen modally
full-screen and releases the tab bar controller. No idle timer is
implemented.

---

## Q20. First clean build requires network access for RxSwift

**Question.** The package manifest pulls RxSwift from its GitHub
mirror, which means a first clean build on any machine must fetch
~60 MB before linking. Air-gapped CI environments cannot build.

**My understanding.** CI machines can cache SPM dependencies after the
first run and air-gapped environments are not a current constraint.

**solution.** Document in the repository README that a
first clean build requires network access and that subsequent builds
are offline once the SPM cache is populated. Commit `Package.resolved`
to pin the exact RxSwift version so the fetch is deterministic
across machines. If Q12 (Combine migration) lands, this question
disappears entirely.

---

*End of questions document. Items without explicit answers will be
implemented under the stated assumption.*
'