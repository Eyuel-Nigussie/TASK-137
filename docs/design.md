# RailCommerce — Offline Rail Ticket & Merchandise iOS App System Design

**Document version:** 2.0
**Date:** 2026-04-16
**Target platform:** iOS 16+ (primary), macOS 12+ (library portability)
**Language:** Swift 5.7
**UI Framework:** UIKit (no SwiftUI)
**Build system:** Swift Package Manager
**Deployment model:** Fully offline, on-device, single-tenant

---

## 1. Overview

RailCommerce is a native Swift iOS application for selling rail tickets,
merchandise, and bundles to customers while simultaneously supporting the
back-office workflows of sales agents, content editors/reviewers, customer
service, and administrators. Every capability required to transact —
catalog browsing, cart management, promotion evaluation, seat reservation,
checkout, after-sales requests, content publishing, staff messaging, talent
matching, and attachment retention — is performed entirely on the device.

The project is structured as a Swift Package with three products: a pure
`RailCommerce` library (platform-agnostic business logic), a
`RailCommerceApp` library (UIKit view controllers, iOS-only via
`#if canImport(UIKit)`), and a `RailCommerceDemo` executable (CLI harness).
This separation is deliberate: the library compiles on both macOS and Linux
CI targets and carries no UIKit dependency, enabling fast unit testing of
the full domain layer without a simulator.

### 1.1 Roles

Implemented in `Models/Roles.swift` as the `Role` enum; the matrix of role →
`Permission` authorizations lives in `RolePolicy.matrix`.

| Role | Permissions granted |
|---|---|
| `customer` | `browseContent`, `purchase`, `manageAfterSales` |
| `salesAgent` | `browseContent`, `processTransaction`, `manageInventory` |
| `contentEditor` | `browseContent`, `draftContent` |
| `contentReviewer` | `browseContent`, `reviewContent`, `publishContent` |
| `customerService` | `browseContent`, `handleServiceTickets`, `sendStaffMessage`, `manageAfterSales` |
| `administrator` | all thirteen permissions (super-user, includes `manageMembership`) |

### 1.2 Primary use cases

1. A **customer** browses the SKU catalog filtered by taxonomy (region,
   theme, rider type), adds tickets and merchandise to a cart, accepts a
   bundle suggestion, applies promotions, checks out against a saved
   address and shipping template, and receives a sealed, tamper-detectable
   order snapshot.
2. A **customer** opens an after-sales request (refund-only, exchange, or
   service claim). Automation auto-approves small refunds (< $25, no
   dispute) after 48 hours and auto-rejects requests older than 14 days
   past the service date.
3. A **sales agent** atomically reserves and confirms a block of seats for
   a walk-in transaction. A snapshot/rollback mechanism guarantees
   inventory integrity when any step in a multi-seat block fails.
4. A **content editor** drafts a travel advisory; a **content reviewer**
   approves it or schedules it for publication. Scheduled publishes are
   deferred when the device is in low-power mode and resume when battery
   state recovers.
5. **CSR** staff exchange messages. The messaging service masks customer
   contact information in free-text bodies, blocks messages containing
   SSNs or payment card numbers, enforces a 3-strike harassment filter,
   and caps attachment sizes at 10 MB per file.
6. An **administrator** imports resumes into the Talent Matching service
   and executes weighted boolean searches to staff specialty routes.

### 1.3 Out of scope

- Real-time networking, remote payment processing, push notifications
  from a backend, server-driven analytics, or cloud sync.
- SSO, OAuth, phone/email verification, or any external identity provider.
- Server-side audit; all state lives in-memory/Keychain on the device.
- Multi-tenancy. The app serves a single operating organization per
  install.

---

## 2. Architecture

### 2.1 Layering

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation (UIKit)                      │
│   LoginViewController · MainTabBarController · View layer    │
│    BrowseVC · CartVC · CheckoutVC · SeatInventoryVC          │
│    AfterSalesVC · ContentPublishingVC · MessagingVC          │
│    TalentMatchingVC                                          │
└─────────────────────────────────────────────────────────────┘
                               │
┌─────────────────────────────────────────────────────────────┐
│                  Domain Services (platform-free)             │
│ Cart · CheckoutService · PromotionEngine · OrderHasher       │
│ AfterSalesService · SeatInventoryService                     │
│ ContentPublishingService · MessagingService                  │
│ AttachmentService · TalentMatchingService                    │
│ AppLifecycleService                                          │
└─────────────────────────────────────────────────────────────┘
                               │
┌─────────────────────────────────────────────────────────────┐
│                    Core Abstractions                         │
│ Clock · BiometricAuthProvider · SecureStore                  │
│ PersistenceStore · CameraPermission · BatteryMonitor         │
│ RolePolicy · LocalNotificationBus · BusinessTime             │
│                                                              │
│              Models: User · Role · Permission                │
│  SKU · Catalog · Cart · Address · TaxonomyTag · USState      │
└─────────────────────────────────────────────────────────────┘
                               │
┌─────────────────────────────────────────────────────────────┐
│              Platform Providers (iOS only)                   │
│ SystemClock · SystemKeychain (Security.framework)            │
│ SystemCamera (AVFoundation) · SystemBattery (UIDevice)       │
│ LocalBiometricAuth (LocalAuthentication)                     │
│ UNUserNotificationCenter bridge                              │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Package / target layout

