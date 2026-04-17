import Foundation
import RailCommerce

// ANSI helpers for readable terminal output.
enum Ansi {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let cyan = "\u{001B}[36m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let magenta = "\u{001B}[35m"
}

func section(_ title: String) {
    print("\n\(Ansi.bold)\(Ansi.cyan)━━ \(title) ━━\(Ansi.reset)")
}

func step(_ msg: String) {
    print("\(Ansi.yellow)•\(Ansi.reset) \(msg)")
}

func ok(_ msg: String) {
    print("\(Ansi.green)✓\(Ansi.reset) \(msg)")
}

func kv(_ key: String, _ value: Any) {
    print("   \(Ansi.magenta)\(key):\(Ansi.reset) \(value)")
}

// Deterministic clock starting Mon 2024-01-01 10:00 UTC.
let clock = FakeClock(Date(timeIntervalSince1970: 1_704_103_200))
let keychain = InMemoryKeychain()
let camera = FakeCamera(granted: true)
let battery = FakeBattery()
let app = RailCommerce(clock: clock, keychain: keychain, camera: camera, battery: battery)

print("\(Ansi.bold)RailCommerce Operations — Offline Demo\(Ansi.reset)")
print("Simulated device clock: \(clock.now())")

// MARK: Administrator seeds catalog and content
section("Administrator seeds catalog & content")
app.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "NE Express",
                       priceCents: 5_000,
                       tag: TaxonomyTag(region: .northeast, theme: .scenic, riderType: .tourist)))
app.catalog.upsert(SKU(id: "m1", kind: .merchandise, title: "Travel Mug", priceCents: 1_500))
app.catalog.upsert(SKU(id: "combo", kind: .bundle, title: "Scenic Combo",
                       priceCents: 6_000, bundleChildren: ["t1", "m1"]))
ok("Catalog has \(app.catalog.all.count) items")
for sku in app.catalog.all { kv(sku.id, "\(sku.title) — $\(Double(sku.priceCents)/100)") }

let editor = User(id: "e1", displayName: "Eve Editor", role: .contentEditor)
let reviewer = User(id: "r1", displayName: "Rita Reviewer", role: .contentReviewer)
let customerUser = User(id: "C1", displayName: "Alice Rider", role: .customer)
let csrUser = User(id: "csr1", displayName: "Chris CSR", role: .customerService)

_ = try app.publishing.createDraft(id: "adv-1", kind: .travelAdvisory,
                                   title: "Snow Delay on Boston Line",
                                   tag: TaxonomyTag(region: .northeast),
                                   body: "Expect 30-min delays.", editorId: editor.id,
                                   actingUser: editor)

// MARK: Content lifecycle
section("Content: draft → review → publish")
_ = try app.publishing.edit(id: "adv-1", body: "Expect 45-min delays.", editorId: editor.id,
                            actingUser: editor)
try app.publishing.submitForReview(id: "adv-1", actingUser: editor)
try app.publishing.approve(id: "adv-1", reviewer: reviewer)
if let item = app.publishing.get("adv-1", actingUser: reviewer) {
    ok("Advisory published")
    kv("status", item.status.rawValue)
    kv("version", item.currentVersion)
    kv("region", item.tag.region?.rawValue ?? "-")
}

// MARK: Customer browses by taxonomy
section("Customer browses by taxonomy")
let neTickets = app.catalog.filter(TaxonomyTag(region: .northeast))
ok("Northeast tickets: \(neTickets.map { $0.id })")

// MARK: Cart CRUD + bundle suggestion
section("Customer builds cart")
let cart = Cart(catalog: app.catalog)
try cart.add(skuId: "t1", quantity: 1)
step("Added 1× t1 — subtotal $\(Double(cart.subtotalCents)/100)")
let suggestions = cart.bundleSuggestions()
for s in suggestions {
    ok("Bundle suggestion: \(s.bundleId) — add [\(s.missing.joined(separator: ", "))] to save $\(Double(s.savingsCents)/100)")
}

