import Foundation

/// Umbrella module type that wires the individual services together. On the iOS target
/// this is built once at app launch; in tests each service is wired with a `FakeClock`.
public final class RailCommerce {
    public let clock: any Clock
    public let keychain: SecureStore
    public let persistence: PersistenceStore
    public let logger: Logger
    public let notifications: LocalNotificationBus
    public let transport: MessageTransport

    public let catalog: Catalog
    /// Legacy shared cart instance. Preserved for backward compatibility with
    /// tests and fixtures that don't assume user isolation. UI flows should
    /// prefer `cart(forUser:)` so persistence is scoped to the signed-in user.
    public let cart: Cart
    public let addressBook: AddressBook
    /// User-scoped cart cache populated lazily by `cart(forUser:)`.
    private var cartsByUser: [String: Cart] = [:]
    public let checkout: CheckoutService
    public let afterSales: AfterSalesService
    public let messaging: MessagingService
    public let seatInventory: SeatInventoryService
    public let publishing: ContentPublishingService
    public let attachments: AttachmentService
    public let talent: TalentMatchingService
    public let membership: MembershipService
    public let lifecycle: AppLifecycleService

    public init(
        clock: any Clock = SystemClock(),
        keychain: SecureStore = InMemoryKeychain(),
        camera: CameraPermission = FakeCamera(granted: true),
        battery: BatteryMonitor = FakeBattery(level: 1.0, isLowPowerMode: false),
        persistence: PersistenceStore = InMemoryPersistenceStore(),
        logger: Logger = SilentLogger(),
        transport: MessageTransport = InMemoryMessageTransport(),
        fileStore: AttachmentFileStore = InMemoryFileStore(),
        attachmentBasePath: String = NSTemporaryDirectory() + "railcommerce-attachments"
    ) {
        self.clock = clock
        self.keychain = keychain
        self.persistence = persistence
        self.logger = logger
        self.notifications = LocalNotificationBus()
        self.transport = transport

        let catalog = Catalog(persistence: persistence)
        self.catalog = catalog
        self.cart = Cart(catalog: catalog, persistence: persistence)
        self.addressBook = AddressBook(persistence: persistence)
        let checkout = CheckoutService(clock: clock, keychain: keychain,
                                        persistence: persistence, logger: logger)
        self.checkout = checkout
        self.afterSales = AfterSalesService(clock: clock, camera: camera,
                                            notifier: notifications,
                                            persistence: persistence, logger: logger,
                                            orderOwnershipValidator: { orderId, userId in
                                                checkout.order(orderId, ownedBy: userId) != nil
                                            })
        self.messaging = MessagingService(clock: clock, transport: transport,
                                          persistence: persistence, logger: logger)
        // Link the after-sales service into messaging so case-level
        // conversations (closed-loop CS thread per request) are routed
        // through the messaging layer's safeguards (masking, filters, etc.).
        self.afterSales.messenger = self.messaging
        self.seatInventory = SeatInventoryService(clock: clock,
                                                  persistence: persistence, logger: logger)
        self.publishing = ContentPublishingService(clock: clock, battery: battery,
                                                   persistence: persistence, logger: logger)
        let attachmentService = AttachmentService(clock: clock, persistence: persistence,
                                                  fileStore: fileStore, basePath: attachmentBasePath,
                                                  logger: logger)
        // Wire the reference graph so the retention sweep only purges truly
        // unreferenced attachments. Each resolver captures the corresponding
        // service weakly to avoid a retain cycle through the container.
        attachmentService.registerReferenceResolver { [weak messaging = self.messaging] in
            messaging?.referencedAttachmentIds() ?? []
        }
        attachmentService.registerReferenceResolver { [weak aftersales = self.afterSales] in
            aftersales?.referencedAttachmentIds() ?? []
        }
        attachmentService.registerReferenceResolver { [weak publishing = self.publishing] in
            publishing?.referencedAttachmentIds() ?? []
        }
        self.attachments = attachmentService
        self.talent = TalentMatchingService(persistence: persistence, logger: logger)
        self.membership = MembershipService(clock: clock, persistence: persistence, logger: logger)
        self.lifecycle = AppLifecycleService(clock: clock)
    }

    /// Returns the cart for a specific user. Persistence is scoped per-user so
    /// carts from other accounts cannot leak into this session on a shared device.
    /// Repeated calls for the same user return the same in-memory Cart so
    /// browse→add→checkout flows share state within one session.
    public func cart(forUser userId: String) -> Cart {
        if let existing = cartsByUser[userId] { return existing }
        let c = Cart(catalog: catalog, persistence: persistence, ownerUserId: userId)
        cartsByUser[userId] = c
        return c
    }

    /// Evicts a user's in-memory cart on sign-out so the next sign-in (possibly
    /// as a different user) sees a freshly hydrated cart, not stale lines from
    /// the previous session. Persistence survives under the user-scoped key.
    public func clearCart(forUser userId: String) {
        cartsByUser.removeValue(forKey: userId)
    }
}