```
Package.swift                       # swift-tools 5.7, platforms: macOS 12+, iOS 16+
├── Sources/
│   ├── RailCommerce/               # platform-free library
│   │   ├── RailCommerce.swift      # composition root (umbrella DI container)
│   │   ├── Core/
│   │   │   ├── Authorization.swift
│   │   │   ├── BiometricAuth.swift
│   │   │   ├── BusinessTime.swift
│   │   │   ├── Clock.swift
│   │   │   ├── KeychainStore.swift
│   │   │   ├── PersistenceStore.swift
│   │   │   └── ReactiveEvents.swift
│   │   ├── Models/
│   │   │   ├── Address.swift
│   │   │   ├── Catalog.swift
│   │   │   ├── Roles.swift
│   │   │   └── Taxonomy.swift
│   │   └── Services/
│   │       ├── Cart.swift
│   │       ├── CheckoutService.swift
│   │       ├── PromotionEngine.swift
│   │       ├── OrderHasher.swift
│   │       ├── AfterSalesService.swift
│   │       ├── SeatInventoryService.swift
│   │       ├── ContentPublishingService.swift
│   │       ├── MessagingService.swift
│   │       ├── AttachmentService.swift
│   │       ├── TalentMatchingService.swift
│   │       └── AppLifecycleService.swift
│   ├── RailCommerceApp/            # iOS UIKit layer (#if canImport(UIKit))
│   │   ├── AppDelegate.swift
│   │   ├── LoginViewController.swift
│   │   ├── MainTabBarController.swift
│   │   ├── SystemKeychain.swift
│   │   ├── SystemProviders.swift   # SystemCamera, SystemBattery
│   │   └── Views/
│   │       ├── BrowseViewController.swift
│   │       ├── CartViewController.swift
│   │       ├── CheckoutViewController.swift
│   │       ├── AfterSalesViewController.swift
│   │       ├── SeatInventoryViewController.swift
│   │       ├── ContentPublishingViewController.swift
│   │       ├── MessagingViewController.swift
│   │       └── TalentMatchingViewController.swift
│   └── RailCommerceDemo/
│       └── main.swift              # CLI smoke-test harness
└── Tests/RailCommerceTests/        # XCTest (24 files)
```

### 2.3 Dependencies

- **RxSwift 6.6.x** (external) — reactive event streams exposed by services
  (`CheckoutService.events`, `AfterSalesService.events`, etc.) using
  `PublishSubject` under the hood.
- **LocalAuthentication** (system, iOS only, conditionally imported) —
  Face ID / Touch ID.
- **Security** (system, iOS only) — Keychain item storage for
  tamper-sealed order hashes.
- **AVFoundation** (system, iOS only) — camera permission check.
- **UIKit / UserNotifications** (system, iOS only) — presentation + local
  notification delivery.

### 2.4 Composition root

`RailCommerce` (the class in `Sources/RailCommerce/RailCommerce.swift`)
acts as an umbrella dependency container. Its initializer takes four
protocol-typed providers — `Clock`, `SecureStore`, `CameraPermission`,
`BatteryMonitor` — and constructs every service with its required
dependencies already wired. Tests construct it with
`FakeClock`/`InMemoryKeychain`/`FakeCamera`/`FakeBattery`; `AppDelegate`
constructs it with `SystemClock`/`SystemKeychain`/`SystemCamera`/
`SystemBattery`.

A single shared `Cart` instance lives on the `RailCommerce` container so
that `BrowseViewController` (which adds SKUs) and `CartViewController`
(which reads them) share state across navigation.

### 2.5 Threading model

All services are **single-threaded** and invoked from the UIKit main
thread. This is an intentional simplification for an offline,
single-user, single-device app — the cost of contention-free mutations
outweighs the benefits of parallelism for the workloads involved
(100s of SKUs, not millions). The reactive event streams use RxSwift's
default scheduler (the current thread); subscribers do not schedule off
main.

Two exceptions:

- **`AppLifecycleService`** records cold-start timing against a 1.5 s
  budget and is the single point that may receive memory-warning
  notifications from `UIApplicationDelegate`.
- **Hash computation** (`OrderHasher`) is a pure SHA-256 Swift
  implementation that runs synchronously on the calling thread. For the
  current catalog scale (10s of cart lines), this is sub-millisecond.

### 2.6 Navigation

- On launch, `AppDelegate` presents `LoginViewController`.
- After authentication, `LoginViewController` presents
  `MainTabBarController` modally full-screen. Tabs are role-aware (built
  in `buildTabs()` against `RolePolicy.can`):
  - **Browse** — always present.
  - **Cart / Seats / Returns** — if role has `.purchase`.
  - **Inventory** — if role has `.processTransaction` (sales agents).
  - **Content** — if role has `.draftContent` or `.publishContent`.
  - **Talent** — if role has `.matchTalent` (currently administrator only).
  - **Messages** — always present.
- Each tab wraps its root view controller in a `UINavigationController`
  for push/pop flows.

---

## 3. Domain Model

### 3.1 Identity & Access

**`User`** (`Sources/RailCommerce/Models/Roles.swift`)
```swift
public struct User: Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let role: Role
}
```

**`Role`** — six-case enum (customer, salesAgent, contentEditor,
contentReviewer, customerService, administrator).

**`Permission`** — twelve-case enum. Mapped to roles by
`RolePolicy.matrix: [Role: Set<Permission>]`.

**`RolePolicy`** — static helpers:
- `can(_ role: Role, _ p: Permission) -> Bool`
- `enforce(user: User, _ p: Permission) throws`
  (throws `AuthorizationError.forbidden(required:)`)

Every mutating service method takes an `actingUser: User` (non-optional)
and guards the call at the top of the method. There is no
implicit/ambient caller identity — authorization is always explicit.

### 3.2 Catalog

**`SKU`** — `id`, `kind` (`.ticket` | `.merchandise` | `.bundle`),
`title`, `priceCents`, `tag: TaxonomyTag`, `bundleChildren: [String]`.