// MARK: Address + shipping
section("Customer saves address & picks shipping")
let address = USAddress(id: "home", recipient: "Alice Rider", line1: "1 Main St",
                        city: "NYC", state: .NY, zip: "10001", isDefault: true)
try app.addressBook.save(address)
ok("Saved default address: \(app.addressBook.defaultAddress!.recipient), \(app.addressBook.defaultAddress!.state.rawValue)")
let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)
kv("shipping", "\(shipping.name) — $\(Double(shipping.feeCents)/100), ~\(shipping.etaDays)d")

// MARK: Promotion pipeline
section("Promotion pipeline (max 3, no percent stacking)")
let discounts = [
    Discount(code: "PCT10", kind: .percentOff, magnitude: 10, priority: 1),
    Discount(code: "PCT20", kind: .percentOff, magnitude: 20, priority: 2), // rejected
    Discount(code: "AMT200", kind: .amountOff, magnitude: 200, priority: 3),
    Discount(code: "SHIPFREE", kind: .freeShipping, magnitude: 0, priority: 4),
    Discount(code: "AMTX", kind: .amountOff, magnitude: 50, priority: 5)    // rejected (>3)
]
let promo = PromotionEngine.apply(cart: cart, discounts: discounts)
ok("Accepted: \(promo.acceptedCodes)   Rejected: \(promo.rejectedCodes)")
for (code, reason) in promo.rejectionReasons {
    kv(code, reason)
}
kv("subtotal", "$\(Double(promo.subtotalCents)/100)")
kv("total discount", "$\(Double(promo.totalDiscountCents)/100)")
kv("free shipping", promo.freeShipping)
for exp in promo.lineExplanations {
    kv("line \(exp.skuId)", "original $\(Double(exp.originalCents)/100) → $\(Double(exp.discountedCents)/100) (\(exp.appliedCodes.joined(separator: ",")))")
}

// MARK: Checkout with idempotency + Keychain hash
section("Checkout (idempotent, hashed, sealed in Keychain)")
let snap = try app.checkout.submit(orderId: "O-1001", userId: "C1", cart: cart,
                                   discounts: discounts,
                                   address: app.addressBook.defaultAddress!,
                                   shipping: shipping, invoiceNotes: "Gift wrap",
                                   actingUser: customerUser)
ok("Order O-1001 accepted — total $\(Double(snap.totalCents)/100)")
kv("stored hash (16 hex)", String(app.checkout.storedHash(for: "O-1001")!.prefix(16)) + "…")
try app.checkout.verify(snap)
ok("Hash verified — snapshot untampered")

step("Replaying same orderId within 10s…")
do {
    _ = try app.checkout.submit(orderId: "O-1001", userId: "C1", cart: cart,
                                discounts: discounts, address: address,
                                shipping: shipping, invoiceNotes: "Gift wrap",
                                actingUser: customerUser)
} catch let err as CheckoutError {
    ok("Blocked as duplicate: \(err)")
}

// MARK: Seat inventory
section("Seat inventory (atomic + 15-min locks + snapshots)")
let seat = SeatKey(trainId: "NE1", date: "2024-01-02", segmentId: "NY-BOS",
                   seatClass: .economy, seatNumber: "12A")
let salesAgentUser = User(id: "agent1", displayName: "Sam Agent", role: .salesAgent)
try app.seatInventory.registerSeat(seat, actingUser: salesAgentUser)
try app.seatInventory.snapshot(date: "2024-01-02", actingUser: salesAgentUser)
let res = try app.seatInventory.reserve(seat, holderId: "C1", actingUser: customerUser)
ok("Reserved seat 12A until \(res.expiresAt) (holder C1)")
kv("state", app.seatInventory.state(seat)!.rawValue)
clock.advance(by: 16 * 60)
ok("After 16 min — lock expired → state = \(app.seatInventory.state(seat)!.rawValue)")

