import XCTest
import RxSwift
@testable import RailCommerce

/// Verifies that service `events` observables emit the correct `*Event` values.
final class ReactiveEventTests: XCTestCase {

    // MARK: - MessagingService

    func testMessagingEnqueueEmitsEvent() throws {
        let bag = DisposeBag()
        let svc = MessagingService(clock: FakeClock())
        var received: [MessagingEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)

        _ = try svc.enqueue(id: "m1", from: "a", to: "b", body: "hello")
        XCTAssertEqual(received, [.messageEnqueued("m1")])
    }

    func testMessagingDrainEmitsEvent() throws {
        let bag = DisposeBag()
        let svc = MessagingService(clock: FakeClock())
        _ = try svc.enqueue(id: "m1", from: "a", to: "b", body: "hi")
        var received: [MessagingEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)

        _ = svc.drainQueue()
        XCTAssertEqual(received, [.queueDrained(1)])
    }

    func testMessagingDrainEmptyQueueEmitsZeroCount() {
        let bag = DisposeBag()
        let svc = MessagingService(clock: FakeClock())
        var received: [MessagingEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)
        _ = svc.drainQueue()
        XCTAssertEqual(received, [.queueDrained(0)])
    }

    // MARK: - CheckoutService

    func testCheckoutSubmitEmitsOrderSubmittedEvent() throws {
        let bag = DisposeBag()
        let clock = FakeClock()
        let svc = CheckoutService(clock: clock, keychain: InMemoryKeychain())
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t1", quantity: 1)
        let address = USAddress(id: "a1", recipient: "Alice", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)

        var received: [CheckoutEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)

        _ = try svc.submit(orderId: "O1", userId: "U1", cart: cart, discounts: [],
                           address: address, shipping: shipping, invoiceNotes: "")
        XCTAssertEqual(received, [.orderSubmitted("O1")])
    }

    func testCheckoutVerifyEmitsOrderVerifiedEvent() throws {
        let bag = DisposeBag()
        let clock = FakeClock()
        let svc = CheckoutService(clock: clock, keychain: InMemoryKeychain())
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t1", quantity: 1)
        let address = USAddress(id: "a1", recipient: "Alice", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)
        let snap = try svc.submit(orderId: "O2", userId: "U1", cart: cart, discounts: [],
                                  address: address, shipping: shipping, invoiceNotes: "")

        var received: [CheckoutEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)

        try svc.verify(snap)
        XCTAssertEqual(received, [.orderVerified("O2")])
    }

    // MARK: - AfterSalesService

    func testAfterSalesOpenEmitsEvent() throws {
        let bag = DisposeBag()
        let clock = FakeClock()
        let svc = AfterSalesService(clock: clock,
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: clock.now(), serviceDate: clock.now(),
                                    amountCents: 500)
        var received: [AfterSalesEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)
        _ = try svc.open(req)
        XCTAssertEqual(received, [.requestOpened("R1")])
    }

    func testAfterSalesApproveEmitsResolvedEvent() throws {
        let bag = DisposeBag()
        let clock = FakeClock()
        let svc = AfterSalesService(clock: clock,
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: clock.now(), serviceDate: clock.now(),
                                    amountCents: 500)
        try svc.open(req)
        var received: [AfterSalesEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)
        try svc.approve(id: "R1")
        XCTAssertEqual(received, [.requestResolved("R1", .approved)])
    }

    func testAfterSalesRejectEmitsResolvedEvent() throws {
        let bag = DisposeBag()
        let clock = FakeClock()
        let svc = AfterSalesService(clock: clock,
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: clock.now(), serviceDate: clock.now(),
                                    amountCents: 500)
        try svc.open(req)
        var received: [AfterSalesEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)
        try svc.reject(id: "R1")
        XCTAssertEqual(received, [.requestResolved("R1", .rejected)])
    }

    // MARK: - SeatInventoryService

    func testSeatReserveEmitsEvent() throws {
        let bag = DisposeBag()
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        var received: [SeatInventoryEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)
        _ = try svc.reserve(key, holderId: "H1")
        XCTAssertEqual(received, [.seatReserved("T1", "1A")])
    }

    func testSeatConfirmEmitsEvent() throws {
        let bag = DisposeBag()
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        _ = try svc.reserve(key, holderId: "H1")
        var received: [SeatInventoryEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)
        try svc.confirm(key, holderId: "H1")
        XCTAssertEqual(received, [.seatConfirmed("T1", "1A")])
    }

    func testSeatReleaseEmitsEvent() throws {
        let bag = DisposeBag()
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        _ = try svc.reserve(key, holderId: "H1")
        var received: [SeatInventoryEvent] = []
        svc.events.subscribe(onNext: { received.append($0) }).disposed(by: bag)
        try svc.release(key, holderId: "H1")
        XCTAssertEqual(received, [.seatReleased("T1", "1A")])
    }

    // MARK: - MessagingEvent enum

    func testMessagingEventEquality() {
        XCTAssertEqual(MessagingEvent.messageEnqueued("x"), MessagingEvent.messageEnqueued("x"))
        XCTAssertNotEqual(MessagingEvent.messageEnqueued("x"), MessagingEvent.queueDrained(1))
        XCTAssertEqual(MessagingEvent.queueDrained(3), MessagingEvent.queueDrained(3))
    }

    func testCheckoutEventEquality() {
        XCTAssertEqual(CheckoutEvent.orderSubmitted("O1"), CheckoutEvent.orderSubmitted("O1"))
        XCTAssertNotEqual(CheckoutEvent.orderSubmitted("O1"), CheckoutEvent.orderVerified("O1"))
        XCTAssertEqual(CheckoutEvent.orderVerified("O2"), CheckoutEvent.orderVerified("O2"))
    }

    func testSeatInventoryEventEquality() {
        XCTAssertEqual(SeatInventoryEvent.seatReserved("T1", "1A"),
                       SeatInventoryEvent.seatReserved("T1", "1A"))
        XCTAssertNotEqual(SeatInventoryEvent.seatReserved("T1", "1A"),
                          SeatInventoryEvent.seatConfirmed("T1", "1A"))
        XCTAssertEqual(SeatInventoryEvent.seatReleased("T1", "1A"),
                       SeatInventoryEvent.seatReleased("T1", "1A"))
    }
}