**`Catalog`** — mutable keyed map `[String: SKU]`; `upsert`, `remove`,
`get`, `all`, `filter(by: TaxonomyTag)`.

**`TaxonomyTag`** — optional `Region` (northeast, midwest, south, west,
pacific) + `Theme` (scenic, business, family, foodie, heritage, eco) +
`RiderType` (commuter, tourist, student, senior, member). A tag matches
a filter iff every non-nil filter component equals the tag component.

### 3.3 Address

**`USAddress`** — `id`, `recipient`, `line1/2`, `city`,
`state: USState` (50-case enum), `zip: String`, `isDefault: Bool`.

**`AddressBook`** — keyed map; `save`, `remove`, `defaultAddress`.

**`AddressValidator`** — ZIP regex `^\d{5}(-\d{4})?$`, trimmed non-empty
line1 and city.

### 3.4 Cart & Orders

**`Cart`** — lines: `[CartLine { sku: SKU, quantity: Int, notes: String? }]`.
Methods: `add(skuId:quantity:notes:)`, `update`, `remove`, `clear`,
`bundleSuggestions()`.

**`OrderSnapshot`** (produced by `CheckoutService.submit`) — frozen view
of the transaction: `orderId`, `userId`, `lines`, `address`, `shipping`,
`promotion: PromotionResult`, `totalCents`, `hash`, `createdAt`. Stored
in-memory and the `hash` is sealed in the `SecureStore` (Keychain).

### 3.5 Other entity types (summary)

| Entity | Location | Purpose |
|---|---|---|
| `Discount` | `PromotionEngine.swift` | Promo code with `kind` (`.percentOff`/`.amountOff`/`.freeShipping`), `magnitude`, `priority`, optional `restrictedSkuIds` |
| `PromotionResult` | `PromotionEngine.swift` | Accepted/rejected codes, per-line explanations, `freeShipping`, `finalCents` |
| `SeatKey` | `SeatInventoryService.swift` | `trainId` × `date` × `segmentId` × `seatClass` × `seatNumber` |
| `Reservation` | `SeatInventoryService.swift` | `holderId`, `expiresAt` (clock.now + 15 min) |
| `AfterSalesRequest` | `AfterSalesService.swift` | `id`, `orderId`, `kind`, `reason`, `serviceDate`, `amountCents`, `status` |
| `ContentItem` | `ContentPublishingService.swift` | `kind` (travelAdvisory, onboardOffer, …), `status`, versions[], currentVersion |
| `Message` / `MessageAttachment` | `MessagingService.swift` | `fromUserId`, `toUserId`, `body`, `attachments`, `createdAt`, `deliveredAt?` |
| `StoredAttachment` | `AttachmentService.swift` | `id`, `sizeBytes`, `kind` (jpeg/png/pdf), `storedAt`, `sandboxPath` |
| `Resume` | `TalentMatchingService.swift` | `skills[]`, `yearsExperience`, `certifications[]`, `tags[]` |
| `TalentSearchCriteria` | `TalentMatchingService.swift` | `wantedSkills`, `wantedCertifications`, `desiredYears`, `filter: BooleanFilter` |

### 3.6 Persistence

Every domain service persists through the `PersistenceStore` protocol.
On iOS this is wired to a Realm-backed store with a 64-byte Keychain-derived
encryption key; on macOS/Linux CI it falls back to `InMemoryPersistenceStore`.