// MARK: After-sales
section("After-sales: refund request + auto-approval")
clock.set(Date(timeIntervalSince1970: 1_704_103_200)) // reset
let rma = AfterSalesRequest(id: "R-1", orderId: "O-1001", kind: .refundOnly,
                            reason: .defective, createdAt: clock.now(),
                            serviceDate: clock.now(), amountCents: 1_500)
_ = try app.afterSales.open(rma, actingUser: customerUser)
clock.advance(by: 60 * 60) // 1h later CSR responds
try app.afterSales.respond(id: "R-1", actingUser: csrUser)
let sla = app.afterSales.sla(for: "R-1")!
kv("first response due", sla.firstResponseDue)
kv("resolution due", sla.resolutionDue)
kv("breach?", "response=\(sla.firstResponseBreached) resolution=\(sla.resolutionBreached)")

clock.advance(by: 48 * 3600)
let changed = app.afterSales.runAutomation()
ok("Automation pass — changed: \(changed)")
kv("R-1 status", try app.afterSales.get("R-1", actingUser: csrUser)!.status.rawValue)

// MARK: Messaging
section("Offline staff messaging (queued, masked, filtered)")
let masked = try app.messaging.enqueue(id: "m1", from: "csr1", to: "agent2",
                                       body: "Please call rider@mail.com at 555 222 3333",
                                       actingUser: csrUser)
ok("Queued message after masking:")
kv("body", masked.body)

do {
    _ = try app.messaging.enqueue(id: "m2", from: "csr1", to: "agent2",
                                  body: "SSN 111-22-3333",
                                  actingUser: csrUser)
} catch let e as MessagingError {
    ok("Sensitive content blocked → \(e)")
}

_ = app.messaging.drainQueue()
ok("Queue drained, delivered=\(app.messaging.deliveredMessages.count)")

// MARK: Talent matching
section("Offline talent matching (weights 50/30/20)")
app.talent.importResume(Resume(id: "tm1", name: "Pat", skills: ["swift", "uikit"],
                               yearsExperience: 6, certifications: ["railSafety"]))
app.talent.importResume(Resume(id: "tm2", name: "Sam", skills: ["kotlin"],
                               yearsExperience: 2, certifications: []))
let adminUser = User(id: "admin1", displayName: "Dan Admin", role: .administrator)
let matches = try app.talent.search(TalentSearchCriteria(
    wantedSkills: ["swift", "uikit"], wantedCertifications: ["railSafety"],
    desiredYears: 5, filter: .or(.hasSkill("swift"), .hasCertification("railSafety"))
), by: adminUser)
for m in matches {
    ok("\(m.resumeId) score=\(String(format: "%.2f", m.score))  [\(m.explanation)]")
}

// MARK: Attachment retention
section("Attachment sandbox & 30-day retention sweep")
_ = try app.attachments.save(id: "proof1", data: Data([0,1,2]), kind: .jpeg)
_ = try app.attachments.save(id: "proof2", data: Data([3,4,5]), kind: .pdf)
ok("Stored: \(app.attachments.all().map { $0.id })")
clock.advance(by: 31 * 86_400)
let purged = app.attachments.runRetentionSweep()
ok("After 31 days → purged: \(purged)")

// MARK: Lifecycle
section("App lifecycle (cold start + memory warning)")
let begin = Date()
let end = begin.addingTimeInterval(1.2)
_ = app.lifecycle.markColdStart(begin: begin, end: end)
app.lifecycle.cache(key: "img1", data: Data([9]))
app.lifecycle.scheduleDecode("img1")
app.lifecycle.handleMemoryWarning()
kv("cold start (ms)", app.lifecycle.coldStartMillis)
kv("memory warnings", app.lifecycle.memoryWarnings)
kv("cache evictions", app.lifecycle.cacheEvictions)
kv("deferred decodes", app.lifecycle.deferredDecodes)

print("\n\(Ansi.green)\(Ansi.bold)All RailCommerce flows executed successfully.\(Ansi.reset)\n")
