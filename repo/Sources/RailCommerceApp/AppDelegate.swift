#if canImport(UIKit)
import UIKit
import UserNotifications
import BackgroundTasks
import os
import RailCommerce
#if canImport(RealmSwift) && os(iOS)
import RealmSwift
#endif

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    /// Retained for touch-activity routing from the root window.
    private let battery = SystemBattery()

    /// Shared dependency container wired with production implementations.
    private(set) lazy var app: RailCommerce = {
        let persistence = Self.makeProductionPersistence()
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let attachBase = docsDir.appendingPathComponent("attachments").path
        let instance = RailCommerce(
            clock: SystemClock(),
            keychain: SystemKeychain(),
            camera: SystemCamera(),
            battery: self.battery,
            persistence: persistence,
            logger: SystemLogger(),
            transport: MultipeerMessageTransport(),
            fileStore: DiskFileStore(),
            attachmentBasePath: attachBase
        )
        seedCatalog(instance.catalog)
        return instance
    }()

    private(set) lazy var credentials: CredentialStore = {
        let store = KeychainCredentialStore(keychain: app.keychain)
        #if DEBUG
        seedCredentialsIfNeeded(into: store)
        #endif
        return store
    }()

    /// Builds the production persistence backend.
    /// On iOS with Realm available, uses encrypted Realm; otherwise falls back to in-memory.
    private static func makeProductionPersistence() -> PersistenceStore {
        #if canImport(RealmSwift) && os(iOS)
        let keychain = SystemKeychain()
        let encKeyName = "railcommerce.realm.encryptionKey"
        let encKey: Data
        if let existing = keychain.get(encKeyName) {
            encKey = existing
        } else {
            encKey = KeychainCredentialStore.randomBytes(64) // Realm requires 64-byte key
            try? keychain.set(encKey, forKey: encKeyName)
            keychain.seal(encKeyName)
        }
        let config = Realm.Configuration(encryptionKey: encKey)
        return RealmPersistenceStore(configuration: config)
        #else
        return InMemoryPersistenceStore()
        #endif
    }

    /// Tracks cold-start timing against the 1.5-second budget.
    private var launchBegin: Date?

    static let bgPublishTaskId = "com.railcommerce.content.publish"
    static let bgCleanupTaskId = "com.railcommerce.attachments.cleanup"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        launchBegin = Date()
        requestNotificationAuthorization()
        wireNotificationBus()
        registerBackgroundTasks()

        // Use ActivityTrackingWindow so every touch resets the inactivity timer
        // on the shared SystemBattery — real user-activity tracking for the
        // heavy-work gate (not just coarse lifecycle notifications).
        let window = ActivityTrackingWindow(frame: UIScreen.main.bounds)
        window.activityObserver = battery
        window.rootViewController = LoginViewController(app: app, credentials: credentials)
        window.makeKeyAndVisible()
        self.window = window

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let begin = self.launchBegin else { return }
            _ = self.app.lifecycle.markColdStart(begin: begin, end: Date())
        }
        return true
    }

    /// Starts the multipeer transport using the logged-in user's ID as the peer
    /// identifier. This ensures transport routing (which matches `message.toUserId`
    /// against peer display names) is consistent with the messaging visibility model.
    /// Called after successful login rather than at app launch.
    func startPeerTransport(asUser userId: String) {
        app.transport.stop()
        try? app.transport.start(asPeer: userId)
        // Drain any messages that were queued while the transport was offline.
        app.messaging.drainQueue()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        app.lifecycle.handleMemoryWarning()
    }

    /// Foreground publish tick. Invokes `ContentPublishingService.processScheduled()`
    /// periodically while the app is active, complementing the `BGProcessingTask`
    /// path. The service's internal power/inactivity gate still enforces the
    /// "heavy work only on power OR user inactivity" contract — this timer just
    /// gives an extra foreground trigger so a user-inactive state is noticed
    /// without waiting for iOS to launch the BG task.
    private var foregroundPublishTimer: Timer?

    private func startForegroundPublishTicker() {
        foregroundPublishTimer?.invalidate()
        // 60 seconds matches the SystemBattery inactivity threshold. The
        // service-layer gate will defer if the device is neither charging nor
        // inactive, so this is cheap and safe.
        foregroundPublishTimer = Timer.scheduledTimer(
            withTimeInterval: 60, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            let published = self.app.publishing.processScheduled()
            if !published.isEmpty {
                self.app.logger.info(.content, "fgPublish processed=\(published.count)")
            }
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        startForegroundPublishTicker()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        foregroundPublishTimer?.invalidate()
        foregroundPublishTimer = nil
    }

    // MARK: - Catalog seeding

    private func seedCatalog(_ catalog: Catalog) {
        catalog.upsert(SKU(id: "t-ne-1", kind: .ticket, title: "NE Express",
                           priceCents: 5_000,
                           tag: TaxonomyTag(region: .northeast, theme: .scenic, riderType: .tourist)))
        catalog.upsert(SKU(id: "t-w-1", kind: .ticket, title: "Pacific Sunset",
                           priceCents: 4_500,
                           tag: TaxonomyTag(region: .west, theme: .scenic, riderType: .tourist)))
        catalog.upsert(SKU(id: "t-mw-1", kind: .ticket, title: "Midwest Commuter",
                           priceCents: 2_200,
                           tag: TaxonomyTag(region: .midwest, theme: nil, riderType: .commuter)))
        catalog.upsert(SKU(id: "m-mug",  kind: .merchandise, title: "Travel Mug",   priceCents: 1_500))
        catalog.upsert(SKU(id: "m-bag",  kind: .merchandise, title: "Rail Tote Bag", priceCents: 2_000))
        catalog.upsert(SKU(id: "b-ne-scenic", kind: .bundle, title: "NE Scenic Combo",
                           priceCents: 6_000, bundleChildren: ["t-ne-1", "m-mug"]))
    }

    // MARK: - Credential seeding

    /// Seeds six role fixtures on first launch. Uses strong passphrases that satisfy the
    /// policy (12+ chars with digit+symbol). In a real deployment these would be seeded
    /// via an MDM enrollment payload rather than compiled in.
    private func seedCredentialsIfNeeded(into store: CredentialStore) {
        let fixtures: [(username: String, password: String, user: RCUser)] = [
            ("alice", "Alice!Pass1#2024", RCUser(id: "C1", displayName: "Alice Rider",  role: .customer)),
            ("sam",   "SamAgent!2024$",   RCUser(id: "A1", displayName: "Sam Agent",    role: .salesAgent)),
            ("eve",   "EveEditor!2024$",  RCUser(id: "E1", displayName: "Eve Editor",   role: .contentEditor)),
            ("rita",  "RitaReview!2024$", RCUser(id: "R1", displayName: "Rita Review",  role: .contentReviewer)),
            ("chris", "ChrisCSR!2024$",   RCUser(id: "S1", displayName: "Chris CSR",    role: .customerService)),
            ("dan",   "DanAdmin!2024$",   RCUser(id: "D1", displayName: "Dan Admin",    role: .administrator))
        ]
        for (u, p, usr) in fixtures {
            try? store.enroll(username: u, password: p, user: usr)
        }
    }

    // MARK: - Background tasks

    private func registerBackgroundTasks() {
        // Scheduled publishing runs as a BGProcessingTask (not BGAppRefreshTask) so the
        // OS only launches us when the device is on external power, satisfying the
        // prompt's "heavy work only on power or user inactivity" contract at the iOS
        // scheduler layer. The service layer (`ContentPublishingService.processScheduled`)
        // re-verifies the same gate so in-app invocations honor the contract too.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgPublishTaskId,
            using: nil
        ) { [weak self] task in
            self?.handlePublishTask(task as! BGProcessingTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgCleanupTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleCleanupTask(task as! BGProcessingTask)
        }
        schedulePublishTask()
        scheduleCleanupTask()
    }

    private func handlePublishTask(_ task: BGProcessingTask) {
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        let published = app.publishing.processScheduled()
        app.logger.info(.content, "bgPublish processed=\(published.count)")
        task.setTaskCompleted(success: true)
        schedulePublishTask()
    }

    private func handleCleanupTask(_ task: BGProcessingTask) {
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        let purged = app.attachments.runRetentionSweep()
        app.logger.info(.persistence, "bgCleanup purged=\(purged.count)")
        task.setTaskCompleted(success: true)
        scheduleCleanupTask()
    }

    /// Schedules the publish task. `requiresExternalPower = true` enforces the
    /// power-gating contract at the iOS scheduler layer — iOS will not run the
    /// task until the device is charging.
    private func schedulePublishTask() {
        let request = BGProcessingTaskRequest(identifier: Self.bgPublishTaskId)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func scheduleCleanupTask() {
        let request = BGProcessingTaskRequest(identifier: Self.bgCleanupTaskId)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Push / local notifications

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func wireNotificationBus() {
        app.notifications.onPost = { event in
            let content = UNMutableNotificationContent()
            content.title = "RailCommerce"
            content.body  = event
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: event,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}

// MARK: - os.Logger-backed Logger

/// Production logger backed by `os.Logger`. Each `LogCategory` maps to a dedicated
/// subsystem/category so Console.app and `log stream` can filter cleanly.
final class SystemLogger: RCLogger {
    private let subsystem = Bundle.main.bundleIdentifier ?? "com.railcommerce.app"
    private var loggers: [LogCategory: os.Logger] = [:]

    init() {
        for c in LogCategory.allCases {
            loggers[c] = os.Logger(subsystem: subsystem, category: c.rawValue)
        }
    }

    func debug(_ category: LogCategory, _ message: String) {
        loggers[category]?.debug("\(LogRedactor.redact(message), privacy: .public)")
    }
    func info(_ category: LogCategory, _ message: String) {
        loggers[category]?.info("\(LogRedactor.redact(message), privacy: .public)")
    }
    func warn(_ category: LogCategory, _ message: String) {
        loggers[category]?.warning("\(LogRedactor.redact(message), privacy: .public)")
    }
    func error(_ category: LogCategory, _ message: String) {
        loggers[category]?.error("\(LogRedactor.redact(message), privacy: .public)")
    }
}
#endif