- **`SecureStore`** (`Core/KeychainStore.swift`) — backed by
  `InMemoryKeychain` (default/tests) or `SystemKeychain` (iOS,
  `Security.framework` generic-password items scoped to
  `Bundle.main.bundleIdentifier`, protection class
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Used by
  `CheckoutService` to store order hashes and by `BiometricBoundAccount`
  to bind biometric unlock to a specific user account.
- **`PersistenceStore`** (`Core/PersistenceStore.swift`) — a generic
  key/prefix-scoped store with an `InMemoryPersistenceStore` default and
  a Realm-backed implementation (`RealmPersistenceStore`) gated by
  `#if canImport(RealmSwift)`. Wired into `CheckoutService`,
  `AfterSalesService`, `SeatInventoryService`, `ContentPublishingService`,
  `MessagingService`, `AttachmentService`, `TalentMatchingService`,
  `MembershipService`, and `AddressBook`. Every mutation is persisted
  immediately; every service hydrates its store on init.

### 3.7 Event buses

Two parallel event surfaces exist:

- **RxSwift `Observable<E>`** on selected services: `CheckoutService.events:
  Observable<CheckoutEvent>`, `AfterSalesService.events`,
  `SeatInventoryService.events`, `MessagingService.events`. Emitted via
  internal `PublishSubject`. Enum cases are defined in
  `Core/ReactiveEvents.swift`.
- **`LocalNotificationBus`** (`AfterSalesService.swift`) — a lightweight
  append-only `[String]` ring with an `onPost: ((String) -> Void)?`
  callback. Only `AfterSalesService` currently posts to it.
  `AppDelegate` wires `onPost` to `UNUserNotificationCenter.add(...)` so
  significant after-sales transitions surface as OS-level local
  notifications.

---

## 4. Authentication, Session & Access Control

### 4.1 Local credentials

`LoginViewController` authenticates against the `CredentialStore` protocol,
backed in production by `KeychainCredentialStore` (PBKDF2-SHA256, 310k
iterations, per-user salt, Keychain-held pepper; records stored at the
generic-password items scoped to the app bundle id). Fixture users for the
six roles are seeded **only in `#if DEBUG`** builds; production deployments
are expected to seed via MDM enrollment.

Validation rejects empty username or password, shows a red `errorLabel` on
mismatch, and fires a `UINotificationFeedbackGenerator` haptic
(`.error` / `.success`). On success, the matched `User` is passed to the
role-aware shell (tab bar on iPhone / split view on iPad) and drives every
downstream authorization check.

### 4.2 Biometrics

`BiometricAuthProvider` (`Core/BiometricAuth.swift`) has two
implementations:

- **`LocalBiometricAuth`** — `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
  localizedReason:)`. Available only when `#if canImport(LocalAuthentication)`.
- **`FakeBiometricAuth`** — test double with configurable `isAvailable`
  and `succeeds` flags.

`LoginViewController` selects the right implementation at init time via
`#if canImport(LocalAuthentication)`. Biometric unlock is **account-bound**
by `BiometricBoundAccount` (`Core/BiometricBoundAccount.swift`): after each
successful password `verify()`, the username is written to a dedicated
Keychain slot. On a biometric tap, `BiometricBoundAccount.resolveUnlock`
rejects the attempt unless the bound username matches the typed field (or
the field is empty). The device owner's biometric cannot authenticate into
any account that has not already been password-verified on the device.
Switching accounts requires explicit password re-entry.

### 4.3 Session model

The only persistent session state is the **bound username** written by
`BiometricBoundAccount.bind` after a successful password login. The bound
username is a convenience binding, not an authentication token — every
session still requires either a password or a biometric unlock. Terminating
or backgrounding the app returns the user to `LoginViewController`, which
re-enforces credentials.

### 4.4 Role-based access control

Every mutating service method:

1. Takes `actingUser: User` as a **non-optional** parameter.
2. Calls `try RolePolicy.enforce(user: actingUser, .permissionName)` or
   an inline `guard RolePolicy.can(...)` on its first line.
3. Throws `AuthorizationError.forbidden(required: .permissionName)` on
   failure.

Examples of the enforcement pattern:

| Service method | Required permission(s) |
|---|---|
| `CheckoutService.submit` | `.purchase` **or** `.processTransaction` |
| `AfterSalesService.open` | `.manageAfterSales` |
| `AfterSalesService.approve` / `.reject` | `.handleServiceTickets` |
| `SeatInventoryService.reserve` / `.confirm` | `.purchase` **or** `.processTransaction` |
| `ContentPublishingService.createDraft` / `.edit` | `.draftContent` |
| `ContentPublishingService.approve` / `.reject` / `.schedule` | `.publishContent` |
| `MessagingService.enqueue` | `.browseContent` (universal floor) |
| `TalentMatchingService.search(_:by:)` | `.matchTalent` |

Read-only methods that could leak cross-user data take an **ownership
scope** parameter. For example, `CheckoutService.order(_:ownedBy:)`
returns `nil` if the snapshot's `userId` does not match the supplied id,
while the internal `order(_:)` is package-private for local tests only.

### 4.5 Extensibility

`BiometricAuthProvider` is a protocol, and the production implementation
is picked by conditional compile. Adding a new factor (e.g. passkey,
PIN) is a matter of adding another conformance and wiring it into
`LoginViewController.init(app:)`. The `RolePolicy` matrix is a
compile-time constant — adding a permission means extending the
`Permission` enum and augmenting the matrix. No runtime
role/permission editing is supported in this build.

---

## 5. Commerce Pipeline

### 5.1 Cart

`Cart` is a single shared instance created by the `RailCommerce`
composition root (`self.cart = Cart(catalog: catalog)`) and accessed by
all view controllers through `app.cart`. This guarantees that
`BrowseViewController.didSelectRowAt` → `cart.add(...)` is visible in
`CartViewController.viewWillAppear` → `tableView.reloadData()`.

Bundle suggestions (`Cart.bundleSuggestions()`) inspect every bundle SKU
in the catalog, compute the subset of its children already owned by the
cart, and surface the bundle when the missing complement would be
cheaper as a bundle than priced individually.

### 5.2 Promotion engine

`PromotionEngine.apply(cart:discounts:)` is **pure** and deterministic:

1. Discounts are sorted by `(priority asc, code asc)` so identical
   inputs always produce identical outputs.
2. At most **3 discounts** are accepted per transaction; extras are
   rejected with `PromotionRejectionReason.tooManyDiscounts`.
3. At most **one percent-off** discount applies per transaction.
   Subsequent percent-off codes are rejected with `.cannotStackPercent`.
4. `amountOff` discounts distribute across affected lines in proportion
   to their pre-discount subtotal, rounding with banker's rules so the
   sum of line discounts exactly equals the discount magnitude (no
   fractional cent drift).
5. `freeShipping` sets a flag on the result; shipping fee is zeroed by
   `CheckoutService` based on that flag.
6. Validation rejects out-of-range magnitudes (percent outside 1–100,
   amount ≤ 0) with `.invalidMagnitude`.

Returns `PromotionResult` with `acceptedCodes`, `rejectedCodes`,
`rejectionReasons`, `lineExplanations: [LineExplanation { lineId,
discountedCents, contributingCodes }]`, and `freeShipping`.

### 5.3 Checkout

`CheckoutService.submit(orderId:userId:cart:discounts:address:shipping:
invoiceNotes:actingUser:)` is the single integration point for order
creation:

1. **Authorization** — `.purchase` or `.processTransaction` required.
2. **Cart validation** — empty cart → `.emptyCart`.
3. **Shipping** — non-ticket cart requires `shipping != nil`; else
   `.noShipping`.
4. **Address validation** — `AddressValidator.validate` must pass; else
   `.addressInvalid`.
5. **Promotion application** — delegates to `PromotionEngine.apply`.
6. **Idempotency / duplicate-submission guard** — `recentSubmissions:
   [String: Date]` records each submitted `orderId`; a resubmission
   within 10 seconds throws `.duplicateSubmission`. This defends
   against accidental double taps on the UI's submit button.
7. **Total calculation** — line discount totals + shipping fee (zero if
   `freeShipping`) + any invoice-note fees.
8. **Hashing** — `OrderHasher.hash(canonicalSnapshot(...))` produces a
   hex SHA-256 over a canonicalized field list (sorted keys, stable
   serialization) to make tamper detection deterministic.
9. **Keychain sealing** — the hash is stored at key
   `"checkout.order.\(orderId).hash"` via `SecureStore.set`, and the
   key is sealed (`InMemoryKeychain.seal`) so further writes throw
   `SecureStoreError.readOnly`. See `questions.md` Q4 for how this maps
   to the real iOS Keychain (which has no inherent `seal`).
10. **Event emission** — publishes
    `CheckoutEvent.orderSubmitted(orderId:)` on `events` (RxSwift).
11. Returns the `OrderSnapshot`.

`verify(_ snap:)` recomputes the hash of the snapshot, fetches the
sealed hash from Keychain by `orderId`, and throws
`CheckoutError.tamperDetected` on mismatch.

### 5.4 Seat inventory

`SeatInventoryService` models seat lifecycle as a three-state machine
per `SeatKey`: `available` → `reserved` → `sold` (plus `released` as a
transient pre-state for recall).

- **`reserve(_:holderId:actingUser:)`** — transitions `available` →
  `reserved`; records a `Reservation { holderId, expiresAt }` with
  `expiresAt = clock.now() + 15 min`.
- **`confirm(_:holderId:actingUser:)`** — transitions `reserved` →
  `sold`, validates `holderId` matches, rejects if `expiresAt` is past.
- **`release(_:holderId:)`** — transitions `reserved` → `available`.
- **`sweepExpired()`** — reclaims expired reservations.
- **`atomic(_ work:)`** — captures a backup of `states` and
  `reservations`; runs `work`; on any thrown error, restores both maps
  verbatim. This is the primary mechanism for multi-seat sales: the
  caller may reserve and confirm several seats within a single block,
  and a failure at any step leaves inventory untouched.
- **`snapshot(date:)`** and **`rollback(to: date)`** — support an audit
  restore path (e.g., to recover from a corrupt batch of confirmations).

Authorization: `.purchase` covers customer self-service (one seat at a
time); `.processTransaction` covers agents performing multi-seat blocks.

### 5.5 After-sales

`AfterSalesService` runs the returns / exchanges / claims workflow:

- **`open(_:actingUser:)`** — customer (or admin) submits an
  `AfterSalesRequest`; posts `afterSales.opened:{id}` to
  `LocalNotificationBus` and emits `.requestOpened` on the RxSwift
  stream.
- **`respond(id:)`** — CSR records the first response; sets
  `firstResponseAt` used to measure the 4-business-hour SLA.
- **`approve(id:actingUser:)` / `reject(id:actingUser:)`** — requires
  `.handleServiceTickets`; moves the request to a terminal state.
- **`dispute(id:)`** — customer pushback; prevents the 48h auto-approve
  path.
- **`runAutomation()`** — executes in a bounded scan:
  - Auto-rejects any request with `serviceDate > 14 days in the past`.
  - Auto-approves `refundOnly` requests with `amountCents < 2500` that
    have been untouched (no dispute, no manual approval) for 48 hours
    after opening.
  - Returns the ids of state-changed requests so a caller (today,
    test-only) can log them.

SLA math uses `BusinessTime` (a fixed-UTC calendar with 9 am–5 pm
business hours); breaches are exposed via `sla(for:)` returning
`AfterSalesSLA { firstResponseDue, firstResponseBreached,
resolutionDue, resolutionBreached }`.

---

## 6. Content Publishing

`ContentPublishingService` manages `ContentItem`s (travel advisories,
onboard offers, etc.) through a two-stage review workflow:

1. **`createDraft(actingUser:)`** — `.draftContent` required. Produces
   a `ContentItem` with status `.draft` and version `1`.
2. **`edit(actingUser:)`** — `.draftContent` required. Appends a new
   version; version history is capped at **10** (oldest dropped).
3. **`submitForReview(id:)`** — moves `.draft` → `.inReview`. No
   authorization required beyond ability to mutate the draft.
4. **`approve(id:reviewer:)` / `reject(id:reviewer:)`** — requires the
   reviewer to have `.publishContent`. Note that this permission is
   granted to `contentReviewer` and `administrator`, but *not* to the
   `contentEditor` who created the draft — enforcing separation of
   duties.
5. **`schedule(id:at:reviewer:)`** — sets a future `publishAt`; the
   item becomes `.scheduled`.
6. **`processScheduled()`** — run periodically (today, on-demand from
   tests); if `BatteryMonitor.isLowPowerMode == true` or
   `BatteryMonitor.level < 0.2`, enqueues the id into
   `deferredProcessing` and returns early. When the battery state
   recovers, the next call drains the deferred list and publishes the
   items whose `publishAt` has elapsed.
7. **`rollback(id:)`** — reverts `currentVersion` to the previous entry.

---

## 7. Messaging

`MessagingService.enqueue(id:from:to:body:attachments:actingUser:)`
applies a layered pipeline to every outbound message:

1. **Block check** — if the recipient has blocked the sender, throw
   `.blockedByRecipient`.
2. **Sensitive-data scanner** — `SensitiveDataScanner.scan(body)`
   applies two regex checks:
   - SSN: `\b\d{3}-\d{2}-\d{4}\b` → throws `.sensitiveDataBlocked(.ssn)`.
   - Payment card: 13–19 digits with optional separators → throws
     `.sensitiveDataBlocked(.paymentCard)`.
3. **Harassment filter** — `HarassmentFilter.isHarassing` (a small
   embedded wordlist: `idiot`, `stupid`, `loser`, `hate`). On hit:
   - Increments `strikes[senderId]`.
   - After 3 strikes, auto-blocks the sender → recipient pair.
   - Throws `.harassmentBlocked`.
4. **Contact masking** — `ContactMasker.mask(body)` replaces emails
   with `****@****` and phone numbers with `***-***-NNNN` (last 4
   preserved). Masking is applied for safe content that also happens to
   contain contact info; the returned `Message.body` is the masked form.
5. **Attachment validation** — each `MessageAttachment` must not exceed
   `maxAttachmentBytes = 10 MB`; type must be `.jpeg`, `.png`, or `.pdf`.
6. **Enqueue** — append to `queue` in FIFO order; emit
   `.messageEnqueued(id:)` on the RxSwift stream.

`drainQueue()` pops every queued message, stamps `deliveredAt =
clock.now()`, appends to `deliveredMessages`, and emits
`.queueDrained(count:)`. `messages(from:)` / `messages(to:)` are
ownership-filtered read APIs.

---

## 8. Talent Matching

`TalentMatchingService` runs an offline, in-memory matching engine for
HR-style candidate lookup. It is the only service currently scoped to
administrators (permission `.matchTalent`).

**Resume model.** `Resume { id, name, skills: [String], yearsExperience:
Int, certifications: [String], tags: [String] }`. Import via
`importResume(_:)`.

**Indices.** `skillIndex: [String: Set<String>]`,
`certIndex: [String: Set<String>]`, `tagIndex: [String: Set<String>]`
(reverse lookup from token → resume ids). Rebuilt on every import.

**Search.** `search(_ criteria: TalentSearchCriteria)` returns a sorted
array of `TalentMatch { resumeId, score, explanation }`.

Score is a weighted composite:

```
score = 0.5 * skillRatio
      + 0.3 * experienceRatio
      + 0.2 * certificationRatio
```

Where `skillRatio = |wantedSkills ∩ resumeSkills| / |wantedSkills|`,
`experienceRatio = min(yearsExperience / desiredYears, 1.0)`, and
`certificationRatio = |wantedCerts ∩ resumeCerts| / |wantedCerts|`.

**Boolean filter.** `BooleanFilter` is a recursive sum type with
combinators `.hasSkill(String)`, `.hasCertification(String)`,
`.minYears(Int)`, `.hasTag(String)`, `.and([BooleanFilter])`,
`.or([BooleanFilter])`, `.not(BooleanFilter)`. Applied as a hard filter
before scoring.

**Explanation.** The returned `explanation` string is stable across
runs (`"skills=100%, exp=120%, certs=100%"`) for audit and UI display.

**Saved searches.** `SavedSearch` persists a named criteria for recall;
`saveSearch`, `savedSearch(id)`, `listSavedSearches()`.

**Bulk operations.** `bulkTag(ids:add:)` applies a tag to many resumes
in a single call.

---

## 9. Attachments

`AttachmentService` is a file-backed attachment store, parameterized by
`Clock` and an `AttachmentFileStore`. It is independent from
`MessagingService`'s `MessageAttachment` value type — the latter describes
an attachment on a message, the former stores the bytes on disk (production
uses `DiskFileStore` with `FileProtectionType.complete`; tests use
`InMemoryFileStore`).

- **`save(id:data:kind:)`** — validates size ≤ 10 MB and kind in
  {`.jpeg`, `.png`, `.pdf`}; throws `AttachmentError.tooLarge` /
  `.invalidType`; computes SHA-256 at save and stores `StoredAttachment {
  id, sizeBytes, kind, storedAt, sandboxPath, sha256 }`.
- **`readData(_:)`** — returns the raw bytes and re-verifies the SHA-256;
  throws `AttachmentError.tamperDetected` on mismatch.
- **`all()`** — enumerates stored entries.
- **`runRetentionSweep()`** — removes every entry whose `storedAt <
  clock.now() - 30 days`, deleting both the on-disk file and the metadata;
  returns the purged ids. Run on demand today and scheduled as a
  `BGProcessingTask` in the app target.

---

## 10. App Lifecycle

`AppLifecycleService` observes process-level telemetry surfaced by
`UIApplicationDelegate`:

- **`markColdStart(begin:end:)`** — records elapsed milliseconds and
  returns `true` if within the **1.5 s** budget.
- **`cache(key:data:)` / `cached(_:)`** — a scratch image/data cache.
- **`scheduleDecode(_:)`** — stubs "decode this later" deferred work.
- **`handleMemoryWarning()`** — flushes the cache, drops all deferred
  decodes, increments `cacheEvictions` and `memoryWarnings` counters.

Wiring: `AppDelegate.applicationDidReceiveMemoryWarning(_:)` forwards to
`app.lifecycle.handleMemoryWarning()`. Cold-start timing is captured in
`application(_:didFinishLaunchingWithOptions:)` via `lifecycle.markColdStart`.

---

## 11. Attachments, Masking, and Data Quality

### 11.1 Contact masking

`ContactMasker` (in `MessagingService.swift`) is the single source of
contact-number and email redaction. Regex patterns are intentionally
permissive on separators (`.` / `-` / ` ` / none) to catch common
user-entered forms. Emails collapse to `****@****`; phones preserve
the last four digits as `***-***-NNNN`.

### 11.2 Sensitive scanners

`SensitiveDataScanner` is deliberately narrow: **SSN** and **payment
card** only. Both use compiled regex patterns and return the first
match — messages that contain either are rejected at enqueue time with
the category surfaced in the thrown error.

### 11.3 Address normalization

`AddressValidator.validate(_:)` enforces non-empty `line1` and `city`,
a ZIP matching `^\d{5}(-\d{4})?$`, and a recognized `USState`. It does
not canonicalize city-case or state abbreviations — that is left to the
caller, which is simpler for this project's offline scope.

### 11.4 Order hashing

`OrderHasher` implements SHA-256 in pure Swift (no CommonCrypto
dependency, so the domain library stays platform-free). The
canonical serialization prefix-length-encodes every `(field_name,
value)` pair so reordering fields cannot silently collide hashes, and
the field set is fixed so new optional fields never shift hash output
for existing orders.

---

## 12. Observability

- **RxSwift streams** — each transactional service exposes an
  `events: Observable<E>` where `E` is a service-specific enum
  (`CheckoutEvent`, `AfterSalesEvent`, `SeatInventoryEvent`,
  `MessagingEvent`). Subscribers (today, tests only) bind to these for
  assertions. The app layer does not currently subscribe.
- **`LocalNotificationBus`** — a separate append-only event buffer used
  for OS-level notifications (only `AfterSalesService` posts to it).
  `AppDelegate.wireNotificationBus()` assigns `app.notifications.onPost`
  so every published event becomes a `UNNotificationRequest` delivered
  to the user.
- **`AppLifecycleService` counters** — coldStartMillis, cacheEvictions,
  memoryWarnings, deferredDecodes. These are readable but there is no
  UI surface for them today; they are intended for diagnostics.

There is **no persistent audit log**. This is a deliberate trade-off
for offline simplicity and is flagged explicitly in `questions.md` Q10.

---

## 13. Security Summary

| Area | Control |
|---|---|
| **Authentication** | Local username/password + optional `LAContext` biometrics (Face ID / Touch ID) |
| **Authorization** | `RolePolicy` matrix checked at every service mutation; `actingUser: User` is non-optional |
| **Data at rest (secrets)** | `SystemKeychain` (generic-password items, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |
| **Order tamper detection** | SHA-256 hash of canonical snapshot, sealed in Keychain, verified by `CheckoutService.verify` |
| **Idempotency** | 10-second duplicate-submission guard on `orderId` |
| **Sensitive data filtering** | SSN and payment-card regex block at message enqueue |
| **Contact masking** | Email and phone redaction on message bodies at enqueue |
| **Harassment** | 3-strike auto-block on banned-word hits |
| **Attachment guards** | 10 MB max, allowlist of {jpeg, png, pdf}; 30-day retention sweep |
| **Separation of duties** | `.draftContent` (editors) ≠ `.publishContent` (reviewers/admin); `contentEditor.approve()` is rejected with `AuthorizationError.forbidden` |
| **Atomic inventory** | `SeatInventoryService.atomic { }` with full backup/restore on any throw |

---

## 14. Performance & Memory

### 14.1 Cold-start budget

1.5 s on iPhone 11-class hardware. Achieved by:

- Lazy `RailCommerce` instantiation in `AppDelegate.app` (the container
  is only built on first access, not synchronously in
  `didFinishLaunchingWithOptions`).
- `seedCatalog(_:)` inserts six SKUs inline — trivial work.
- No synchronous file I/O on the main thread.
- RxSwift `PublishSubject`s are allocated lazily by the services that
  expose them.

### 14.2 Memory warning handling

`AppLifecycleService.handleMemoryWarning()` flushes the scratch cache
and drops deferred decodes. Domain service state (carts, orders,
messages) is already small enough to not warrant eviction.

### 14.3 List rendering

UITableView is used throughout; no prefetching is wired today because
the dataset sizes (10s of SKUs, cart lines, requests) do not need it.
Scaling up past a few hundred rows in any list would warrant switching
to `UICollectionView` with a `UICollectionViewDataSourcePrefetching`.

---

## 15. Accessibility & HIG

- All labels and text fields on `LoginViewController` use
  `font = .preferredFont(forTextStyle:)` and
  `adjustsFontForContentSizeCategory = true` — the login screen
  responds to Dynamic Type.
- Auto Layout with `centerXAnchor` / `centerYAnchor` / readable insets;
  safe-area respected implicitly via `UIViewController.view`.
- `UINotificationFeedbackGenerator` fires `.error` on failed auth and
  `.success` on accepted auth; the pattern extends to checkout and
  after-sales approval flows.
- Dark Mode is inherited via `UIColor.systemBackground` and
  `UIColor.label` / `UIColor.secondaryLabel` semantic colors.
- Returning in `UITextFieldDelegate.textFieldShouldReturn` advances
  from username → password → sign in for keyboard-only users.

Dynamic Type, VoiceOver labels/hints, and split-view adaptation on
iPad are currently scoped to the login screen and the tab bar
containers; see `questions.md` Q11 for the full backlog of UX gaps
called out in the acceptance audit.

---

## 16. Testing Strategy

`Tests/RailCommerceTests/` holds 24 XCTest files targeting each service
in isolation plus integration flows:

- **Unit tests** cover every service's authorization guards, happy
  paths, error branches, and boundary conditions (e.g., 13 vs 14 days
  past service date for after-sales auto-reject; 9.99 vs 10 MB
  attachment size; 19 vs 20 minutes of time overlap).
- **`AuthorizationTests.swift`** is the cross-cutting RBAC harness:
  for every service method, it confirms each role's allowed/denied
  outcome against `RolePolicy.matrix`.
- **`IntegrationTests.swift`** exercises the browse→cart→promotion→
  checkout→verify→after-sales flow end-to-end with a `FakeClock`,
  `InMemoryKeychain`, `FakeCamera`, `FakeBattery` wired into
  `RailCommerce`.
- **`PromotionEngineTests.swift`** is particularly extensive because
  the distribution of amount-off discounts across lines is the most
  arithmetically subtle piece of logic in the project.
- **Reactive streams** are asserted via subscription in
  `ReactiveEventTests.swift` and in each service's own test file,
  confirming the right cases are emitted in the right order.

The library target builds and tests on macOS (no UIKit) as well as
iOS; CI can therefore validate the full domain layer without a
simulator.

---

## 17. Out-of-band constraints (CI / packaging)

- RxSwift is pulled from `https://github.com/ReactiveX/RxSwift.git`
  version `6.6.x`. A previous iteration of `Package.swift` used a
  local `/tmp/RxSwift` path; this was replaced with the remote URL for
  build reproducibility. The first `swift build` after clean-cache
  therefore incurs a network fetch of the RxSwift mirror.
- The Xcode project `RailCommerceApp.xcodeproj` coexists with the
  `Package.swift`-driven build. The canonical command-line build is
  `swift build`; the Xcode project is used only for device deployment
  / debugging.

---

## 18. Design decisions that remain open

Captured in detail in `questions.md`. Headline items:

1. **Audit trail** — no immutable log exists; hash-chain idea sketched
   but not implemented.
2. **Multi-tenancy** — explicitly out of scope in this build; the
   design must not leak assumptions that would preclude a later
   tenant scope.
3. **Explicit sign-out / bound-account reset** — today the bound
   username is cleared only when the device-level credential store is
   reset. A future "Forget this device" UX would call
   `BiometricBoundAccount.clear` to rebind on next password login.

Previously-open items that are now resolved:

- **Credential store** (was: in-VC user dictionary) — replaced by
  `KeychainCredentialStore` with PBKDF2-SHA256.
- **Persistence** (was: unwired) — every service now hydrates from and
  writes to `PersistenceStore`.
- **Observable subscription** (was: only tests) — view controllers
  subscribe to `events` streams for reactive UI refresh (cart, messaging,
  after-sales, seat inventory).

---

---

## 19. Membership Marketing

`MembershipService` provides an offline membership engine:

- **Enrollment** — `enroll(userId:tier:)` creates a member at the
  specified tier (default bronze). Duplicate enrollment is rejected.
- **Points** — `accruePoints` / `redeemPoints` track a balance;
  insufficient balance throws `.insufficientPoints`.
- **Tier progression** — `upgradeTier(userId:to:)` moves a member
  across bronze → silver → gold → platinum.
- **Tagging** — `tagMember(userId:tag:)` for segmentation (e.g.
  "frequent", "vip").
- **Campaigns** — `MarketingCampaign` targets members by tier set
  and/or tag set. `eligibleCampaigns(for:)` returns active campaigns
  matching the member's profile. `deactivateCampaign` disables a
  campaign without deleting it.
- **Persistence** — all member and campaign records persist through
  `PersistenceStore`; the service hydrates on init.

---

## 20. Anti-Harassment Report Controls

`MessagingService` now supports:

- `reportMessage(messageId:reportedBy:reason:)` — creates a
  `ReportRecord`, auto-blocks the sender from sending to the reporter.
- `reportUser(targetUserId:reportedBy:reason:)` — creates a
  `ReportRecord`, auto-blocks the target from sending to the reporter.
- Reports are persisted as `[ReportRecord]` and exposed via
  `reports` for admin audit.
- The UI surfaces a "Report" button in `MessagingViewController`.

---

## 21. Real File-Backed Attachment Storage

`AttachmentService` now writes bytes to disk:

- **File store abstraction** — `AttachmentFileStore` protocol with
  `DiskFileStore` (production, uses `FileProtectionType.complete`)
  and `InMemoryFileStore` (tests).
- **SHA-256 tamper detection** — hash computed at save, stored on
  `StoredAttachment.sha256`, and re-verified on every `get()` call.
  Mismatch throws `AttachmentError.tamperDetected`.
- **Retention sweep** — `runRetentionSweep()` deletes both the
  physical file and the metadata entry for attachments older than
  30 days.
- **Read API** — `readData(_:)` returns the raw bytes from disk.

---

## 22. Camera Permission + Photo Capture

`AfterSalesViewController` now:

- Calls `AVCaptureDevice.requestAccess(for: .video)` on first use,
  surfacing the system permission prompt.
- Presents `UIImagePickerController` with `.camera` source type when
  permission is granted.
- Attaches captured JPEG to the after-sales request via
  `app.attachments.save(id:data:kind:)`.
- Falls back to refund-only (no photo required) when camera is
  denied or unavailable.

---

## 23. Object-Level Data Isolation in UI

- **AfterSalesViewController** — customers see only requests for
  their own orders (filtered via `app.checkout.orders(for: user.id)`).
  CSR and admin see all requests.
- **MessagingViewController** — calls `messagesVisibleTo(_:actingUser:)`
  which returns only messages where the user is sender or recipient.
  CSR/admin can audit any user's messages.

---

## 24. Customer Content Browsing

`ContentBrowseViewController` (new) lets all users browse published
travel advisories and onboard offers with full taxonomy filtering
(region, theme, rider type). Backed by
`ContentPublishingService.items(filter:publishedOnly:)`.

---

*End of design document.*
