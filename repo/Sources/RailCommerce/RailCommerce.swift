import Foundation

/// Umbrella module type that wires the individual services together. On the iOS target
/// this is built once at app launch; in tests each service is wired with a `FakeClock`.
public final class RailCommerce {
    public let clock: Clock
    public let keychain: SecureStore
    public let notifications: LocalNotificationBus

    public let catalog: Catalog
    public let addressBook: AddressBook
    public let checkout: CheckoutService
    public let afterSales: AfterSalesService
    public let messaging: MessagingService
    public let seatInventory: SeatInventoryService
    public let publishing: ContentPublishingService
    public let attachments: AttachmentService
    public let talent: TalentMatchingService
    public let lifecycle: AppLifecycleService

    public init(
        clock: Clock = SystemClock(),
        keychain: SecureStore = InMemoryKeychain(),
        camera: CameraPermission = FakeCamera(granted: true),
        battery: BatteryMonitor = FakeBattery(level: 1.0, isLowPowerMode: false)
    ) {
        self.clock = clock
        self.keychain = keychain
        self.notifications = LocalNotificationBus()
        self.catalog = Catalog()
        self.addressBook = AddressBook()
        self.checkout = CheckoutService(clock: clock, keychain: keychain)
        self.afterSales = AfterSalesService(clock: clock, camera: camera, notifier: notifications)
        self.messaging = MessagingService(clock: clock)
        self.seatInventory = SeatInventoryService(clock: clock)
        self.publishing = ContentPublishingService(clock: clock, battery: battery)
        self.attachments = AttachmentService(clock: clock)
        self.talent = TalentMatchingService()
        self.lifecycle = AppLifecycleService(clock: clock)
    }
}
